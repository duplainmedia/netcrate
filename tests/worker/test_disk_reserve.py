# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import disk_reserve

class ReserveTests(unittest.TestCase):
    def test_resume_below_reserve_refused(self):
        with patch('disk_reserve.shutil.disk_usage') as usage:
            usage.return_value.free = 49 * 1024**3
            with self.assertRaisesRegex(RuntimeError, 'SSD reserve'):
                disk_reserve.assert_reserve(Path.cwd())

    def test_expansion_kills_active_writer(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'finished'
            command = [sys.executable, '-c', 'import time,pathlib;time.sleep(2);pathlib.Path(__import__("sys").argv[1]).touch()', str(marker)]
            with patch('disk_reserve.shutil.disk_usage') as usage:
                usage.side_effect = [type('Usage', (), {'free': 100 * 1024**3})(), type('Usage', (), {'free': 49 * 1024**3})()]
                with self.assertRaisesRegex(RuntimeError, 'SSD reserve'):
                    disk_reserve.run_guarded(command, Path(folder), capture_output=True, text=True)
            self.assertFalse(marker.exists())

if __name__ == '__main__':
    unittest.main()
