"""Backup freshness sentinel (Cloud Function, 2nd gen, Pub/Sub-triggered).

Design decision (documented in JOURNEY.md Day 3): the original plan had a
Cloud Function SSH into the VM to *run* the backup. That needs SSH keys or
OS Login credentials inside a function — a bigger attack surface than the
problem it solves. The simpler honest design used here:

  - The backup itself runs ON the VM via cron at 02:00 UTC (backup.sh).
  - Cloud Scheduler (03:00 UTC) publishes to a Pub/Sub topic.
  - This function lists the backup bucket and checks the newest backup's
    age against the RPO target. If breached (or no backups exist), it
    emits a structured ERROR log containing "RPO_BREACH", which a
    log-based metric + Cloud Monitoring alert policy turns into an email.

The function's service account holds only roles/storage.objectViewer on
the backup bucket (bucket-level) — read-only, nothing else.
"""

import json
import os
from datetime import datetime, timezone

import functions_framework
from google.cloud import storage


def _log(severity: str, message: str, **fields) -> None:
    """Structured log entry — Cloud Logging parses JSON on stdout."""
    entry = {"severity": severity, "message": message}
    entry.update(fields)
    print(json.dumps(entry))


@functions_framework.cloud_event
def check_backup_freshness(cloud_event):
    """Entry point. The Pub/Sub payload is ignored — it is only a tick."""
    bucket_name = os.environ["BACKUP_BUCKET"]
    prefix = os.environ.get("BACKUP_PREFIX", "backups/")
    rpo_max_hours = float(os.environ.get("RPO_MAX_HOURS", "24"))

    client = storage.Client()
    # Stream the listing rather than materialising it: with an hourly
    # cadence and 30-day retention this bucket holds ~720 objects, and
    # the function only needs the newest one. Materialising the whole
    # list would grow without bound against a 256M memory limit.
    newest = None
    for blob in client.list_blobs(bucket_name, prefix=prefix):
        if not blob.name.endswith(".db.gz"):
            continue
        if newest is None or blob.time_created > newest.time_created:
            newest = blob

    if newest is None:
        _log(
            "ERROR",
            "RPO_BREACH: no backups found at all",
            bucket=bucket_name,
            prefix=prefix,
            rpo_max_hours=rpo_max_hours,
        )
        return

    age_hours = (
        datetime.now(timezone.utc) - newest.time_created
    ).total_seconds() / 3600.0

    if age_hours > rpo_max_hours:
        _log(
            "ERROR",
            f"RPO_BREACH: newest backup is {age_hours:.1f}h old "
            f"(limit {rpo_max_hours:.0f}h)",
            bucket=bucket_name,
            newest_object=newest.name,
            age_hours=round(age_hours, 1),
            rpo_max_hours=rpo_max_hours,
        )
    else:
        _log(
            "INFO",
            f"backup fresh: {newest.name} is {age_hours:.1f}h old "
            f"(limit {rpo_max_hours:.0f}h)",
            bucket=bucket_name,
            newest_object=newest.name,
            age_hours=round(age_hours, 1),
        )
