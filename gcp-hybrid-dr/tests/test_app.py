"""Tests for the primary site's Flask app.

The failover decision rests entirely on this app's /health endpoint: if
it reports healthy when the database is broken, the DR site never gets
traffic, and the whole "health checks must verify the full stack"
lesson from JOURNEY.md Day 5 is lost.

These tests also cover the HTML escaping on the public page — the
endpoint is reachable from 0.0.0.0/0 and the schema is designed for
user-supplied orders.
"""

import importlib.util
import sqlite3
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
APP_PATH = REPO_ROOT / "src" / "app" / "app.py"


def _load_app():
    """Load the app module with a temp database path.

    The module reads DR_DB_PATH at import time, so it has to be set
    before the import.
    """
    spec = importlib.util.spec_from_file_location("dr_app", APP_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["dr_app"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def app_module(tmp_path, monkeypatch):
    """Import the app against a fresh SQLite database."""
    db_path = tmp_path / "app.db"
    monkeypatch.setenv("DR_DB_PATH", str(db_path))

    module = _load_app()
    module.init_db()

    # A Flask test client.
    module.app.config["TESTING"] = True
    with module.app.test_client() as client:
        yield module, client


def test_health_reports_ok_with_a_working_database(app_module):
    """A healthy site must answer 200 — the failover trigger depends on it."""
    _module, client = app_module
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
    assert resp.get_json()["site"] == "primary"


def test_health_reports_503_when_the_database_is_broken(app_module, tmp_path):
    """A web server fronting a dead database must NOT report healthy.

    This is the single most important behaviour in the app: the uptime
    check probes /health, and if that returns 200 with a broken
    database, the DR site never receives traffic.
    """
    module, client = app_module

    # Break the database: replace the file with something that is not a
    # database at all.
    Path(module.DB_PATH).write_bytes(b"this is not a sqlite database")

    resp = client.get("/health")
    assert resp.status_code == 503
    assert resp.get_json()["status"] == "unhealthy"


def test_health_reports_503_when_the_database_is_missing(app_module):
    """A deleted database is also a failure, not a healthy site."""
    module, client = app_module
    Path(module.DB_PATH).unlink()
    resp = client.get("/health")
    assert resp.status_code == 503


def test_index_lists_the_orders(app_module):
    """The page must actually render the data it claims to serve."""
    _module, client = app_module
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    assert "ORD-1001" in body
    assert "Anvil, 50kg" in body


def test_index_escapes_untrusted_values(app_module):
    """Order values must be HTML-escaped before they reach the page.

    The endpoint is public and the schema is designed for user-supplied
    orders, so an unescaped value would be a stored-XSS hole.
    """
    module, client = app_module

    conn = sqlite3.connect(module.DB_PATH)
    conn.execute(
        "INSERT INTO orders (order_ref, item, amount, created_at)"
        " VALUES (?,?,?,?)",
        (
            "ORD-XSS",
            "<script>alert('xss')</script>",
            1.0,
            "2026-01-01T00:00:00+00:00",
        ),
    )
    conn.commit()
    conn.close()

    body = client.get("/").get_data(as_text=True)
    assert "<script>alert('xss')</script>" not in body
    assert "&lt;script&gt;" in body


def test_init_db_is_idempotent(app_module):
    """Re-initialising must not duplicate the seed rows."""
    module, _client = app_module
    module.init_db()
    module.init_db()

    conn = sqlite3.connect(module.DB_PATH)
    try:
        count = conn.execute("SELECT count(*) FROM orders").fetchone()[0]
    finally:
        conn.close()
    assert count == 5, "the seed data should be inserted exactly once"
