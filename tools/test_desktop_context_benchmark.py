"""Fast acceptance-tool checks; no model or native library is required."""
import threading
import sys
import subprocess
import unittest
from unittest.mock import patch

import desktop_context_benchmark as benchmark


class AcceptanceToolTests(unittest.TestCase):
    def test_long_inference_timeout_is_an_explicit_cli_setting(self):
        result = subprocess.run([sys.executable, benchmark.__file__, '--help'],
                                capture_output=True, text=True, check=True)
        self.assertIn('--timeout-seconds', result.stdout)

    @unittest.skipUnless(sys.platform == 'win32' or sys.platform.startswith('linux'),
                         'Desktop acceptance targets Linux and Windows')
    def test_queries_the_real_process_working_set(self):
        self.assertGreater(benchmark.memory_snapshot()['rss_bytes'], 0)

    def test_sampling_failure_reaches_the_acceptance_caller(self):
        calls = iter([{'rss_bytes': 4096, 'threads': 1}, OSError('resource query failed')])

        def snapshot():
            result = next(calls)
            if isinstance(result, Exception):
                raise result
            return result

        with patch.object(benchmark, 'memory_snapshot', side_effect=snapshot), \
                patch.object(threading, 'excepthook'):
            with self.assertRaisesRegex(OSError, 'resource query failed'):
                with benchmark.Peaks() as peaks:
                    peaks.thread.join(2)

    def test_cached_tokens_must_be_present_and_positive(self):
        for usage in ({'prompt_tokens': 100},
                      {'prompt_tokens': 100, 'prompt_tokens_details': {'cached_tokens': 0}},
                      {'prompt_tokens': 100, 'prompt_tokens_details': {'cached_tokens': 101}}):
            with self.subTest(usage=usage), self.assertRaises(AssertionError):
                benchmark.verify_prefix_reuse({'usage': usage})

    def test_actual_cached_prefix_is_accepted(self):
        benchmark.verify_prefix_reuse({'usage': {
            'prompt_tokens': 120, 'prompt_tokens_details': {'cached_tokens': 100}}})


if __name__ == '__main__':
    unittest.main()
