"""DNS failover automation (Cloud Function, 2nd gen, Pub/Sub-triggered).

What this does
--------------
    uptime check /health  ->  primary_down alert (monitoring.tf)
      -> Pub/Sub notification channel (this module's topic)
        -> this function rewrites the zone's public record:
             incident OPEN   -> DR target  (the Cloud Run standby)
             incident CLOSED -> primary target (the on-prem VM)

Why a CNAME and not an A record
--------------------------------
The public record is a CNAME that points at a *hostname*:

    app.dr-demo.example.com.  CNAME -> primary.dr-demo.example.com.
                                            (A record -> the VM's static IP)
                                            ...or -> <dr-service>.a.run.app
                                            (the Cloud Run standby)

Two reasons this is better than rewriting A records directly:

1. The failover target is a NAME, so it never goes stale. Google's Cloud Run
   front-end IPs rotate; an A record pinned to last month's IPs is a broken
   record. A CNAME to `*.a.run.app` always resolves to something live.
2. The record TYPE never changes, so there is no A<->CNAME conflict and no
   window where the name has no usable record. The zone goes from "points at
   the primary" to "points at the standby" in ONE atomic DNS change.

It also means failover works WITHOUT buying a domain: a Cloud DNS zone is
authoritative for its own name, and its nameservers answer queries for
anyone who asks them directly (`dig @ns-cloud-a1.googledomains.com
app.dr-demo.example.com`). Registration is only needed for real-world
public resolution.

Safety rules
------------
* No DR target configured  -> refuse to act, log FAILOVER_TARGET_MISSING.
  Blanking the public record would turn a partial outage into a total one.
* DR health probe fails    -> refuse to act, log FAILOVER_ABORTED.
  Failing over into an unreachable standby is worse than staying down.
* Unknown incident state   -> leave the record alone.

IAM: the function's SA holds a project-level CUSTOM role
(``drFailoverDnsAdmin``) with only these permissions:

    dns.resourceRecordSets.{create,delete,get,list,update}
    dns.changes.{create,get,list}
    dns.managedZones.{get,list}

It cannot create or delete zones, cannot touch IAM policies, and cannot
affect any other project.

Why not a predefined role: ``roles/dns.resourceRecordsAdmin`` — the
obvious choice — DOES NOT EXIST on GCP. The IAM API 404s it, and Cloud
DNS's setIamPolicy accepts the binding and then stores an EMPTY policy,
so the function looks correctly permissioned and can do nothing at all.
``roles/dns.admin`` does work at the project level but also grants zone
create/delete and IAM mutation — far more than a failover function needs.
"""

import base64
import json
import os
import urllib.error
import urllib.request

import functions_framework
from googleapiclient import discovery

# How long to wait for the DR health probe before giving up.
HEALTH_PROBE_TIMEOUT = 10


def _log(severity: str, message: str, **fields) -> None:
    """Structured log entry — Cloud Logging parses JSON on stdout."""
    entry = {"severity": severity, "message": message}
    entry.update(fields)
    print(json.dumps(entry))


def _dns_service():
    return discovery.build(
        "dns", "v1", cache_discovery=False, cache=None
    )


def _split_targets(raw: str) -> list[str]:
    """Split a comma-separated env value into a clean list of targets.

    Each target is normalised to a bare DNS name: no scheme, no path,
    and a trailing dot. Being defensive here matters — Cloud DNS rejects
    a CNAME whose rdata still carries "https://" with a 400, and a
    mis-configured target must not take the whole failover path down.
    """
    targets = []
    for item in (raw or "").split(","):
        item = item.strip()
        if not item:
            continue
        # Strip a scheme if one was (incorrectly) configured.
        if "://" in item:
            item = item.split("://", 1)[1]
        # Strip any path.
        item = item.split("/", 1)[0]
        if not item:
            continue
        # A CNAME target is a fully-qualified name.
        if not item.endswith("."):
            item += "."
        targets.append(item)
    return targets


def _probe_health(url: str) -> tuple[bool, str]:
    """Check that the DR target actually answers.

    Returns (ok, detail). detail is a short reason for the log line.
    """
    request = urllib.request.Request(url, method="GET")
    request.add_header("User-Agent", "gcp-hybrid-dr-dns-failover/1.0")
    try:
        with urllib.request.urlopen(request, timeout=HEALTH_PROBE_TIMEOUT) as resp:
            if 200 <= resp.status < 300:
                return True, f"HTTP {resp.status}"
            return False, f"HTTP {resp.status}"
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return False, f"unreachable: {exc}"


def _set_records(project, managed_zone, record_name, record_type, ttl, targets):
    """Replace the RRset at record_name with targets (no-op if already equal).

    Returns True when a DNS change was submitted, False when the record
    already pointed where we want it.
    """
    service = _dns_service()
    resp = (
        service.resourceRecordSets()
        .list(
            project=project,
            managedZone=managed_zone,
            name=record_name,
            type=record_type,
        )
        .execute()
    )
    existing = resp.get("rrsets", [])

    desired = {
        "name": record_name,
        "type": record_type,
        "ttl": int(ttl),
        "rrdatas": sorted(targets),
    }

    if existing:
        current = existing[0]
        if sorted(current.get("rrdatas", [])) == desired["rrdatas"]:
            return False  # already pointing where we want — no change needed
        deletions = [
            {
                "name": current["name"],
                "type": current["type"],
                "ttl": current["ttl"],
                "rrdatas": current["rrdatas"],
            }
        ]
    else:
        deletions = []

    service.changes().create(
        project=project,
        managedZone=managed_zone,
        body={"deletions": deletions, "additions": [desired]},
    ).execute()
    return True


def _swap(
    project,
    managed_zone,
    record_name,
    record_type,
    ttl,
    targets,
    primary_targets,
):
    """Point the public record at `targets` (unless it already is).

    Returns one of: "changed", "noop", "aborted".
    """
    if sorted(targets) == sorted(primary_targets):
        # Nothing to switch to — do not churn the zone.
        return "noop"

    changed = _set_records(
        project, managed_zone, record_name, record_type, ttl, targets
    )
    return "changed" if changed else "noop"


@functions_framework.cloud_event
def handle_monitor_alert(cloud_event):
    """Entry point. Reacts to Cloud Monitoring incident open/close events."""
    project = os.environ["PROJECT_ID"]
    managed_zone = os.environ["MANAGED_ZONE"]
    record_name = os.environ["RECORD_NAME"]
    record_type = os.environ.get("RECORD_TYPE", "CNAME").upper()
    ttl = int(os.environ.get("RECORD_TTL", "300"))

    primary_targets = _split_targets(os.environ.get("PRIMARY_TARGET", ""))
    dr_targets = _split_targets(os.environ.get("DR_TARGETS", ""))
    dr_health_url = os.environ.get("DR_HEALTH_URL", "").strip()

    # Eventarc delivers the Pub/Sub message inside cloud_event.data["message"]
    message = cloud_event.data.get("message", {})
    raw = base64.b64decode(message.get("data", b"{}"))
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        _log("ERROR", "FAILOVER_SKIP: unparseable notification payload")
        return

    incident = payload.get("incident", {})
    state = incident.get("state", "")
    incident_id = incident.get("incidentId", "unknown")

    if state == "open":
        if not dr_targets:
            _log(
                "ERROR",
                "FAILOVER_TARGET_MISSING: primary down but no DR target "
                "configured — the failover function refuses to repoint the "
                "record because that would point users at nothing",
                incident_id=incident_id,
            )
            return

        if dr_health_url:
            ok, detail = _probe_health(dr_health_url)
            if not ok:
                _log(
                    "ERROR",
                    "FAILOVER_ABORTED: DR target failed its health probe — "
                    "staying on the primary rather than failing over into an "
                    "unreachable standby",
                    incident_id=incident_id,
                    dr_health_url=dr_health_url,
                    detail=detail,
                )
                return

        result = _swap(
            project,
            managed_zone,
            record_name,
            record_type,
            ttl,
            dr_targets,
            primary_targets,
        )
        if result == "changed":
            _log(
                "WARNING",
                f"FAILOVER_ACTIVATED: {record_name} now points at the DR target",
                incident_id=incident_id,
                record_type=record_type,
                rrdatas=dr_targets,
            )
        else:
            _log(
                "INFO",
                "FAILOVER_NOOP: already on the DR target",
                incident_id=incident_id,
                rrdatas=dr_targets,
            )

    elif state == "closed":
        result = _swap(
            project,
            managed_zone,
            record_name,
            record_type,
            ttl,
            primary_targets,
            dr_targets,
        )
        if result == "changed":
            _log(
                "INFO",
                f"FAILOVER_RECOVERED: {record_name} restored to the primary target",
                incident_id=incident_id,
                record_type=record_type,
                rrdatas=primary_targets,
            )
        else:
            _log(
                "INFO",
                "FAILOVER_NOOP: already on the primary target",
                incident_id=incident_id,
            )

    else:
        _log(
            "INFO",
            f"FAILOVER_IGNORED: incident state '{state}'",
            incident_id=incident_id,
        )
