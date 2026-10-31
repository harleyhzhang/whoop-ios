"""Bounded reconstruction of WHOOP format-1 frames from retained notifications."""

from __future__ import annotations

import hashlib
import struct
import zlib


def header_crc(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc


class NotificationFrames:
    def __init__(self) -> None:
        self.streams: dict[str, tuple[bytes, list[str], float]] = {}

    def feed(self, channel: str, packet: bytes, received: float) -> list[tuple[bytes, list[str]]]:
        if len(packet) > 4096:
            self.streams.clear()
            return []
        if channel not in self.streams and len(self.streams) >= 4:
            self.streams.clear()
        data, hashes, last = self.streams.get(channel, (b"", [], received))
        if received - last > 2 or received < last or len(hashes) >= 256:
            data, hashes = b"", []
        data += packet
        hashes = [*hashes, hashlib.sha256(packet).hexdigest()]
        frames = []
        while len(data) >= 8:
            if (
                data[:2] != b"\xaa\x01"
                or header_crc(data[:6]) != struct.unpack_from("<H", data, 6)[0]
            ):
                data = data[1:]
                continue
            declared = struct.unpack_from("<H", data, 2)[0]
            size = declared + 8
            if not 16 <= size <= 4096 or (declared - 4) % 4:
                data = data[1:]
                continue
            if len(data) < size:
                break
            frame = data[:size]
            if zlib.crc32(frame[8:-4]) != struct.unpack_from("<I", frame, size - 4)[0]:
                data = data[1:]
                continue
            frames.append((frame, hashes))
            data = data[size:]
            hashes = [] if not data else hashes[-1:]
        self.streams[channel] = (data, hashes, received)
        return frames
