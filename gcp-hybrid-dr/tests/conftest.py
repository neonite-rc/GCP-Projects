"""Shared pytest fixtures and helpers for the Cloud Function test suite.

The three functions in ``src/functions/`` are deployed as separate Cloud
Function units, so each one is importable only after its own directory is on
``sys.path``. ``import_function`` below does that without requiring the
directories to be packages.
"""

import json
import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = REPO_ROOT / "src" / "functions"


def import_function(name: str):
    """Load a Cloud Function module by directory name under src/functions.

    Each function directory contains a ``main.py``. They are loaded by
    absolute path under a unique module name (``fn_backup_trigger`` etc.)
    so that all three can coexist in one pytest session — importing them
    all as ``main`` would make the first one win.
    """
    import importlib.util

    module_name = f"fn_{name.replace('-', '_')}"
    if module_name in sys.modules:
        return sys.modules[module_name]

    path = FUNCTIONS_DIR / name / "main.py"
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class LogSink:
    """Captures the structured JSON log lines a function prints to stdout.

    The functions log via ``print(json.dumps(entry))`` so Cloud Logging
    parses them as structured entries. Tests assert on the decoded fields
    rather than on raw strings, which keeps them honest about the shape the
    alerting rules actually match on (e.g. ``jsonPayload.message``).
    """

    def __init__(self, capsys):
        self._capsys = capsys
        self.entries: list[dict] = []

    def read(self) -> list[dict]:
        out = self._capsys.readouterr().out
        self.entries = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                self.entries.append(json.loads(line))
            except json.JSONDecodeError:
                # Non-JSON stdout would break the log-based metric filters.
                raise AssertionError(f"function wrote non-JSON to stdout: {line!r}")
        return self.entries

    def messages(self) -> list[str]:
        return [e.get("message", "") for e in self.read()]


@pytest.fixture
def log_sink(capsys):
    return LogSink(capsys)


@pytest.fixture
def cloud_event():
    """Build a CloudEvent shaped like Eventarc's Pub/Sub delivery.

    Eventarc wraps the Pub/Sub payload one level deeper than the
    functions-framework examples suggest: the alert JSON lives at
    ``cloud_event.data["message"]["data"]`` as base64 (see JOURNEY.md
    Day 9). Tests build the same shape so a regression in that unwrapping
    is caught.
    """

    def _make(payload: dict | str):
        raw = payload if isinstance(payload, str) else json.dumps(payload)
        import base64

        return type(
            "FakeCloudEvent",
            (),
            {
                "data": {
                    "message": {
                        "data": base64.b64encode(raw.encode()).decode(),
                        "attributes": {},
                    }
                }
            },
        )()

    return _make


@pytest.fixture
def clean_env(monkeypatch):
    """Remove inherited env vars that would leak into function behaviour."""

    for key in (
        "BACKUP_BUCKET",
        "BACKUP_PREFIX",
        "RPO_MAX_HOURS",
        "PROJECT_ID",
        "MANAGED_ZONE",
        "RECORD_NAME",
        "RECORD_TTL",
        "PRIMARY_IP",
        "DR_RRDATAS",
    ):
        monkeypatch.delenv(key, raising=False)
    return monkeypatch


@pytest.fixture
def temp_db(tmp_path):
    """Create a small SQLite DB matching the primary app's schema."""

    import sqlite3

    path = tmp_path / "app.db"
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE orders (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               order_ref TEXT NOT NULL UNIQUE,
               item TEXT NOT NULL,
               amount REAL NOT NULL,
               created_at TEXT NOT NULL
           )"""
    )
    conn.executemany(
        "INSERT INTO orders (order_ref, item, amount, created_at) VALUES (?,?,?,?)",
        [
            ("ORD-1001", "Anvil, 50kg", 129.00, "2026-01-01T00:00:00+00:00"),
            ("ORD-1002", "Rocket skates", 79.50, "2026-01-01T00:00:01+00:00"),
            ("ORD-1003", "Giant rubber band", 12.25, "2026-01-01T00:00:02+00:00"),
        ],
    )
    conn.commit()
    conn.close()
    return path


@pytest.fixture
def gzip_db(temp_db):
    """A gzip-compressed copy of the fixture DB plus its sha256 manifest.

    Mirrors exactly what ``src/scripts/backup.sh`` uploads: the compressed
    artifact and a ``.sha256`` manifest naming the compressed file.
    """

    import gzip
    import hashlib
    import shutil

    gz_path = temp_db.with_suffix(".db.gz")
    with open(temp_db, "rb") as src, gzip.open(gz_path, "wb") as dst:
        shutil.copyfileobj(src, dst)

    digest = hashlib.sha256(gz_path.read_bytes()).hexdigest()
    manifest = temp_db.with_suffix(".db.gz.sha256")
    manifest.write_text(f"{digest}  {gz_path.name}\n", encoding="utf-8")
    return gz_path, manifest


# Keep the repo's own src/ on the path for ruff/pytest consistency.
os.environ.setdefault("PYTHONHASHSEED", "0")
