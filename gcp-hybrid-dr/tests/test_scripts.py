"""Tests for the shell scripts that implement the backup pipeline.

``backup.sh`` is the heart of the DR strategy: it takes a consistent
snapshot, verifies it, compresses it, checksums it and ships it. A silent
bug here means silent data loss, so the script is exercised against a REAL
SQLite database with a stubbed ``gcloud`` and ``curl`` on PATH.

The curl stub emulates the Cloud Storage JSON API closely enough to be
useful: it parses the multipart upload and VALIDATES the ``crc32c``
metadata field exactly as the real API does. That matters — a bug once
shipped in which the script computed zlib's IEEE CRC-32 (not CRC32C) and
sent it in an ``x-goog-hash`` header, which Cloud Storage does not
validate at all. A permissive stub would have hidden it; a validating
one catches it.
"""

import base64
import gzip
import hashlib
import os
import shutil
import sqlite3
import subprocess
import zlib
from datetime import datetime, timezone
from pathlib import Path

import pytest
from crc32c import crc32c

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "src" / "scripts"
STUBS = REPO_ROOT / "tests" / "stubs"


@pytest.fixture
def fake_gcloud(tmp_path, monkeypatch):
    """Install a stub `gcloud` and `curl` on PATH that record uploads locally.

    backup.sh uploads through the Cloud Storage JSON API (multipart) rather
    than ``gcloud storage cp`` — see the script's header for why — so the
    stub has to emulate both the ``gcloud auth application-default
    print-access-token`` call and the ``curl`` upload POST.

    The stub captures each uploaded object under
    ``<capture>/<bucket>/<object-name>`` so the test can inspect exactly
    what would have reached GCS.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    capture = tmp_path / "uploaded"

    # Both stubs live in the repo (tests/stubs/) so they can be read and
    # reviewed as part of the source rather than buried in a string.
    shutil.copy(STUBS / "gcloud_stub.sh", bindir / "gcloud")
    (bindir / "gcloud").chmod(0o755)
    shutil.copy(STUBS / "curl_stub.sh", bindir / "curl")
    (bindir / "curl").chmod(0o755)

    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    monkeypatch.setenv("DR_TEST_CAPTURE", str(capture))
    monkeypatch.setenv("DR_TEST_BUCKET", "test-bucket")
    monkeypatch.setenv("DR_TEST_STUB_PY", str(STUBS / "storage_upload_stub.py"))
    return capture


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "app.db"
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, order_ref TEXT, item TEXT,"
        " amount REAL, created_at TEXT)"
    )
    conn.executemany(
        "INSERT INTO orders (order_ref, item, amount, created_at)"
        " VALUES (?,?,?,?)",
        [
            ("ORD-1", "Anvil", 1.0, "2026-01-01T00:00:00+00:00"),
            ("ORD-2", "Skates", 2.0, "2026-01-01T00:00:01+00:00"),
        ],
    )
    conn.commit()
    conn.close()
    return path


def _run(script, env, extra_args=()):
    """Run a script from src/scripts with the given environment."""
    return subprocess.run(
        ["bash", str(SCRIPTS / script), *extra_args],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def _base_env(tmp_path, db_path, monkeypatch):
    env = dict(os.environ)
    env.update(
        {
            "BACKUP_BUCKET": "test-bucket",
            "DB_PATH": str(db_path),
            "BACKUP_PREFIX": "backups",
            "LOCK_FILE": str(tmp_path / "backup.lock"),
            "DR_BACKUP_ENV": str(tmp_path / "nonexistent.env"),
        }
    )
    return env


def _crc32c_of(path: Path) -> str:
    """The CRC32C of a file, base64 encoded — as the API expects it."""
    return base64.b64encode(crc32c(path.read_bytes()).to_bytes(4, "big")).decode()


def test_backup_creates_artifact_and_manifest(tmp_path, db_path, fake_gcloud):
    """A successful run uploads a .db.gz AND its .sha256 manifest."""
    env = _base_env(tmp_path, db_path, None)
    result = _run("backup.sh", env)

    assert result.returncode == 0, result.stderr

    artifacts = list(fake_gcloud.rglob("*.db.gz"))
    assert len(artifacts) == 1, f"expected one artifact, got {artifacts}"
    manifests = list(fake_gcloud.rglob("*.sha256"))
    assert len(manifests) == 1, f"expected one manifest, got {manifests}"

    # The manifest must actually verify against the uploaded artifact.
    digest = hashlib.sha256(artifacts[0].read_bytes()).hexdigest()
    assert digest in manifests[0].read_text()


def test_uploaded_artifact_is_a_valid_database(tmp_path, db_path, fake_gcloud):
    """The uploaded .db.gz must decompress to a healthy SQLite file.

    This is the property that matters: the thing in the bucket has to be a
    restorable database, not merely a file.
    """
    env = _base_env(tmp_path, db_path, None)
    result = _run("backup.sh", env)
    assert result.returncode == 0, result.stderr

    artifact = next(fake_gcloud.rglob("*.db.gz"))
    with gzip.open(artifact, "rb") as fh:
        data = fh.read()

    db_file = tmp_path / "restored.db"
    db_file.write_bytes(data)
    conn = sqlite3.connect(db_file)
    try:
        assert conn.execute("PRAGMA integrity_check;").fetchone()[0] == "ok"
        assert conn.execute("SELECT count(*) FROM orders;").fetchone()[0] == 2
    finally:
        conn.close()


def test_backup_refuses_invalid_bucket_name(tmp_path, db_path, fake_gcloud):
    """A malformed bucket name must fail before any upload happens."""
    env = _base_env(tmp_path, db_path, None)
    env["BACKUP_BUCKET"] = "Invalid Bucket Name!"
    result = _run("backup.sh", env)

    assert result.returncode != 0
    assert "invalid bucket name" in result.stderr.lower()
    assert not list(fake_gcloud.rglob("*.db.gz"))


def test_backup_fails_when_database_missing(tmp_path, fake_gcloud):
    """A missing database is a hard failure, not a silent no-op."""
    env = _base_env(tmp_path, tmp_path / "nope.db", None)
    result = _run("backup.sh", env)

    assert result.returncode != 0
    assert "not readable" in result.stderr.lower()
    assert not list(fake_gcloud.rglob("*.db.gz"))


def test_backup_fails_when_bucket_unset(tmp_path, db_path, fake_gcloud):
    """Without a bucket there is nowhere to ship the backup."""
    env = _base_env(tmp_path, db_path, None)
    env.pop("BACKUP_BUCKET")
    result = _run("backup.sh", env)

    assert result.returncode != 0
    assert "BACKUP_BUCKET" in result.stderr


def test_backup_timestamps_names_for_chronological_sort(
    tmp_path, db_path, fake_gcloud
):
    """Object names must sort lexicographically == chronologically.

    The restore drill and verify-backup.sh both pick the 'latest' backup
    by taking the max of a lexicographic sort, so the timestamp format
    has to be fixed-width and UTC.
    """
    env = _base_env(tmp_path, db_path, None)
    result = _run("backup.sh", env)
    assert result.returncode == 0, result.stderr

    artifact = next(fake_gcloud.rglob("*.db.gz"))
    stamp = artifact.name.removeprefix("app-").removesuffix(".db.gz")
    assert len(stamp) == 20, f"unexpected timestamp format: {stamp}"
    assert stamp.endswith("Z")
    # Parses as a real UTC timestamp. strptime has no %3N directive, so
    # the millisecond field is parsed separately.

    base = stamp[:-5]  # drop ".123Z"
    millis = stamp[-4:-1]
    assert millis.isdigit(), f"millisecond field must be numeric: {stamp!r}"
    # The name carries a UTC timestamp; the trailing "Z" is the marker.
    parsed = datetime.strptime(base, "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
    # ...and it must be within a couple of minutes of now (the test just ran).
    now = datetime.now(timezone.utc)
    assert abs((now - parsed).total_seconds()) < 120


def test_backup_names_do_not_collide_within_the_same_second(
    tmp_path, db_path, fake_gcloud
):
    """Two runs in the same second must NOT produce the same object name.

    The primary VM's service account holds only roles/storage.objectCreator
    — deliberately write-only, so it CANNOT overwrite an existing object.
    If two backups shared a name the second upload would fail with 403
    and silently cost an RPO window. Millisecond precision prevents it.
    """
    env = _base_env(tmp_path, db_path, None)
    assert _run("backup.sh", env).returncode == 0
    assert _run("backup.sh", env).returncode == 0

    artifacts = list(fake_gcloud.rglob("*.db.gz"))
    assert len(artifacts) == 2, f"expected two distinct artifacts, got {artifacts}"
    assert len({a.name for a in artifacts}) == 2, "artifact names must be unique"
    # Both must be valid GCS object names.
    for a in artifacts:
        assert a.name.startswith("app-") and a.name.endswith(".db.gz")


def test_backup_leaves_no_temp_files(tmp_path, db_path, fake_gcloud):
    """The working directory must be cleaned up on every exit path.

    backup.sh creates its workdir with `mktemp -d`, which lands in
    $TMPDIR (not the pytest tmp_path), so the check has to look there.
    """
    workdir = tmp_path / "work"
    workdir.mkdir()
    env = _base_env(tmp_path, db_path, None)
    env["TMPDIR"] = str(workdir)

    before = set(workdir.iterdir())
    result = _run("backup.sh", env)
    assert result.returncode == 0, result.stderr

    after = set(workdir.iterdir())
    leftovers = [p for p in after - before if p.is_dir()]
    assert not leftovers, f"backup.sh left temp dirs behind: {leftovers}"


def test_backup_is_idempotent_across_runs(tmp_path, db_path, fake_gcloud):
    """Re-running only ever ADDS a backup — it never overwrites one."""
    env = _base_env(tmp_path, db_path, None)
    assert _run("backup.sh", env).returncode == 0
    assert _run("backup.sh", env).returncode == 0

    artifacts = list(fake_gcloud.rglob("*.db.gz"))
    assert len(artifacts) == 2, f"expected two distinct artifacts, got {artifacts}"
    assert len({a.name for a in artifacts}) == 2, "artifact names must be unique"


# ---------------------------------------------------------------------------
# verify-backup.sh — the admin-side restore verification
# ---------------------------------------------------------------------------


def test_verify_backup_accepts_a_good_backup(tmp_path, db_path, fake_gcloud):
    """The verifier must PASS a backup produced by backup.sh.

    This is the script the README tells users to run to check their
    backups, so it has to be exercised end to end — not just against a
    stub that cannot list.
    """
    env = _base_env(tmp_path, db_path, None)
    assert _run("backup.sh", env).returncode == 0

    # verify-backup.sh talks to the bucket via `gcloud storage ls` and
    # `gcloud storage cp`; both are emulated by the stub, so the script
    # can be driven against the captured objects.
    result = _run("verify-backup.sh", env, extra_args=("test-bucket",))
    assert result.returncode == 0, result.stderr
    assert "checksum verified" in result.stdout
    assert "integrity_check ok" in result.stdout
    assert "2 order rows" in result.stdout


def test_verify_backup_rejects_a_corrupt_backup(tmp_path, db_path, fake_gcloud):
    """A tampered artifact must fail verification, not pass it."""
    env = _base_env(tmp_path, db_path, None)
    assert _run("backup.sh", env).returncode == 0

    # Corrupt the captured artifact so the checksum no longer matches.
    artifact = next(fake_gcloud.rglob("*.db.gz"))
    artifact.write_bytes(b"corrupted")

    result = _run("verify-backup.sh", env, extra_args=("test-bucket",))
    assert result.returncode != 0


def test_verify_backup_rejects_empty_bucket_name(tmp_path, db_path):
    """A bogus bucket name is rejected before any network call."""
    env = _base_env(tmp_path, db_path, None)
    result = _run("verify-backup.sh", env, extra_args=("BAD BUCKET",))
    assert result.returncode != 0
    assert "invalid bucket name" in result.stderr.lower()


def test_verify_backup_requires_a_bucket_argument(tmp_path, db_path):
    """Called with no argument it must explain itself, not guess."""
    env = _base_env(tmp_path, db_path, None)
    env.pop("BACKUP_BUCKET")
    result = _run("verify-backup.sh", env)
    assert result.returncode == 2
    assert "usage" in result.stderr.lower()


# ---------------------------------------------------------------------------
# The upload checksum — the one that shipped broken once
# ---------------------------------------------------------------------------


def test_crc32c_matches_the_standard_check_vector():
    """CRC32C("123456789") == 0xe3069283 — the standard test vector.

    If this is wrong, every checksum the project sends is wrong.
    """
    assert crc32c(b"123456789") == 0xE3069283
    # ...and it is demonstrably NOT zlib's IEEE CRC-32.
    assert zlib.crc32(b"123456789") & 0xFFFFFFFF == 0xCBF43926


def test_backup_uploads_with_a_validated_crc32c(tmp_path, db_path, fake_gcloud):
    """The upload must carry a REAL CRC32C that GCS would validate.

    Regression guard for a bug that shipped once: the upload sent
    zlib's crc32 (IEEE 802.3) under the name "crc32c", and in the
    x-goog-hash HEADER, which Cloud Storage does not validate at all.
    The correct algorithm is CRC32C (Castagnoli), and it must be sent
    in the request METADATA for GCS to check it.
    """
    env = _base_env(tmp_path, db_path, None)
    result = _run("backup.sh", env)
    assert result.returncode == 0, result.stderr

    artifact = next(fake_gcloud.rglob("*.db.gz"))
    # The stub validated the checksum on the way through (it rejects a
    # mismatch exactly as the API does), so reaching here means the
    # script sent a correct CRC32C.
    assert "crc32c" in result.stdout
    assert _crc32c_of(artifact) != base64.b64encode(
        (zlib.crc32(artifact.read_bytes()) & 0xFFFFFFFF).to_bytes(4, "big")
    ).decode()


def test_backup_fails_when_the_checksum_is_wrong(
    tmp_path, db_path, fake_gcloud, monkeypatch
):
    """A wrong CRC32C must fail the upload, not be silently accepted.

    The stub emulates the real API: it recomputes the checksum and
    rejects a mismatch, exactly as storage.googleapis.com does for the
    `crc32c` metadata field.
    """
    env = _base_env(tmp_path, db_path, None)

    # Make the script's inline checksum computation return a wrong value.
    # The script pipes the file path to `python3 -`, so the stub only
    # needs to recognise "read a file and print a checksum" and return
    # a deliberately wrong one.
    stub_python = tmp_path / "bin" / "python3"
    stub_python.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "${1:-}" == "-" ]]; then\n'
        "  echo 'AAAAAA=='\n"
        "  exit 0\n"
        "fi\n"
        "exec /usr/bin/python3 \"$@\"\n"
    )
    stub_python.chmod(0o755)
    monkeypatch.setenv("PATH", f"{stub_python.parent}:{env['PATH']}")

    result = _run("backup.sh", env)
    assert result.returncode != 0, "a wrong checksum must fail the upload"
    assert "failed" in result.stderr.lower()


# ---------------------------------------------------------------------------
# disaster-drill.sh — the RTO measurement harness
# ---------------------------------------------------------------------------


def test_disaster_drill_requires_project(tmp_path):
    """Without a project the drill must refuse to run."""
    env = dict(os.environ)
    env.pop("TF_VAR_project_id", None)
    result = _run("disaster-drill.sh", env)

    assert result.returncode == 2
    assert "--project" in result.stderr


def test_disaster_drill_rejects_unknown_flags(tmp_path):
    """Typos in flags must not be silently ignored."""
    env = dict(os.environ)
    env["TF_VAR_project_id"] = "test-project"
    result = _run("disaster-drill.sh", env, extra_args=("--nonsense",))

    assert result.returncode == 2
    assert "unknown argument" in result.stderr.lower()


def test_disaster_drill_help_exits_zero(tmp_path):
    """--help prints usage and exits 0."""
    env = dict(os.environ)
    result = _run("disaster-drill.sh", env, extra_args=("--help",))
    assert result.returncode == 0
    assert "disaster drill" in result.stdout.lower()
