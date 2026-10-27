"""Measure a published GPU library across real decode/cancel/recovery cycles."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import time


def gpu_memory_bytes():
    output = subprocess.check_output([
        'nvidia-smi', '--query-compute-apps=pid,used_gpu_memory',
        '--format=csv,noheader,nounits'], text=True, timeout=10)
    values = [int(row.split(',')[1].strip()) * 1024 * 1024
              for row in output.splitlines() if row.split(',')[0].strip() == str(os.getpid())]
    if len(values) != 1:
        raise RuntimeError('Expected one GPU memory entry for this PID; use the host PID namespace')
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['harness', 'library', 'model', 'output']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--backend', choices=['cuda', 'vulkan'], required=True)
    args = parser.parse_args()
    if not shutil.which('nvidia-smi'):
        parser.error('nvidia-smi is required for per-process GPU measurements')
    arguments = sys.argv
    try:
        sys.argv = [args.harness, args.library, args.model]
        harness = runpy.run_path(args.harness, run_name='gpu_resource_harness')
    finally:
        sys.argv = arguments
    config = dict(model_path=args.model, n_ctx=512, n_batch=64, n_ubatch=64,
                  n_parallel=1, n_threads=6, n_threads_batch=6, n_gpu_layers=99,
                  backend=args.backend, require_backend=True,
                  cache_type_k='f16', cache_type_v='f16', swa_full=False)
    evidence = dict(status='running', backend=args.backend, requested=config,
                    pid=os.getpid(), samples=[], cancelled_decode_requests=0,
                    recovery_requests=0, cancel_barrier_seconds=[],
                    library_sha256=hashlib.sha256(Path(args.library).read_bytes()).hexdigest(),
                    harness_sha256=hashlib.sha256(Path(args.harness).read_bytes()).hexdigest())
    engine = harness['Engine'](config)
    assert engine.ptr, engine.read(engine.error)
    try:
        engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
        engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
        engine.lib.llcs_engine_caps.argtypes = [ctypes.c_void_p]
        engine.lib.llcs_engine_caps.restype = ctypes.c_void_p
        caps = engine.read(engine.lib.llcs_engine_caps(engine.ptr))
        evidence['caps'] = caps
        assert caps['selected_backend'] == args.backend and caps['require_backend']
        assert not caps['degradation']
        assert any(d['backend'].lower() == args.backend and d['type'] != 'cpu'
                   for d in caps['device_info'])
        request = dict(messages=[dict(role='user', content='List all the integers from 1 to 10000.')],
                       stream=True, max_tokens=384, temperature=0, ignore_eos=True,
                       chat_template_kwargs={'enable_thinking': False},
                       stream_options={'include_usage': True})
        recovery = dict(messages=[dict(role='user', content='Reply with the word ready.')],
                        stream=True, max_tokens=16, temperature=0,
                        chat_template_kwargs={'enable_thinking': False},
                        stream_options={'include_usage': True})
        zero_fields = ['active_tasks', 'retained_tasks', 'pending_cancellations',
                       'buffered_events', 'buffered_bytes']
        for index in range(1, 151):
            task, error = engine.submit(request)
            assert task >= 0, error
            deadline = time.monotonic() + 15
            while True:
                assert time.monotonic() < deadline, 'No actual decode content before cancel'
                event = engine.read(engine.lib.llcs_engine_poll(engine.ptr, task, 20))
                assert event is not None, 'Request ended before cancellation'
                if event:
                    assert isinstance(event, dict) and 'error' not in event, event
                    assert not any(c.get('finish_reason') for c in event['choices']), event
                    if any(c['delta'].get('content') for c in event['choices']):
                        break
            before = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            own_task = next(t for t in before['tasks'] if t['id'] == task)
            assert own_task['state'] == 'decoding', own_task
            cancelled_at = time.monotonic()
            engine.lib.llcs_engine_cancel(engine.ptr, task)
            # Never poll this cancelled task again. The next request is immediate.
            events = engine.complete(recovery)
            text = ''.join(c['delta'].get('content') or '' for e in events for c in e['choices'])
            evidence['last_recovery'] = dict(cycle=index, text=text, events=events)
            assert text == 'ready', evidence['last_recovery']
            assert [c['finish_reason'] for e in events for c in e['choices'] if c.get('finish_reason')] == ['stop'], events
            assert any(e.get('usage', {}).get('completion_tokens', 0) > 0 for e in events), events
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            assert all(stats[k] == 0 for k in zero_fields), stats
            assert stats['collector_threads'] == 1
            assert stats['cancelled'] == index and stats['completed'] == index, stats
            evidence['cancel_barrier_seconds'].append(time.monotonic() - cancelled_at)
            evidence['cancelled_decode_requests'] = index
            evidence['recovery_requests'] = index
            if index in [50, 75, 100, 125, 150]:
                threads, rss_kib = harness['process_resources']()
                sample = dict(cycles=index, threads=threads, rss_bytes=rss_kib * 1024,
                              vram_bytes=gpu_memory_bytes(), native_stats=stats)
                evidence['samples'].append(sample)
                print(json.dumps({k: sample[k] for k in ['cycles', 'threads', 'rss_bytes', 'vram_bytes']}), flush=True)
        samples = evidence['samples']
        first = samples[0]
        assert all(s['threads'] <= first['threads'] + 2 for s in samples), samples
        assert all(s['rss_bytes'] <= first['rss_bytes'] + 32 * 1024 * 1024 for s in samples), samples
        # nvidia-smi reports whole MiB; permit only its one-MiB reporting granularity.
        assert max(s['vram_bytes'] for s in samples) - min(s['vram_bytes'] for s in samples) <= 1024 * 1024, samples
        evidence['final_native_stats'] = stats
        evidence['status'] = 'passed'
    except BaseException as error:
        evidence['status'] = 'failed'
        evidence['error'] = str(error)
        raise
    finally:
        engine.close()
        evidence['engine_destroy_returned'] = True
        Path(args.output).write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(dict(status=evidence['status'], backend=args.backend, cycles=150)), flush=True)


if __name__ == '__main__':
    main()
