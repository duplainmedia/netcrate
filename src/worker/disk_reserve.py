# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
"""Pause media jobs before consuming the Windows system drive reserve."""
import shutil
import subprocess

RESERVE = 50 * 1024**3
# Stop at 51 GiB to allow for writes between half-second samples.
STOP_AT = RESERVE + 1024**3

def assert_reserve(path):
    if shutil.disk_usage(path).free < STOP_AT:
        raise RuntimeError('SSD reserve reached; job retained for retry after space is available.')

def run_guarded(args, storage_path, **kwargs):
    on_poll=kwargs.pop('on_poll',None)
    assert_reserve(storage_path)
    capture = kwargs.pop('capture_output', False)
    if capture:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with subprocess.Popen(args, **kwargs) as child:
        try:
            while True:
                try:
                    stdout, stderr = child.communicate(timeout=0.5)
                    if on_poll:
                        try:on_poll()
                        except Exception:pass
                    assert_reserve(storage_path)
                    return subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
                except subprocess.TimeoutExpired:
                    assert_reserve(storage_path)
                    if on_poll:
                        try:on_poll()
                        except Exception:pass
        except BaseException:
            child.kill()
            child.communicate()
            raise
