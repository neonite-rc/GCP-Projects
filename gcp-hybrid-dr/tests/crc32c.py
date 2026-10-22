"""CRC32C (Castagnoli) — the checksum Cloud Storage validates.

Python's stdlib has no CRC32C. ``zlib.crc32`` is the IEEE 802.3
polynomial (0xEDB88320), which is a DIFFERENT function with DIFFERENT
values — sending that under the name "crc32c" is a bug that GCS's
``crc32c`` metadata validation catches immediately.

The implementation below is the standard table-driven Castagnoli
version, and is checked against the canonical test vector
crc32c("123456789") == 0xe3069283.
"""

from __future__ import annotations

_POLY = 0x82F63B78  # Castagnoli, reflected

_TABLE: list[int] = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (_POLY if _c & 1 else 0)
    _TABLE.append(_c)


def crc32c(data: bytes) -> int:
    """Return the CRC32C of ``data`` as an unsigned 32-bit int."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF
