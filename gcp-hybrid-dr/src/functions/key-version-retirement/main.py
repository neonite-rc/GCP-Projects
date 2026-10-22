"""Key version retirement (Cloud Function, 2nd gen, Scheduler-triggered).

Why this exists
---------------
Cloud KMS bills **$0.06 per month per active key version**, and a
version is active while it is Enabled, Disabled, *or* Scheduled for
destruction.

Rotating a key creates a new primary version but does **not** disable
or destroy the previous one, and nothing does it automatically.
Measured on a scratch key with a 1-day rotation period:

    after one rotation:  version 1 ENABLED, version 2 ENABLED
                         -> BOTH billed

With a 90-day rotation period that is one extra billed version every 90
days, forever: ~13 versions per key after a year, $0.78/mo per key,
$1.56/mo across the two keys — against a $0.12/mo figure in the cost
table. A slow, invisible cost leak in a project whose whole pitch is
cost control.

``destroy_scheduled_duration`` is **not** the fix. It only controls how
long a version stays in DESTROY_SCHEDULED after something has
explicitly destroyed it; it does not schedule anything on rotation.

What this function does
-----------------------
Monthly, it finds key versions that are:

  * **not** the current primary version,
  * **superseded** for longer than the backup retention window,

and destroys them.

The second condition is the subtle one, and getting it wrong destroys
data. A version's CREATE time is when it became primary; what matters is
when it STOPPED being primary — the moment its successor was created.
A version created 90 days ago may have been primary until yesterday, and
the backups written in that window are still restorable, so destroying
it would make them permanently unreadable. A version is therefore only
retired once `now > superseded_at + retention_window`.

(An earlier version of this function used the create time directly and
did exactly that: it destroyed the version still encrypting every live
backup. The 30-day soft-delete window is the only reason that was
recoverable.)

IAM: the function's SA holds ``roles/cloudkms.admin`` on the two key
rings this project owns. It is a dedicated principal, not the runtime
SAs of the other functions.
"""

import json
import os
from datetime import datetime, timedelta, timezone

import functions_framework
from google.cloud import kms

# How many days a version must have been superseded before it is
# retired. Set to the backup retention window: the oldest backup that
# must still be restorable is exactly that old, so a version younger
# than this could still be needed to decrypt a live backup.
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))

# The keyrings to sweep, as "projects/<project>/locations/<loc>/keyRings/<name>".
KEYRING_NAMES = [
    n.strip()
    for n in os.environ.get("KEYRINGS", "").split(",")
    if n.strip()
]

# Key version state constants (the API uses these numbers).
_STATE_DESTROY_SCHEDULED = 3


def _log(severity: str, message: str, **fields) -> None:
    """Structured log entry — Cloud Logging parses JSON on stdout."""
    entry = {"severity": severity, "message": message}
    entry.update(fields)
    print(json.dumps(entry))


def _retirable_versions(client, keyring_name: str, now: datetime):
    """Yield (name, state) for versions that are safe to destroy.

    `keyring_name` is a fully-qualified keyring resource name:
    "projects/<p>/locations/<l>/keyRings/<name>".

    THE CRITICAL RULE
    -----------------
    A key version is safe to destroy only when **every object encrypted
    with it has already expired**.

    A version's CREATE time is when it became primary, not when it
    stopped being primary. A version created 90 days ago may have been
    primary until yesterday, and the backups written in that window are
    still inside the retention window — destroying it would make them
    permanently unreadable.

    So the age that matters is the SUPERSESSION time: the moment the
    NEXT version was created, the previous one stopped being primary.
    A version is retirable only once
    ``now > superseded_at + retention_window``.

    Getting this wrong is not theoretical. An earlier version of this
    function used the create time directly, and it destroyed a version
    that was still the one encrypting every live backup — every one of
    them became unreadable ("Cloud KMS key is disabled, destroyed, or
    scheduled to be destroyed"). The 30-day soft-delete window is what
    made that recoverable; there is no second chance in production.

    The primary version is identified from the KEY: `key.primary` is a
    CryptoKeyVersion OBJECT, not a name, so its `.name` is what has to
    be compared. The list API has no per-version "is primary" flag, and
    asking for one is rejected with
    "Unknown field for ListCryptoKeyVersionsRequest".
    """
    for key in client.list_crypto_keys(request={"parent": keyring_name}):
        primary_version = getattr(key, "primary", None)
        primary_name = getattr(primary_version, "name", None)

        versions = list(
            client.list_crypto_key_versions(
                request={"parent": key.name, "view": "FULL"}
            )
        )
        # Oldest first, so each version's successor is the next one.
        versions.sort(key=lambda v: v.create_time or datetime.min.replace(tzinfo=timezone.utc))

        for index, version in enumerate(versions):
            # Never touch the primary version — destroying it would break
            # every subsequent write.
            if primary_name and version.name == primary_name:
                continue
            # A version already scheduled for destruction is on its way
            # out and costs nothing more to leave alone.
            if version.state == _STATE_DESTROY_SCHEDULED:
                continue
            created = version.create_time
            if created is None:
                continue

            # When did this version stop being primary? The successor's
            # creation. The newest non-primary version has no successor
            # in the list, which means it was superseded by a version
            # that is not visible to us — treat it as superseded now,
            # which is the safe direction (it earns the full window).
            if index + 1 < len(versions):
                superseded_at = versions[index + 1].create_time
            else:
                superseded_at = now

            if superseded_at is None:
                continue

            if now > superseded_at + timedelta(days=RETENTION_DAYS):
                yield version.name, version.state


def retire(project_id: str) -> int:
    """Destroy every retired key version. Returns the number destroyed."""
    client = kms.KeyManagementServiceClient()
    now = datetime.now(timezone.utc)

    destroyed = 0
    for keyring_name in KEYRING_NAMES:
        # KEYRINGS already holds fully-qualified keyring resource names
        # ("projects/<p>/locations/<l>/keyRings/<name>"). Prefixing the
        # project again would produce
        # "projects/<p>/locations/projects/<p>/locations/..." and the API
        # rejects it with a 400.
        full = keyring_name
        if not full.startswith("projects/"):
            full = f"projects/{project_id}/locations/{keyring_name}"
        for version_name, state in _retirable_versions(client, full, now):
            try:
                client.destroy_crypto_key_version(
                    request={"name": version_name}
                )
                destroyed += 1
                _log(
                    "INFO",
                    "KEY_VERSION_RETIRED: superseded key version destroyed",
                    version=version_name,
                    previous_state=state,
                    retention_days=RETENTION_DAYS,
                )
            except Exception as exc:  # noqa: BLE001 — one failure must not
                # stop the sweep of the remaining versions
                _log(
                    "ERROR",
                    f"KEY_VERSION_RETIRE_FAILED: {exc}",
                    version=version_name,
                )
    return destroyed


@functions_framework.cloud_event
def run_key_version_retirement(cloud_event):
    """Entry point. The Scheduler payload is ignored — it is only a tick."""
    project_id = os.environ["PROJECT_ID"]

    if not KEYRING_NAMES:
        _log(
            "ERROR",
            "KEY_VERSION_RETIRE_CONFIG: no keyrings configured — nothing to sweep",
            project=project_id,
        )
        return

    try:
        destroyed = retire(project_id)
    except Exception as exc:  # noqa: BLE001 — the failure must be visible
        _log("ERROR", f"KEY_VERSION_RETIRE_FAILED: {exc}", project=project_id)
        return

    _log(
        "INFO",
        "KEY_VERSION_RETIRE_PASS: retired superseded key versions",
        project=project_id,
        destroyed=destroyed,
        retention_days=RETENTION_DAYS,
        keyrings=len(KEYRING_NAMES),
    )
