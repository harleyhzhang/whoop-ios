from __future__ import annotations

import subprocess
from pathlib import Path
from typing import IO, ClassVar

import phone_shipping_debugger as debugger
import pytest
from phone_shipping_core import Device, ShippingError


class Worker:
    ready_pid: int | None = 123
    confirms_detach = True
    times_out = False
    instances: ClassVar[list[Worker]] = []

    def __init__(self, arguments: list[str], *, stdout: IO[str], **kwargs: object) -> None:
        self.directory = Path(stdout.name).parent
        self.arguments = arguments
        self.killed = False
        self.instances.append(self)
        if self.ready_pid is not None:
            (self.directory / "ready").write_text(str(self.ready_pid))

    def poll(self) -> int | None:
        return 0 if self.ready_pid is None else None

    def wait(self, *, timeout: int) -> int:
        assert (self.directory / "release").exists()
        if self.times_out and not self.killed:
            raise subprocess.TimeoutExpired(self.arguments, timeout)
        if self.confirms_detach:
            (self.directory / "detached").write_text("123")
        return -9 if self.killed else 0

    def kill(self) -> None:
        self.killed = True


@pytest.fixture
def device() -> Device:
    return Device("CORE-1", "UDID-1", "phone", "iPhone", "27.0", "24A1", "")


@pytest.fixture(autouse=True)
def fake_worker(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("phone_shipping_debugger.subprocess.Popen", Worker)
    monkeypatch.setattr(Worker, "instances", [])
    monkeypatch.setattr(Worker, "ready_pid", 123)
    monkeypatch.setattr(Worker, "confirms_detach", True)
    monkeypatch.setattr(Worker, "times_out", False)


@pytest.mark.parametrize("copy_fails", [False, True])
def test_debugger_releases_and_detaches_even_when_copy_fails(
    tmp_path: Path, device: Device, copy_fails: bool
) -> None:
    def copy() -> None:
        with debugger.debugger_paused_application(device, tmp_path, 123):
            assert not (Worker.instances[0].directory / "release").exists()
            if copy_fails:
                raise RuntimeError("copy failed")

    if copy_fails:
        with pytest.raises(RuntimeError, match="copy failed"):
            copy()
    else:
        copy()
    arguments = Worker.instances[0].arguments
    assert "--no-lldbinit" in arguments
    assert "device select CORE-1" in arguments
    assert "device process attach --pid 123" in arguments


@pytest.mark.parametrize("ready_pid", [None, 999])
def test_no_copy_without_confirmation_of_expected_process(
    tmp_path: Path, device: Device, monkeypatch: pytest.MonkeyPatch, ready_pid: int | None
) -> None:
    monkeypatch.setattr(Worker, "ready_pid", ready_pid)
    with (
        pytest.raises(ShippingError, match=r"did not confirm|wrong process"),
        debugger.debugger_paused_application(device, tmp_path, 123),
    ):
        pytest.fail("Never copy without a confirmed paused process")


def test_success_exit_without_detach_receipt_fails_closed(
    tmp_path: Path, device: Device, monkeypatch: pytest.MonkeyPatch
) -> None:
    # LLDB may exit zero after a Python-command exception; exit status alone
    # cannot prove the app remained stopped or detached successfully.
    monkeypatch.setattr(Worker, "confirms_detach", False)
    with (
        pytest.raises(ShippingError, match="pause/detach failed"),
        debugger.debugger_paused_application(device, tmp_path, 123),
    ):
        pass


def test_unresponsive_debugger_is_killed_and_requires_collector_recovery(
    tmp_path: Path, device: Device, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(Worker, "times_out", True)
    with (
        pytest.raises(ShippingError, match="collector recovery required"),
        debugger.debugger_paused_application(device, tmp_path, 123),
    ):
        pass
    assert Worker.instances[0].killed
