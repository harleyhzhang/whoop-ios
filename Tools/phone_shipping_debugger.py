"""Hold a development-signed app stopped while an AFC snapshot is read."""

from __future__ import annotations

import subprocess
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from phone_shipping_core import Device, ShippingError

ATTACH_TIMEOUT = 60
DETACH_TIMEOUT = 30
SNAPSHOT_TIMEOUT = 1200


def debugger_script(directory: Path, pid: int) -> str:
    return f"""
import lldb, pathlib, time
root = pathlib.Path({str(directory)!r})
deadline = time.monotonic() + {ATTACH_TIMEOUT}
while True:
    process = lldb.debugger.GetSelectedTarget().GetProcess()
    if process.GetState() == lldb.eStateStopped:
        break
    if process.GetState() in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
        raise RuntimeError('Snapshot debugger could not stop the app')
    if time.monotonic() >= deadline:
        raise RuntimeError('Snapshot debugger attach timed out')
    time.sleep(0.1)
if process.GetProcessID() != {pid}:
    raise RuntimeError('Snapshot debugger attached to the wrong process')
(root / 'ready').write_text(str(process.GetProcessID()))
deadline = time.monotonic() + {SNAPSHOT_TIMEOUT}
while not (root / 'release').exists():
    if process.GetState() != lldb.eStateStopped:
        raise RuntimeError('App stopped being paused during snapshot')
    if time.monotonic() >= deadline:
        raise RuntimeError('Snapshot debugger hold timed out')
    time.sleep(0.1)
if process.GetState() != lldb.eStateStopped:
    raise RuntimeError('App stopped being paused before snapshot release')
error = process.Detach()
if not error.Success():
    raise RuntimeError('Snapshot debugger detach failed: ' + str(error))
(root / 'detached').write_text(str(process.GetProcessID()))
"""


def debugger_failure(directory: Path, message: str) -> ShippingError:
    detail = (directory / "lldb.log").read_text(errors="replace")[-2000:]
    return ShippingError(message + ("\n" + detail if detail else ""))


@contextmanager
def debugger_paused_application(device: Device, scratch: Path, pid: int) -> Iterator[None]:
    """Require an attached debugger's stop, then detach on every exit path.

    CoreDevice's start-stopped launch alone does not hold a running collector
    paused for a whole multi-gigabyte transfer. A debugger stop also prevents
    lifecycle watchdog kills. File-length/metadata and SQLite checks still run.
    """
    with tempfile.TemporaryDirectory(prefix="snapshot-debugger-", dir=scratch) as temporary:
        directory = Path(temporary)
        with (directory / "lldb.log").open("w") as log:
            worker = subprocess.Popen(
                [
                    "xcrun",
                    "lldb",
                    "--no-lldbinit",
                    "--batch",
                    "-o",
                    f"device select {device.identifier}",
                    "-o",
                    f"device process attach --pid {pid}",
                    "-o",
                    f"script exec({debugger_script(directory, pid)!r})",
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + ATTACH_TIMEOUT
                while not (directory / "ready").exists():
                    if worker.poll() is not None or time.monotonic() >= deadline:
                        raise debugger_failure(
                            directory, "Snapshot debugger did not confirm a stopped app."
                        )
                    time.sleep(0.1)
                if (directory / "ready").read_text() != str(pid):
                    raise debugger_failure(
                        directory, "Snapshot debugger confirmed the wrong process."
                    )
                yield
            finally:
                (directory / "release").touch()
                try:
                    status = worker.wait(timeout=DETACH_TIMEOUT)
                except subprocess.TimeoutExpired as error:
                    worker.kill()
                    worker.wait(timeout=5)
                    raise ShippingError(
                        "Snapshot debugger did not detach; collector recovery required."
                    ) from error
                if status != 0 or not (directory / "detached").exists():
                    raise debugger_failure(
                        directory, "Snapshot debugger pause/detach failed; refusing the snapshot."
                    )
