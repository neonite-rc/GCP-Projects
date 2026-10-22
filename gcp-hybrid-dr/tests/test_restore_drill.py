"""Tests for the automated restore drill (src/functions/restore-drill).

"A backup you haven't restored is a hope, not a backup." The drill is the
proof, and the alert policy watches for a log entry containing
``RESTORE_DRILL_FAIL`` at severity >= ERROR.

These tests exercise the full verification chain against a REAL gzip + sha256
+ SQLite fixture (not a mock of it), so the assertions cover the actual
failure modes: corrupt checksum, truncated gzip, and a structurally damaged
SQLite file.
"""

import gzip
import hashlib

from conftest import import_function

drill = import_function("restore-drill")

DRILL_FAIL = "RESTORE_DRILL_FAIL"
DRILL_PASS = "RESTORE_DRILL_PASS"


class FakeBlob:
    def __init__(self, name, time_created, path=None):
        self.name = name
        self.time_created = time_created
        self._path = path

    def download_to_filename(self, dest):
        if self._path is None:
            raise FileNotFoundError(f"no local copy for {self.name}")
        with open(self._path, "rb") as src, open(dest, "wb") as dst:
            dst.write(src.read())


class FakeBucket:
    def __init__(self, blobs):
        self._blobs = {b.name: b for b in blobs}

    def blob(self, name):
        return self._blobs[name]


class FakeClient:
    def __init__(self, blobs):
        self._blobs = blobs

    def list_blobs(self, bucket_name, prefix=None):
        return [b for b in self._blobs if b.name.startswith(prefix or "")]

    def bucket(self, bucket_name):
        return FakeBucket(self._blobs)


def _patch_client(monkeypatch, blobs):
    client = FakeClient(blobs)
    monkeypatch.setattr(drill.storage, "Client", lambda *a, **k: client)
    return client


def _blob(name, path):
    from datetime import datetime, timezone

    return FakeBlob(name, datetime.now(timezone.utc), path)


def test_valid_backup_passes(monkeypatch, clean_env, log_sink, gzip_db):
    """The happy path: correct checksum, intact gzip, healthy SQLite."""
    gz_path, manifest = gzip_db
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-20260101T020000Z.db.gz", gz_path),
            _blob("backups/app-20260101T020000Z.db.gz.sha256", manifest),
        ],
    )

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_PASS in entries[0]["message"]
    assert entries[0]["severity"] == "INFO"
    assert entries[0]["order_rows"] == 3


def test_checksum_mismatch_fails_the_drill(
    monkeypatch, clean_env, log_sink, gzip_db
):
    """A tampered artifact must fail the drill, not silently pass it."""
    gz_path, manifest = gzip_db
    manifest.write_text(f"{'0' * 64}  {gz_path.name}\n", encoding="utf-8")
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-20260101T020000Z.db.gz", gz_path),
            _blob("backups/app-20260101T020000Z.db.gz.sha256", manifest),
        ],
    )

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_FAIL in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"
    assert "checksum mismatch" in entries[0]["message"]


def test_missing_manifest_fails_the_drill(
    monkeypatch, clean_env, log_sink, gzip_db
):
    """No manifest means no integrity proof — that is a failure, not a skip."""
    gz_path, _ = gzip_db
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch, [_blob("backups/app-20260101T020000Z.db.gz", gz_path)]
    )

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_FAIL in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"


def test_truncated_gzip_fails_the_drill(
    monkeypatch, clean_env, log_sink, gzip_db
):
    """A half-written object fails during decompression."""
    gz_path, manifest = gzip_db
    data = gz_path.read_bytes()
    gz_path.write_bytes(data[: len(data) // 2])
    # Re-checksum so the failure is attributed to gzip, not the checksum.
    digest = hashlib.sha256(gz_path.read_bytes()).hexdigest()
    manifest.write_text(f"{digest}  {gz_path.name}\n", encoding="utf-8")
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-20260101T020000Z.db.gz", gz_path),
            _blob("backups/app-20260101T020000Z.db.gz.sha256", manifest),
        ],
    )

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_FAIL in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"


def test_corrupt_sqlite_fails_integrity_check(
    monkeypatch, clean_env, log_sink, tmp_path
):
    """A valid gzip + valid checksum but a damaged database must still fail.

    This is the case checksum-only verification would miss: the bytes
    arrived intact, but the database inside them is garbage.
    """
    broken = tmp_path / "broken.db"
    broken.write_bytes(b"this is definitely not a sqlite database" * 40)
    gz_path = tmp_path / "app-broken.db.gz"
    with open(broken, "rb") as src, gzip.open(gz_path, "wb") as dst:
        dst.write(src.read())
    manifest = tmp_path / "app-broken.db.gz.sha256"
    digest = hashlib.sha256(gz_path.read_bytes()).hexdigest()
    manifest.write_text(f"{digest}  {gz_path.name}\n", encoding="utf-8")

    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-broken.db.gz", gz_path),
            _blob("backups/app-broken.db.gz.sha256", manifest),
        ],
    )

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_FAIL in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"


def test_empty_bucket_fails_the_drill(monkeypatch, clean_env, log_sink):
    """No backups at all must page someone, not report a vacuous pass."""
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(monkeypatch, [])

    drill.run_restore_drill(None)

    entries = log_sink.read()
    assert len(entries) == 1
    assert DRILL_FAIL in entries[0]["message"]
    assert entries[0]["severity"] == "ERROR"


def test_drill_cleans_up_its_workdir(monkeypatch, clean_env, log_sink, gzip_db):
    """The function must not leave decrypted data lying in /tmp."""
    import tempfile

    gz_path, manifest = gzip_db
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-20260101T020000Z.db.gz", gz_path),
            _blob("backups/app-20260101T020000Z.db.gz.sha256", manifest),
        ],
    )

    before = set(tempfile.gettempdir())
    drill.run_restore_drill(None)
    after = set(tempfile.gettempdir())

    leaked = [
        p
        for p in after - before
        if p.startswith("restore-drill-") and "tmp" not in p
    ]
    assert not leaked, f"drill leaked temp dirs: {leaked}"


def test_drill_returns_row_count_on_success(
    monkeypatch, clean_env, log_sink, gzip_db
):
    """The internal helper returns the row count it verified."""
    gz_path, manifest = gzip_db
    clean_env.setenv("BACKUP_BUCKET", "test-bucket")
    _patch_client(
        monkeypatch,
        [
            _blob("backups/app-20260101T020000Z.db.gz", gz_path),
            _blob("backups/app-20260101T020000Z.db.gz.sha256", manifest),
        ],
    )

    rows = drill._drill("test-bucket", "backups/")
    assert rows == 3
