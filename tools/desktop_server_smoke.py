#!/usr/bin/env python3
"""Default-name CLI consumer smoke; intentionally never passes --library."""
import argparse
import http.client
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import urllib.error
import urllib.request
import urllib.parse


def main(args):
    directory = str(Path(args.library_directory).resolve())
    env = dict(os.environ)
    key = 'PATH' if os.name == 'nt' else 'LD_LIBRARY_PATH'
    env[key] = directory + os.pathsep + env.get(key, '')
    log = open(args.log, 'w')
    command = [args.dart, 'run', 'lib_llama_cpp_server', '--model-path', args.model,
        '--ctx-size', '4096', '--gpu-layers', '0', '--backend', 'cpu', '--threads', '8',
        '--threads-batch', '8', '--batch-size', '256', '--ubatch-size', '128', '--port', '0']
    # CPU cancellation is serviced between logical prefill batches. Use the
    # documented interactive CPU configuration; keep the 15s recovery deadline.
    process = subprocess.Popen(command, cwd=args.package_root, env=env,
        stdout=log, stderr=log, text=True)
    result = {'command': command, 'library_lookup': 'platform default name', 'checks': []}
    try:
        address = None
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            match = re.search(r'listening on (http://[^\s]+)', Path(args.log).read_text(errors='replace'))
            if match:
                address = match.group(1)
                break
            if process.poll() is not None:
                break
            time.sleep(.05)
        assert address, f'CLI failed readiness within 120s ({process.poll()}); see {args.log}'
        def post(body, timeout=20):
            request = urllib.request.Request(address + '/v1/chat/completions',
                json.dumps(body).encode(), {'Content-Type': 'application/json'})
            return urllib.request.urlopen(request, timeout=timeout)
        body = {'messages': [{'role': 'user', 'content': 'Reply with the word ready.'}],
            'max_tokens': 32, 'temperature': 0, 'chat_template_kwargs': {'enable_thinking': False}}
        response = json.load(post(body))
        assert response['choices'][0]['message']['content'].strip(), response
        result['checks'].append('default-name load and non-stream inference')
        raw = post(dict(body, stream=True)).read().decode()
        events = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith('data: {')]
        assert 'data: [DONE]' in raw and any(c.get('finish_reason') for e in events for c in e['choices']), raw
        assert any(c.get('delta', {}).get('content') or c.get('delta', {}).get('reasoning_content')
                   for e in events for c in e['choices']), raw
        result['checks'].append('stream actual payload, finish reason, DONE')
        for invalid, code in [(dict(body, repeat_last_n=-2), 'invalid_request'),
                              (dict(body, max_tokens=4096), 'context_overflow')]:
            try:
                post(invalid)
                raise AssertionError('invalid request accepted')
            except urllib.error.HTTPError as error:
                value = json.load(error)
                assert error.code == 400 and value['error']['code'] == code, (error.code, value)
        result['checks'].append('invalid request and overflow return HTTP 400')
        # A fresh long prefix ensures this request spends time in prefill on CPU.
        uri = urllib.parse.urlparse(address)
        connection = http.client.HTTPConnection(uri.hostname, uri.port, timeout=15)
        long_body = dict(body, stream=True, messages=[{'role': 'user', 'content': 'New prefill probe. ' + 'ordinary notes ' * 1500}])
        connection.request('POST', '/v1/chat/completions', json.dumps(long_body), {'Content-Type': 'application/json'})
        stream = connection.getresponse()  # Receives the heartbeat during prefill.
        stream.close()
        connection.close()
        started = time.monotonic()
        response = json.load(post(body, timeout=15))
        assert response['choices'][0]['message']['content'].strip(), response
        result['disconnect_recovery_seconds'] = time.monotonic() - started
        result['checks'].append('prefill client disconnect followed immediately by valid inference')
        result['status'] = 'passed'
    except BaseException as error:
        result.update(status='failed', error=repr(error))
        raise
    finally:
        try:
            if process.poll() is None:
                process.send_signal(signal.SIGINT if os.name != 'nt' else signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                result.update(status='failed', shutdown='failed to exit within 30 seconds')
                raise RuntimeError(result['shutdown'])
            result['shutdown'] = ('SIGTERM process termination; graceful native cleanup is tested separately'
                if os.name == 'nt' else 'SIGINT graceful shutdown')
            result['exit_code'] = process.returncode
        finally:
            log.close()
            Path(args.output).write_text(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--package-root', default='.')
    parser.add_argument('--model', required=True)
    parser.add_argument('--library-directory', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--output', required=True)
    main(parser.parse_args())
