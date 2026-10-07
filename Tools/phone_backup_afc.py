"""Read-only, bounded AFC copies through the paired app-container service."""

from __future__ import annotations

import ctypes as c
import os
import plistlib
import shutil
from pathlib import Path
from types import TracebackType
from typing import Protocol

from phone_shipping_core import BUNDLE_IDENTIFIER, Device, ShippingError

CHUNK_BYTES = 1024 * 1024


class FileReader(Protocol):
    def read(self, length: int) -> bytes: ...


def copy_exact(reader: FileReader, destination: Path, size: int) -> None:
    """A short read is progress, not EOF. Reject truncation and unexpected growth."""
    with destination.open("xb") as output:
        os.chmod(destination, 0o600)
        remaining = size
        while remaining:
            chunk = reader.read(min(CHUNK_BYTES, remaining))
            if not chunk or len(chunk) > remaining:
                raise ShippingError("AFC backup ended before the advertised file size.")
            output.write(chunk)
            remaining -= len(chunk)
        if reader.read(1):
            raise ShippingError("AFC backup file grew during the copy.")
        output.flush()
        os.fsync(output.fileno())


class AppContainer:
    """Use libimobiledevice already required by the shipping toolchain.

    Every remote file is opened AFC_FOPEN_RDONLY. No remote mutation API is bound.
    """

    def __init__(self, device: Device) -> None:
        executable = shutil.which("ideviceinfo")
        if executable is None:
            raise ShippingError("ideviceinfo is required for AFC backups.")
        library = Path(executable).resolve().parent.parent / "lib/libimobiledevice-1.0.dylib"
        try:
            self.api = c.CDLL(str(library))
        except OSError as error:
            raise ShippingError(f"Cannot load the paired-device AFC library: {error}") from error
        pointer = c.c_void_p
        signatures = {
            "idevice_new_with_options": [c.POINTER(pointer), c.c_char_p, c.c_int],
            "idevice_free": [pointer],
            "house_arrest_client_start_service": [pointer, c.POINTER(pointer), c.c_char_p],
            "house_arrest_send_command": [pointer, c.c_char_p, c.c_char_p],
            "house_arrest_get_result": [pointer, c.POINTER(pointer)],
            "house_arrest_client_free": [pointer],
            "afc_client_new_from_house_arrest_client": [pointer, c.POINTER(pointer)],
            "afc_client_free": [pointer],
            "afc_get_file_info": [pointer, c.c_char_p, c.POINTER(c.POINTER(c.c_char_p))],
            "afc_dictionary_free": [c.POINTER(c.c_char_p)],
            "afc_file_open": [pointer, c.c_char_p, c.c_int, c.POINTER(c.c_uint64)],
            "afc_file_read": [pointer, c.c_uint64, pointer, c.c_uint32, c.POINTER(c.c_uint32)],
            "afc_file_close": [pointer, c.c_uint64],
            "plist_to_xml": [pointer, c.POINTER(pointer), c.POINTER(c.c_uint32)],
            "plist_mem_free": [pointer],
            "plist_free": [pointer],
        }
        for name, arguments in signatures.items():
            function = getattr(self.api, name)
            function.argtypes = arguments
            function.restype = None if name in ("plist_mem_free", "plist_free") else c.c_int
        self.device = pointer()
        self.house = pointer()
        self.afc = pointer()
        self.file = c.c_uint64()
        try:
            # USB first, then network; the UDID always binds the selected phone.
            self.check(
                self.api.idevice_new_with_options(c.byref(self.device), device.udid.encode(), 6)
            )
            self.check(
                self.api.house_arrest_client_start_service(
                    self.device, c.byref(self.house), b"whoop-phone-backup"
                )
            )
            self.check(
                self.api.house_arrest_send_command(
                    self.house, b"VendContainer", BUNDLE_IDENTIFIER.encode()
                )
            )
            result = pointer()
            self.check(self.api.house_arrest_get_result(self.house, c.byref(result)))
            xml = pointer()
            length = c.c_uint32()
            try:
                self.check(self.api.plist_to_xml(result, c.byref(xml), c.byref(length)))
                response = plistlib.loads(c.string_at(xml, length.value))
                if response.get("Status") != "Complete":
                    raise ShippingError(
                        f"App-container service refused backup: {response.get('Error')}"
                    )
            finally:
                self.api.plist_mem_free(xml)
                self.api.plist_free(result)
            self.check(
                self.api.afc_client_new_from_house_arrest_client(self.house, c.byref(self.afc))
            )
        except BaseException:
            self.close()
            raise

    @staticmethod
    def check(code: int) -> None:
        if code != 0:
            raise ShippingError(f"Paired-device AFC backup failed (service code {code}).")

    def stat(self, name: str, *, required: bool) -> dict[str, str] | None:
        values = c.POINTER(c.c_char_p)()
        code = self.api.afc_get_file_info(self.afc, self.path(name), c.byref(values))
        if code == 8 and not required:  # AFC_E_OBJECT_NOT_FOUND; no other error is optional.
            return None
        self.check(code)
        try:
            result: dict[str, str] = {}
            index = 0
            while values[index]:
                result[values[index].decode()] = values[index + 1].decode()
                index += 2
            if result.get("st_ifmt") != "S_IFREG":
                raise ShippingError(f"Backup source {name} is not a regular file.")
            # Reads may update atime; allocated blocks can change without content.
            stable_keys = ("st_ifmt", "st_size", "st_mtime", "st_birthtime")
            if any(key not in result for key in stable_keys):
                raise ShippingError(f"AFC did not report stable metadata for {name}.")
            return {key: result[key] for key in stable_keys}
        finally:
            self.api.afc_dictionary_free(values)

    @staticmethod
    def path(name: str) -> bytes:
        if Path(name).name != name:
            raise ShippingError("Backup accepts only file names within the Sleep directory.")
        return f"Library/Application Support/Sleep/{name}".encode()

    def read(self, length: int) -> bytes:
        buffer = c.create_string_buffer(length)
        count = c.c_uint32()
        code = self.api.afc_file_read(self.afc, self.file, buffer, length, c.byref(count))
        if code == 14 and count.value == 0:  # AFC_E_END_OF_DATA is also an EOF response.
            return b""
        self.check(code)
        return buffer.raw[: count.value]

    def copy(self, name: str, destination: Path, metadata: dict[str, str]) -> None:
        self.check(self.api.afc_file_open(self.afc, self.path(name), 1, c.byref(self.file)))
        try:
            copy_exact(self, destination, int(metadata["st_size"]))
        finally:
            code = self.api.afc_file_close(self.afc, self.file)
            self.file = c.c_uint64()
            self.check(code)

    def close(self) -> None:
        if self.afc:
            self.api.afc_client_free(self.afc)
            self.afc = c.c_void_p()
        if self.house:
            self.api.house_arrest_client_free(self.house)
            self.house = c.c_void_p()
        if self.device:
            self.api.idevice_free(self.device)
            self.device = c.c_void_p()

    def __enter__(self) -> AppContainer:
        return self

    def __exit__(self, *_: type[BaseException] | BaseException | TracebackType | None) -> None:
        self.close()


def copy_snapshot(
    device: Device, root: Path, required: tuple[str, ...], optional: tuple[str, ...]
) -> None:
    with AppContainer(device) as container:
        before = {
            name: container.stat(name, required=name in required) for name in (*required, *optional)
        }
        for name, metadata in before.items():
            if metadata is not None:
                print(
                    f"Backing up {name} ({int(metadata['st_size']):,} bytes) through AFC",
                    flush=True,
                )
                container.copy(name, root / name, metadata)
        after = {name: container.stat(name, required=name in required) for name in before}
        if before != after:
            raise ShippingError("App files changed while suspended; AFC snapshot is not coherent.")
