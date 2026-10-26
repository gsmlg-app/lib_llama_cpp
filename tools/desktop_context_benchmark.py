#!/usr/bin/env python3
"""Opt-in real Gemma native-window acceptance; no model is downloaded by this tool."""
import argparse
import ctypes
import hashlib
import json
import os
import platform
import subprocess
import sys
import threading
import time
from pathlib import Path


def memory_snapshot():
    if sys.platform.startswith('linux'):
        data = Path('/proc/self/status').read_text()
        fields = dict(line.split(':', 1) for line in data.splitlines() if ':' in line)
        return {'rss_bytes': int(fields['VmRSS'].split()[0]) * 1024,
                'threads': int(fields['Threads'].strip())}
    if sys.platform == 'win32':
        class Counters(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_ulong), ('faults', ctypes.c_ulong)] + [
                (n, ctypes.c_size_t) for n in ('peak_ws', 'ws', 'qpp', 'qpc', 'qnpp', 'qnpc', 'page', 'peak_page')]
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        handle = ctypes.windll.kernel32.GetCurrentProcess()
        if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            raise OSError('GetProcessMemoryInfo failed')
        return {'rss_bytes': counters.ws, 'threads': None}
    raise RuntimeError('Acceptance targets Linux and Windows only')


class Peaks:
    def __init__(self):
        self.rss = 0
        self.vram = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.sample)

    def sample(self):
        while not self.stop.is_set():
            self.rss = max(self.rss, memory_snapshot()['rss_bytes'])
            try:
                proc = subprocess.run(['nvidia-smi', '--query-compute-apps=pid,used_gpu_memory',
                    '--format=csv,noheader,nounits'], capture_output=True, text=True, timeout=2)
                for line in proc.stdout.splitlines():
                    pid, used = [v.strip() for v in line.split(',', 1)]
                    if pid == str(os.getpid()) and used.isdigit():
                        self.vram = max(self.vram or 0, int(used) * 1024 * 1024)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
            self.stop.wait(0.25)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()


class Native:
    def __init__(self, library, config):
        self.lib = ctypes.CDLL(library)
        signatures = {
            'llcs_engine_create': ([ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_void_p),
            'llcs_engine_submit': ([ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int64),
            'llcs_engine_prepare': ([ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_void_p),
            'llcs_engine_poll': ([ctypes.c_void_p, ctypes.c_int64, ctypes.c_int32], ctypes.c_void_p),
            'llcs_engine_cancel': ([ctypes.c_void_p, ctypes.c_int64], None),
            'llcs_engine_caps': ([ctypes.c_void_p], ctypes.c_void_p),
            'llcs_engine_stats': ([ctypes.c_void_p], ctypes.c_void_p),
            'llcs_engine_destroy': ([ctypes.c_void_p], None),
            'llcs_string_free': ([ctypes.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = args, result
        err = ctypes.c_void_p()
        start = time.monotonic()
        self.ptr = self.lib.llcs_engine_create(json.dumps(config).encode(), ctypes.byref(err))
        self.load_seconds = time.monotonic() - start
        if not self.ptr:
            raise RuntimeError(self.read(err))

    def read(self, ptr):
        if not ptr:
            return None
        try:
            text = ctypes.string_at(ptr).decode('utf-8')
            return json.loads(text) if text else ''
        finally:
            self.lib.llcs_string_free(ptr)

    def call(self, name, body):
        err = ctypes.c_void_p()
        result = getattr(self.lib, name)(self.ptr, json.dumps(body).encode(), ctypes.byref(err))
        error = self.read(err)
        if error is not None:
            raise RuntimeError(error)
        return result

    def prepare(self, body):
        return self.read(self.call('llcs_engine_prepare', body))

    def stats(self):
        return self.read(self.lib.llcs_engine_stats(self.ptr))

    def caps(self):
        return self.read(self.lib.llcs_engine_caps(self.ptr))

    def run(self, body, timeout=7200, stop_after_content=False):
        started = time.monotonic()
        task = self.call('llcs_engine_submit', body)
        events, text, reasoning = [], '', ''
        ttft, finished, drained = None, False, False
        try:
            while time.monotonic() - started < timeout:
                event = self.read(self.lib.llcs_engine_poll(self.ptr, task, 100))
                if event is None:
                    drained = True
                    break
                if event == '':
                    continue
                if 'error' in event:
                    raise RuntimeError(event)
                events.append(event)
                for choice in event.get('choices', []):
                    delta = choice.get('delta', {})
                    text += delta.get('content') or ''
                    reasoning += delta.get('reasoning_content') or ''
                    if (text or reasoning or delta.get('tool_calls')) and ttft is None:
                        ttft = time.monotonic() - started
                    finished |= choice.get('finish_reason') is not None
                if stop_after_content and ttft is not None:
                    break
            if stop_after_content:
                return task, {'ttft_seconds': ttft}
            assert drained and finished and (text or reasoning), ('incomplete stream', events[-3:])
            usage = next((e['usage'] for e in reversed(events) if 'usage' in e), None)
            assert usage and usage['prompt_tokens'] > 0 and usage['completion_tokens'] > 0, events[-3:]
            elapsed = time.monotonic() - started
            return {'text': text, 'reasoning': reasoning, 'ttft_seconds': ttft, 'duration_seconds': elapsed,
                'usage': usage, 'decode_tokens_per_second_excluding_ttft':
                max(0, usage['completion_tokens'] - 1) / max(0.000001, elapsed - ttft),
                'native_timings': [e['timings'] for e in events if 'timings' in e],
                'finish_reasons': [c['finish_reason'] for e in events for c in e.get('choices', []) if c.get('finish_reason')],
                'event_count': len(events), 'request_ids': sorted({e['id'] for e in events if 'id' in e})}
        except BaseException:
            self.lib.llcs_engine_cancel(self.ptr, task)
            raise

    def cancel_and_wait(self, task):
        started = time.monotonic()
        self.lib.llcs_engine_cancel(self.ptr, task)
        while time.monotonic() - started < 30:
            stats = self.stats()
            if stats['pending_cancellations'] == 0:
                return {'latency_seconds': time.monotonic() - started, 'stats': stats}
            time.sleep(0.01)
        raise AssertionError(('cancellation did not reach upstream barrier', self.stats()))

    def close(self):
        self.lib.llcs_engine_destroy(self.ptr)
        self.ptr = None


def request(content, output=512):
    return {'messages': [{'role': 'user', 'content': content}], 'stream': True,
        'max_tokens': output, 'temperature': 0, 'cache_prompt': True,
        'stream_options': {'include_usage': True}, 'chat_template_kwargs': {'enable_thinking': False}}


def long_request(engine, target):
    def body(repetitions):
        filler = 'The archive contains ordinary notes on weather, roads, rivers, and books.\n'
        text = ('Read the document and report the three secret key values.\nDocument begins.\n'
            'BEGIN_KEY: amber731\n' + filler * (repetitions // 2) + 'MIDDLE_KEY: birch482\n' +
            filler * (repetitions - repetitions // 2) + 'END_KEY: cedar956\nDocument ends.\n'
            'Return BEGIN_KEY, MIDDLE_KEY, END_KEY values as JSON. Only return the JSON.')
        return request(text)
    low, high = 0, target
    while low + 1 < high:
        middle = (low + high) // 2
        if engine.prepare(body(middle))['prompt_tokens'] <= target - 1024:
            low = middle
        else:
            high = middle
    result = body(low)
    budget = engine.prepare(result)
    assert budget['fits'] and budget['prompt_tokens'] >= target * .95, budget
    return result, budget


def verify_retrieval(result):
    assert all(value in result['text'] for value in ('amber731', 'birch482', 'cedar956')), result


def acceptance(args):
    config = {'model_path': str(Path(args.model).resolve()), 'n_ctx': args.context,
        'n_batch': args.batch, 'n_ubatch': args.ubatch, 'n_threads': args.threads,
        'n_threads_batch': args.threads, 'n_gpu_layers': args.gpu_layers,
        'n_parallel': 1, 'cache_type_k': 'f16', 'cache_type_v': 'f16', 'swa_full': False,
        'flash_attn': args.flash_attn, 'backend': args.backend, 'require_backend': True}
    evidence = {'status': 'running', 'platform': platform.platform(), 'machine': platform.machine(),
        'model_file': Path(args.model).name, 'model_sha256': hashlib.file_digest(open(args.model, 'rb'), 'sha256').hexdigest(),
        'library_file': Path(args.library).name,
        'library_sha256': hashlib.file_digest(open(args.library, 'rb'), 'sha256').hexdigest(),
        'llama_cpp_commit': '95b8b8ec1a9e77bcc7b3fb04da82c9f35cb12a79', 'requested': config}
    engine = None
    try:
        with Peaks() as peaks:
            engine = Native(args.library, config)
            evidence.update(load_seconds=engine.load_seconds, caps=engine.caps())
            body, budget = long_request(engine, args.context)
            evidence['budget'] = budget
            evidence['first_turn'] = engine.run(body)
            verify_retrieval(evidence['first_turn'])
            history = body['messages'] + [{'role': 'assistant', 'content': evidence['first_turn']['text']},
                {'role': 'user', 'content': 'Repeat the same three values as JSON.'}]
            second = dict(body, messages=history, max_tokens=256)
            evidence['second_budget'] = engine.prepare(second)
            evidence['second_turn'] = engine.run(second)
            verify_retrieval(evidence['second_turn'])
            overflow = dict(body, max_tokens=args.context)
            try:
                engine.call('llcs_engine_submit', overflow)
                raise AssertionError('overflow was accepted')
            except RuntimeError as error:
                assert 'context_overflow' in str(error), error
                evidence['overflow'] = str(error)
            cancel_body = dict(body, messages=[{'role': 'system', 'content': 'New independent document for cancellation.'}] + body['messages'])
            evidence['prefill_cancel_budget'] = engine.prepare(cancel_body)
            task = engine.call('llcs_engine_submit', cancel_body)
            time.sleep(.05)
            # Observe an upstream prompt-progress state, not a cached decode.
            # A completed CPU prefill batch can take longer than five seconds.
            # Still require observed work (processed > 0), within a bounded wait.
            phase_deadline = time.monotonic() + 120
            while True:
                tasks = engine.stats().get('tasks', [])
                current = next((t for t in tasks if t['id'] == task), {})
                if current.get('state') == 'prefilling' and current.get('prompt_progress', {}).get('processed', 0) > 0:
                    evidence['prefill_cancel_observed'] = current
                    break
                assert current.get('state') not in ('decoding', 'completed'), ('cancel probe missed prefill', current)
                assert time.monotonic() < phase_deadline, ('prefill state not observed', tasks)
                time.sleep(.01)
            # Deliberately never poll this task after cancellation.
            evidence['prefill_cancel'] = engine.cancel_and_wait(task)
            evidence['recovery'] = engine.run(request('Reply with the word ready.', 32))
            task, first = engine.run(request('Count upwards from one, one number per line.', 256), stop_after_content=True)
            evidence['decode_cancel'] = dict(engine.cancel_and_wait(task), **first)
            evidence['post_cancel_recovery'] = engine.run(request('Reply with the word ready.', 32))
            evidence['stats'] = engine.stats()
            evidence['peak_rss_bytes'] = peaks.rss
            evidence['peak_vram_bytes'] = peaks.vram
            evidence['vram_note'] = None if peaks.vram is not None else 'Driver did not expose per-process VRAM; unified-memory peak is included in RSS.'
        evidence['status'] = 'passed'
    except BaseException as error:
        evidence.update(status='failed', error=repr(error))
        raise
    finally:
        if engine:
            engine.close()
        Path(args.output).write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--context', required=True, type=int, choices=[32768, 65536, 131072])
    parser.add_argument('--backend', choices=['cpu', 'cuda', 'vulkan'], default='cpu')
    parser.add_argument('--gpu-layers', type=int, default=0)
    parser.add_argument('--batch', type=int, default=1024)
    parser.add_argument('--ubatch', type=int, default=256)
    parser.add_argument('--threads', type=int, default=8)
    parser.add_argument('--flash-attn', choices=['auto', 'on', 'off'], default='on')
    parser.add_argument('--output', required=True)
    acceptance(parser.parse_args())
