"""Tests for the backup freshness sentinel (src/functions/backup-trigger).

This function is the RPO tripwire. The alert policy watches for a log entry
whose message contains ``RPO_BREACH`` at severity >= ERROR, so the tests
assert on exactly that contract: the right message text, the right severity
and the right fields. A refactor that changes the message string would
silently break alerting in production — these tests make that loud.
"""

from datetime import datetime, timedelta, timezone

import pytest
from conftest import import_function

freshness = import_function("backup-trigger")

# The exact token the log-based metric filter matches on.
RPO_BREACH = "RPO_BREACH"


class FakeBlob:
    """Minimal stand-in for a GCS Blob."""

    def __init__(self, name, time_created):
        self.name = name
        self.time_created = time_created


class FakeStorageClient:
    """Stands in for google.cloud.storage.Client.

    The function calls list_blobs() on the CLIENT (not on a bucket
    object), so the fake mirrors that shape.
    """

    def __init__(self, blobs):
        self._blobs = blobs

    def list_blobs(self, bucket_name, prefix=None):
        assert bucket_name == "test-bucket"
        return [b for b in self._blobs if b.name.startswith(prefix or "")]


def _patch_client(monkeypatch, blobs):
    client = FakeStorageClient(blobs)
    monkeypatch.setattr(freshness.storage, "Client", lambda *a, **k: client)
    return client


def _hours_ago(hours):
    return datetime.now(timezone.utc) - timedelta(hours=hours)


def test_fresh_backup_logs_no_breach(monkeypatch, clean_env, log_sink):
    """A 2-hour-old backup under a 24h RPO target must NOT page anyone."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(
        monkeypatch,
        [FakeBlob("backups/app-20260101T020000Z.db.gz", _hours_ago(2))],
    )

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert RPO_BREACH not in entries[0]["message"]
    assert entries[0]["severity"] == "INFO"
    assert entries[0]["newest_object"] == "backups/app-20260101T020000Z.db.gz"
    assert entries[0]["age_hours"] == pytest.approx(2, abs=0.1)


def test_stale_backup_emits_rpo_breach(monkeypatch, clean_env, log_sink):
    """A 30-hour-old backup under a 24h RPO target MUST page."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(
        monkeypatch,
        [FakeBlob("backups/app-20260101T020000Z.db.gz", _hours_ago(30))],
    )

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert RPO_BREACH in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"
    assert entries[0]["rpo_max_hours"] == 24
    assert entries[0]["age_hours"] == pytest.approx(30, abs=0.1)


def test_no_backups_at_all_is_a_breach(monkeypatch, clean_env, log_sink):
    """An empty bucket is the worst case, not a healthy state."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(monkeypatch, [])

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert RPO_BREACH in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"
    assert entries[0]["bucket"] == "test-bucket"


def test_boundary_exactly_at_threshold_is_not_a_breach(
    monkeypatch, clean_env, log_sink
):
    """The comparison is strictly greater-than: exactly 24h still passes."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(
        monkeypatch,
        [FakeBlob("backups/app-20260101T020000Z.db.gz", _hours_ago(23.9))],
    )

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert RPO_BREACH not in entries[0]["message"]


def test_manifests_are_ignored(monkeypatch, clean_env, log_sink):
    """Only .db.gz artifacts count; .sha256 manifests are not backups."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(
        monkeypatch,
        [
            FakeBlob("backups/app-20260101T020000Z.db.gz.sha256", _hours_ago(1)),
            FakeBlob("backups/app-20260101T020000Z.db.gz", _hours_ago(3)),
        ],
    )

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert entries[0]["newest_object"] == "backups/app-20260101T020000Z.db.gz"


def test_newest_backup_wins_not_the_listed_first(
    monkeypatch, clean_env, log_sink
):
    """A stale backup listed first must not mask a fresh one."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    clean_env.setenv("RPO_MAX_HOURS", "24")
    _patch_client(
        monkeypatch,
        [
            FakeBlob("backups/app-old.db.gz", _hours_ago(100)),
            FakeBlob("backups/app-new.db.gz", _hours_ago(1)),
        ],
    )

    freshness.check_backup_freshness(None)

    entries = log_sink.read()
    assert entries[0]["newest_object"] == "backups/app-new.db.gz"
    assert RPO_BREACH not in entries[0]["message"]


def test_missing_bucket_env_is_a_hard_error(clean_env):
    """Without BACKUP_BUCKET the function cannot do its job — fail loudly."""
    with pytest.raises(KeyError):
        freshness.check_backup_freshness(None)
