"""Automated restore drill (Cloud Function, 2nd gen, Pub/Sub-triggered).

"A backup you haven't restored is a hope, not a backup." The freshness
sentinel proves backups are RECENT; this drill proves they are USABLE:

    Cloud Scheduler (weekly) -> Pub/Sub -> this function:
      1. download the newest app-*.db.gz + its sha256 manifest
      2. verify the checksum
      3. decompress and open the SQLite file
      4. PRAGMA integrity_check + row count on the orders table
      5. emit RESTORE_DRILL_PASS (INFO) or RESTORE_DRILL_FAIL (ERROR)

RESTORE_DRILL_FAIL feeds a log-based metric + alert policy (same pattern
as RPO_BREACH), so a silently-corrupt backup pages a human instead of
being discovered during an actual disaster.

IAM: the function's SA holds only roles/storage.objectViewer on the
backup bucket — read-only, nothing else.
"""

import gzip
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone

import functions_framework
from google.cloud import storage


def _log(severity: str, message: str, **fields) -> None:
    entry = {"severity": severity, "message": message}
    entry.update(fields)
    print(json.dumps(entry))


def _drill(bucket_name: str, prefix: str) -> int:
    """Run the full drill. Returns order-row count on success; raises on any failure."""
    workdir = tempfile.mkdtemp(prefix="restore-drill-")
    try:
        client = storage.Client()
        # Stream the listing instead of materialising it — the drill only
        # needs the newest backup, and the bucket grows with the retention
        # window (an hourly cadence over 30 days is ~720 objects).
        newest = None
        for blob in client.list_blobs(bucket_name, prefix=prefix):
            if not blob.name.endswith(".db.gz"):
                continue
            if newest is None or blob.time_created > newest.time_created:
                newest = blob

        if newest is None:
            raise RuntimeError(f"no backups found at gs://{bucket_name}/{prefix}")

        manifest_name = f"{newest.name}.sha256"

        gz_path = os.path.join(workdir, os.path.basename(newest.name))
        man_path = os.path.join(workdir, "manifest.sha256")
        blob = client.bucket(bucket_name).blob(newest.name)
        blob.download_to_filename(gz_path)
        client.bucket(bucket_name).blob(manifest_name).download_to_filename(man_path)

        # 1. Checksum against the manifest written by backup.sh
        with open(man_path, encoding="utf-8") as fh:
            expected = fh.read().split()[0].strip()
        actual = hashlib.sha256()
        with open(gz_path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                actual.update(chunk)
        if actual.hexdigest() != expected:
            raise RuntimeError(
                f"checksum mismatch for {newest.name}: "
                f"manifest {expected} != actual {actual.hexdigest()}"
            )

        # 2. Decompress
        db_path = gz_path[: -len(".gz")]
        with gzip.open(gz_path, "rb") as src, open(db_path, "wb") as dst:
            shutil.copyfileobj(src, dst)

        # 3. SQLite integrity + real query
        conn = sqlite3.connect(db_path)
        try:
            integrity = conn.execute("PRAGMA integrity_check;").fetchone()[0]
            if integrity != "ok":
                raise RuntimeError(f"integrity_check failed: {integrity}")
            rows = conn.execute("SELECT count(*) FROM orders;").fetchone()[0]
        finally:
            conn.close()

        age_hours = (
            datetime.now(timezone.utc) - newest.time_created
        ).total_seconds() / 3600.0

        _log(
            "INFO",
            "RESTORE_DRILL_PASS: newest backup downloaded, checksum verified, "
            "gzip intact, integrity ok",
            bucket=bucket_name,
            object=newest.name,
            order_rows=rows,
            age_hours=round(age_hours, 1),
        )
        return rows

    finally:
        shutil.rmtree(workdir, ignore_errors=True)


@functions_framework.cloud_event
def run_restore_drill(cloud_event):
    """Entry point. The Pub/Sub payload is ignored — it is only a tick."""
    bucket_name = os.environ["BACKUP_BUCKET"]
    prefix = os.environ.get("BACKUP_PREFIX", "backups/")
    try:
        _drill(bucket_name, prefix)
    except Exception as exc:  # noqa: BLE001 — every failure mode must page
        _log("ERROR", f"RESTORE_DRILL_FAIL: {exc}", bucket=bucket_name)
