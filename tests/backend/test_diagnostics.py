import io
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

from backend import diagnostics


ROOT = Path(__file__).resolve().parents[2]


class DiagnosticsTests(unittest.TestCase):
    def run_child(self, directory, source):
        setup = "from pathlib import Path\nfrom backend import diagnostics\n"
        setup += f"diagnostics.LOG_DIR = Path({str(directory)!r})\n"
        return subprocess.run(
            [sys.executable, "-c", setup + textwrap.dedent(source)],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )

    def read_log(self, directory):
        logs = list(Path(directory).glob("llama-gui-*.log"))
        self.assertEqual(len(logs), 1)
        return logs[0].read_text(encoding="utf-8")

    def test_uncaught_exception_saved_and_console_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_child(directory, """
                diagnostics.initialize()
                import sys
                print('handled backend error', file=sys.stderr)
                raise RuntimeError('overnight failure')
            """)
            self.assertEqual(result.returncode, 1)
            log = self.read_log(directory)
            for text in ("handled backend error", "Traceback (most recent call last)",
                         "RuntimeError: overnight failure", "Python executable:"):
                self.assertIn(text, log)
                self.assertIn(text, result.stderr)
            self.assertRegex(log, r"\[\d{4}-\d{2}-\d{2}T.*\+00:00\]")

    def test_worker_exception_and_fatal_handler_without_console(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_child(directory, """
                import faulthandler
                import sys
                import threading
                sys.stderr = None
                diagnostics.initialize()
                assert faulthandler.is_enabled()
                def fail():
                    raise ValueError('worker failed')
                worker = threading.Thread(target=fail, name='test-worker')
                worker.start()
                worker.join()
                faulthandler.dump_traceback(file=sys.stderr, all_threads=True)
            """)
            self.assertEqual(result.returncode, 0, result.stderr)
            log = self.read_log(directory)
            self.assertIn("Exception in thread test-worker", log)
            self.assertIn("ValueError: worker failed", log)
            self.assertIn("Current thread", log)

    def test_entrypoints_capture_import_failure_before_app_startup(self):
        for entrypoint in ("server", "backend.app"):
            with self.subTest(entrypoint=entrypoint), tempfile.TemporaryDirectory() as directory:
                result = self.run_child(directory, f"""
                    import importlib.abc
                    import runpy
                    import sys
                    class BrokenImport(importlib.abc.MetaPathFinder):
                        def find_spec(self, fullname, path, target=None):
                            if fullname == 'backend.config':
                                raise ImportError('startup dependency failed')
                    sys.meta_path.insert(0, BrokenImport())
                    runpy.run_module({entrypoint!r}, run_name='__main__')
                """)
                self.assertEqual(result.returncode, 1)
                self.assertIn("ImportError: startup dependency failed", self.read_log(directory))

    def test_imports_have_no_logging_side_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_child(directory, """
                import sys
                before = sys.stderr
                import server
                assert sys.stderr is before
                assert diagnostics._session is None
            """)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_initialization_is_idempotent_and_retains_recent_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            for index in range(12):
                # Even a clock rollback must not prune the current, open log.
                (Path(directory) / f"llama-gui-29990101-000000-{index:06d}-1.log").write_text("old")
            unrelated = Path(directory) / "user.log"
            unrelated.write_text("keep")
            result = self.run_child(directory, """
                first = diagnostics.initialize()
                assert diagnostics.initialize() == first
                assert first.exists()
            """)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list(Path(directory).glob("llama-gui-*.log"))), 10)
            self.assertTrue(unrelated.exists())
            self.assertFalse((Path(directory) / "llama-gui-29990101-000000-000000-1.log").exists())

    def test_unwritable_log_directory_does_not_prevent_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            blocked = Path(directory) / "file"
            blocked.write_text("not a directory")
            result = self.run_child(blocked, """
                import sys
                before = sys.stderr
                assert diagnostics.initialize() is None
                assert sys.stderr is before
                print('startup continues')
            """)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Could not create crash log", result.stderr)
            self.assertIn("startup continues", result.stdout)

    def test_file_failure_does_not_hide_console_errors(self):
        console = io.StringIO()
        broken_file = mock.Mock()
        broken_file.write.side_effect = OSError("disk full")
        stream = diagnostics._DiagnosticStream(console, broken_file)
        self.assertEqual(stream.write("first error\n"), len("first error\n"))
        stream.write("second error\n")
        self.assertIn("Log write failed: disk full", console.getvalue())
        self.assertIn("first error\nsecond error", console.getvalue())
        self.assertEqual(broken_file.write.call_count, 1)

    def test_console_failure_does_not_prevent_logging(self):
        console = mock.Mock()
        console.write.side_effect = OSError("console closed")
        log = io.StringIO()
        stream = diagnostics._DiagnosticStream(console, log)
        stream.write("first error\n")
        stream.write("second error\n")
        self.assertIn("first error", log.getvalue())
        self.assertIn("Console output unavailable: console closed", log.getvalue())
        self.assertIn("second error", log.getvalue())
        self.assertEqual(console.write.call_count, 1)

    def test_native_crash_written_directly_to_log(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_child(directory, """
                import os
                import sys
                if sys.platform == 'win32':
                    import ctypes
                    ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002)
                else:
                    import resource
                    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
                diagnostics.initialize()
                os.abort()
            """)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Fatal Python error", self.read_log(directory))


if __name__ == "__main__":
    unittest.main()
