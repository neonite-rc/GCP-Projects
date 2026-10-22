"""Parses a Cloud Storage JSON API multipart upload and validates it.

Used by the `curl` stub in tests/stubs/curl_stub.sh. It emulates the
real API's behaviour that matters for this project:

  * the ``crc32c`` metadata field IS validated — a mismatch is a 400;
  * the ``x-goog-hash`` header is NOT validated (the real API silently
    ignores a wrong checksum sent that way).

That asymmetry is the reason the backup script sends the checksum in
the metadata rather than as a header.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.parse

# crc32c.py lives one directory up (tests/), not next to this stub.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from crc32c import crc32c


def _split_multipart(body: bytes) -> tuple[dict, bytes]:
    """Return (metadata_dict, payload_bytes) from a multipart body.

    Parsed by BOUNDARY OFFSETS, not by splitting on "\\r\\n--" — the
    payload is gzip-compressed binary that can contain those bytes, and
    a naive split corrupts it. (It did, which made the checksum
    mismatch and looked like a bug in the upload path.)

    The payload is everything up to the CRLF that precedes the closing
    boundary — the CRLF belongs to the boundary, not to the content, and
    the real API treats it that way.
    """
    delimiter = b"--dr-backup-boundary"
    meta: dict = {}
    payload = b""

    # Split into the raw chunks between boundaries.
    chunks = body.split(delimiter)
    for chunk in chunks[1:]:
        # The final chunk is the epilogue ("--\r\n"), skip it.
        if chunk.startswith(b"--"):
            break
        # Strip the CRLF after the boundary and the CRLF before the next
        # one; what remains is one part's headers + body.
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        head, sep, rest = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        if b"application/json" in head:
            raw = rest.rsplit(b"\r\n", 1)[0]
            try:
                meta = json.loads(raw)
            except json.JSONDecodeError:
                meta = {}
        elif b"application/octet-stream" in head:
            # The trailing CRLF belongs to the boundary.
            if rest.endswith(b"\r\n"):
                rest = rest[:-2]
            payload = rest

    return meta, payload


def main() -> None:
    body_path, bucket, capture = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(body_path, "rb") as fh:
        body = fh.read()

    meta, payload = _split_multipart(body)
    # The API stores the DECODED object name — the script URL-encodes it
    # on the wire, and the real service decodes it before storing.
    name = urllib.parse.unquote(meta.get("name", ""))

    # The `crc32c` metadata field is validated by Cloud Storage.
    declared = meta.get("crc32c")
    if declared:
        actual = base64.b64encode(crc32c(payload).to_bytes(4, "big")).decode()
        if actual != declared:
            print(
                json.dumps(
                    {
                        "error": {
                            "code": 400,
                            "message": (
                                f'Provided CRC32C "{declared}" doesn\'t match '
                                f'calculated CRC32C "{actual}".'
                            ),
                        }
                    }
                )
            )
            return

    dest = os.path.join(capture, bucket, name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as out:
        out.write(payload)

    print(
        json.dumps(
            {
                "kind": "storage#object",
                "name": name,
                "bucket": bucket,
                "size": len(payload),
                "crc32c": base64.b64encode(crc32c(payload).to_bytes(4, "big")).decode(),
            }
        )
    )


if __name__ == "__main__":
    main()
