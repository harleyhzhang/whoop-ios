from __future__ import annotations

import ctypes
import io
from pathlib import Path

import phone_backup_afc as afc
import pytest
from phone_shipping_core import Device, ShippingError


@pytest.mark.parametrize("size", [0, 1, afc.CHUNK_BYTES, afc.CHUNK_BYTES + 13])
def test_exact_copy_handles_final_partial_block(tmp_path: Path, size: int) -> None:
    contents = b"x" * size
    destination = tmp_path / "copy"
    afc.copy_exact(io.BytesIO(contents), destination, size)
    assert destination.read_bytes() == contents
    assert destination.stat().st_mode & 0o777 == 0o600


def test_short_read_is_progress_not_eof(tmp_path: Path) -> None:
    class ShortReader(io.BytesIO):
        def read(self, size: int | None = -1) -> bytes:
            return super().read(min(size if size is not None else 7, 7))

    afc.copy_exact(ShortReader(b"x" * 100), tmp_path / "copy", 100)
    assert (tmp_path / "copy").read_bytes() == b"x" * 100


@pytest.mark.parametrize(("contents", "size"), [(b"short", 6), (b"too long", 2)])
def test_copy_rejects_truncation_or_growth(tmp_path: Path, contents: bytes, size: int) -> None:
    with pytest.raises(ShippingError):
        afc.copy_exact(io.BytesIO(contents), tmp_path / "copy", size)


def test_copy_does_not_overwrite_existing_evidence(tmp_path: Path) -> None:
    destination = tmp_path / "copy"
    destination.write_bytes(b"original")
    with pytest.raises(FileExistsError):
        afc.copy_exact(io.BytesIO(b"new"), destination, 3)
    assert destination.read_bytes() == b"original"


@pytest.mark.parametrize("changed", [False, True])
def test_snapshot_checks_all_metadata_after_all_copies(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, changed: bool
) -> None:
    events: list[str] = []

    class Container:
        def __init__(self, _: Device) -> None:
            pass

        def __enter__(self) -> Container:
            return self

        def __exit__(self, *args: object) -> None:
            events.append("close")

        def stat(self, name: str, *, required: bool) -> dict[str, str] | None:
            events.append(f"stat:{name}")
            if name == "optional":
                assert not required
                return None
            assert required
            return {"st_size": "1", "st_mtime": "2" if changed and "copy:db" in events else "1"}

        def copy(self, name: str, destination: Path, metadata: dict[str, str]) -> None:
            events.append(f"copy:{name}")
            destination.write_bytes(b"x")

    monkeypatch.setattr(afc, "AppContainer", Container)
    selected = Device("core", "udid", "phone", "model", "27", "build", "")
    if changed:
        with pytest.raises(ShippingError, match="not coherent"):
            afc.copy_snapshot(selected, tmp_path, ("db",), ("optional",))
    else:
        afc.copy_snapshot(selected, tmp_path, ("db",), ("optional",))
    assert events == ["stat:db", "stat:optional", "copy:db", "stat:db", "stat:optional", "close"]


@pytest.mark.parametrize("name", ["../secret", "/absolute", "dir/file"])
def test_afc_rejects_outside_paths(name: str) -> None:
    with pytest.raises(ShippingError):
        afc.AppContainer.path(name)


@pytest.mark.parametrize("code", [0, 14, 4, 12, 30])
def test_native_read_accepts_only_eof_or_success(
    monkeypatch: pytest.MonkeyPatch, code: int
) -> None:
    from types import SimpleNamespace

    container = afc.AppContainer.__new__(afc.AppContainer)
    monkeypatch.setattr(
        container, "api", SimpleNamespace(afc_file_read=lambda *_: code), raising=False
    )
    monkeypatch.setattr(container, "afc", ctypes.c_void_p(), raising=False)
    monkeypatch.setattr(container, "file", ctypes.c_uint64(1), raising=False)
    if code in (0, 14):
        assert container.read(1) == b""
    else:
        with pytest.raises(ShippingError):
            container.read(1)


@pytest.mark.parametrize("code", [8, 4, 12, 30])
@pytest.mark.parametrize("required", [True, False])
def test_only_missing_optional_files_are_ignored(
    monkeypatch: pytest.MonkeyPatch, code: int, required: bool
) -> None:
    from types import SimpleNamespace

    container = afc.AppContainer.__new__(afc.AppContainer)
    monkeypatch.setattr(
        container, "api", SimpleNamespace(afc_get_file_info=lambda *_: code), raising=False
    )
    monkeypatch.setattr(container, "afc", ctypes.c_void_p(), raising=False)
    if code == 8 and not required:
        assert container.stat("db", required=False) is None
    else:
        with pytest.raises(ShippingError):
            container.stat("db", required=required)
