"""Check real process measurements without loading a model or native library."""
import sys
import threading
import unittest

from test_engine import process_resources


@unittest.skipUnless(sys.platform == 'win32' or sys.platform.startswith('linux'),
                     'Desktop acceptance targets Linux and Windows')
class ProcessResourceTests(unittest.TestCase):
    def test_counts_real_threads_and_working_set(self):
        before = process_resources()
        self.assertGreater(before[0], 0)
        self.assertGreater(before[1], 0)
        stop = threading.Event()
        threads = [threading.Thread(target=stop.wait) for _ in range(8)]
        try:
            for thread in threads:
                thread.start()
            during = process_resources()
            self.assertGreaterEqual(during[0], before[0] + len(threads))
            self.assertGreater(during[1], 0)
        finally:
            stop.set()
            for thread in threads:
                thread.join()
        self.assertLessEqual(process_resources()[0], before[0] + 1)


if __name__ == '__main__':
    unittest.main()
