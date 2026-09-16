"""Automatic, per-process diagnostics, initialized only when starting the app."""

from datetime import datetime, timezone
import faulthandler
import os
from pathlib import Path
import sys
import threading


LOG_DIR = Path(__file__).resolve().parents[1] / "logs"
LOG_RETENTION = 10
_session = None


def _console_write(console, text):
    if console is not None:
        try:
            console.write(text)
            console.flush()
        except (OSError, ValueError) as exc:
            # Detached restarts can inherit an unusable console. The file still
            # receives diagnostics; a broken terminal must not break the app.
            return exc
    return None


class _DiagnosticStream:
    def __init__(self, console, log_file):
        self.console = console
        self.log_file = log_file
        self.lock = threading.RLock()
        self.line_start = True
        self.failed = False

    def write(self, text):
        with self.lock:
            if not self.failed:
                try:
                    for part in text.splitlines(keepends=True):
                        if self.line_start:
                            stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
                            self.log_file.write(f"[{stamp}] ")
                        self.log_file.write(part)
                        self.line_start = part.endswith(("\n", "\r"))
                    self.log_file.flush()
                except (OSError, ValueError) as exc:
                    self.failed = True
                    _console_write(self.console, f"[diagnostics] Log write failed: {exc}\n")
            console_error = _console_write(self.console, text)
            if console_error is not None:
                self.console = None
                self.write(f"\n[diagnostics] Console output unavailable: {console_error}\n")
        return len(text)

    def flush(self):
        # Each write already flushes both destinations, including partial lines.
        return None

    def fileno(self):
        return self.log_file.fileno()

    def isatty(self):
        return False

    @property
    def encoding(self):
        return "utf-8"


def initialize():
    """Keep stderr and fatal tracebacks after exit, without changing exit codes.

    Python's default main-thread, worker-thread, unraisable-exception and HTTP
    server handlers already print to stderr, so their full tracebacks are saved
    without replacing exception hooks. Keep the file open for the entire process
    lifetime: faulthandler retains its descriptor, including during finalization.
    """
    global _session
    if _session is not None:
        return Path(_session.log_file.name)

    console = sys.stderr
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        log_path = LOG_DIR / f"llama-gui-{stamp}-{os.getpid()}.log"
        log_file = log_path.open("x", encoding="utf-8", errors="backslashreplace")
    except OSError as exc:
        _console_write(console, f"[diagnostics] Could not create crash log: {exc}\n")
        return None

    _session = _DiagnosticStream(console, log_file)
    sys.stderr = _session
    print(f"[diagnostics] Crash log: {log_path}", file=sys.stderr)
    print(f"[diagnostics] PID {os.getpid()}; Python {sys.version}; platform {sys.platform}", file=sys.stderr)
    print(f"[diagnostics] Python executable: {sys.executable}", file=sys.stderr)
    try:
        faulthandler.enable(file=log_file, all_threads=True)
    except (OSError, RuntimeError) as exc:
        print(f"[diagnostics] Could not enable native fault tracebacks: {exc}", file=sys.stderr)

    # Never rotate the current file: native fault reporting needs a stable FD.
    # Unique names also keep overlapping restarts from writing into one file.
    try:
        previous_logs = (path for path in LOG_DIR.glob("llama-gui-*.log") if path != log_path)
        old_logs = sorted(previous_logs, reverse=True)[LOG_RETENTION - 1:]
        for old_log in old_logs:
            try:
                old_log.unlink()
            except OSError as exc:
                print(f"[diagnostics] Could not remove old log {old_log.name}: {exc}", file=sys.stderr)
    except OSError as exc:
        print(f"[diagnostics] Could not list old logs: {exc}", file=sys.stderr)
    return log_path
