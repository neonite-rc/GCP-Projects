"""Tests for the DNS failover automation (src/functions/dns-failover).

This function owns the most dangerous write in the whole project: it
rewrites the zone's public record. A bug here either takes the site down
during an incident (flips when it should not) or leaves it pointing at a
dead VM (does not flip when it should).

The tests below pin the decision table:

    incident OPEN   -> record points at the DR target
    incident CLOSED -> record points back at the primary
    unknown state   -> record is left alone

and the two safety rules that matter most:

  1. with no DR target configured, the function must refuse to act and log
     loudly rather than pointing users at nothing;
  2. if the DR standby fails its health probe, the function must NOT fail
     over into it — staying on a broken primary is recoverable, failing
     over into an unreachable standby is not.
"""

import json

import pytest
from conftest import import_function

failover = import_function("dns-failover")

PRIMARY_TARGET = "primary.dr-demo.example.com."
DR_TARGET = "dr-maintenance-abc123.a.run.app."


class FakeRequest:
    """Mirrors the google-api-python-client request object.

    The real client returns a request whose ``.execute()`` performs the
    call, so the fake has to do the same or the tests would be testing a
    different interface than production uses.
    """

    def __init__(self, result):
        self._result = result

    def execute(self):
        return self._result


class FakeChanges:
    def __init__(self, service):
        self._service = service

    def create(self, project, managedZone, body):
        self._service.applied.append(body)
        return FakeRequest({"kind": "dns#change"})


class FakeResourceRecordSets:
    def __init__(self, service):
        self._service = service

    def list(self, project, managedZone, name, type):
        self._service.list_calls.append({"name": name, "type": type})
        return FakeRequest(self._service.list_result)


class FakeService:
    def __init__(self, existing_rrsets=None):
        self.existing_rrsets = existing_rrsets or []
        self.applied = []
        self.list_calls = []
        self.list_result = {"rrsets": self.existing_rrsets}

    def resourceRecordSets(self):
        return FakeResourceRecordSets(self)

    def changes(self):
        return FakeChanges(self)


@pytest.fixture
def fake_dns(monkeypatch):
    """Patch the DNS client and return the FakeService backing it."""

    def _make(existing_rrsets=None):
        service = FakeService(existing_rrsets)
        monkeypatch.setattr(failover, "_dns_service", lambda: service)
        return service

    return _make


@pytest.fixture
def failover_env(clean_env):
    clean_env.setenv("PROJECT_ID", "test-project")
    clean_env.setenv("MANAGED_ZONE", "test-zone")
    clean_env.setenv("RECORD_NAME", "app.dr-demo.example.com.")
    clean_env.setenv("RECORD_TYPE", "CNAME")
    clean_env.setenv("RECORD_TTL", "300")
    clean_env.setenv("PRIMARY_TARGET", PRIMARY_TARGET)
    clean_env.setenv("DR_TARGETS", DR_TARGET)
    return clean_env


def _incident(state, incident_id="inc-1"):
    return {"incident": {"state": state, "incidentId": incident_id}}


def _existing(target=PRIMARY_TARGET, rtype="CNAME"):
    return [
        {
            "name": "app.dr-demo.example.com.",
            "type": rtype,
            "ttl": 300,
            "rrdatas": [target],
        }
    ]


def test_open_incident_flips_record_to_dr(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A primary-down incident must repoint the record at the DR target."""
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert len(service.applied) == 1
    body = service.applied[0]
    assert body["additions"][0]["rrdatas"] == [DR_TARGET]
    assert body["additions"][0]["type"] == "CNAME"
    assert body["deletions"][0]["rrdatas"] == [PRIMARY_TARGET]

    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_ACTIVATED")
    assert entries[0]["severity"] == "WARNING"
    assert entries[0]["rrdatas"] == [DR_TARGET]


def test_closed_incident_restores_the_primary(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """When the incident closes the record must go back to the primary."""
    service = fake_dns(_existing(DR_TARGET))

    failover.handle_monitor_alert(cloud_event(_incident("closed")))

    assert len(service.applied) == 1
    body = service.applied[0]
    assert body["additions"][0]["rrdatas"] == [PRIMARY_TARGET]
    assert body["deletions"][0]["rrdatas"] == [DR_TARGET]

    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_RECOVERED")


def test_no_dr_target_refuses_to_act(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """Without a DR target the function must NOT rewrite the record.

    Pointing the only public record at nothing would turn a partial
    outage into a total one. It logs an ERROR and leaves DNS alone.
    """
    failover_env.setenv("DR_TARGETS", "")
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert service.applied == [], "record must not be touched without a target"
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_TARGET_MISSING")
    assert entries[0]["severity"] == "ERROR"


def test_unhealthy_dr_target_aborts_failover(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A DR standby that fails its health probe must NOT be switched to.

    Failing over into an unreachable standby is strictly worse than
    staying on a degraded primary: the operator still has a known state.
    """
    failover_env.setenv("DR_HEALTH_URL", "https://dr.invalid/health")

    def _boom(url):
        return False, "unreachable: connection refused"

    monkeypatch.setattr(failover, "_probe_health", _boom)
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert service.applied == [], "must not fail over to an unhealthy DR target"
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_ABORTED")
    assert entries[0]["severity"] == "ERROR"


def test_healthy_dr_target_allows_failover(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A DR standby that answers its health probe is switched to."""
    failover_env.setenv("DR_HEALTH_URL", "https://dr.example.com/health")
    monkeypatch.setattr(
        failover, "_probe_health", lambda url: (True, "HTTP 200")
    )
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert len(service.applied) == 1
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_ACTIVATED")


def test_already_on_dr_target_is_a_noop(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A repeated incident-open event must not churn the DNS zone."""
    service = fake_dns(_existing(DR_TARGET))

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert service.applied == []
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_NOOP")


def test_already_on_primary_is_a_noop_on_close(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A close event when the record never moved must not write anything."""
    service = fake_dns(_existing(PRIMARY_TARGET))

    failover.handle_monitor_alert(cloud_event(_incident("closed")))

    assert service.applied == []
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_NOOP")


def test_unknown_incident_state_is_ignored(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """An unrecognised state must leave the record untouched."""
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("weird")))

    assert service.applied == []
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_IGNORED")


def test_unparseable_payload_is_skipped(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """A malformed notification must not crash the function."""
    service = fake_dns([])

    failover.handle_monitor_alert(cloud_event("this is not json {"))

    assert service.applied == []
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_SKIP")
    assert entries[0]["severity"] == "ERROR"


def test_record_creation_when_none_exists(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """If the RRset is missing entirely, the function creates it."""
    service = fake_dns([])

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert len(service.applied) == 1
    body = service.applied[0]
    assert body["deletions"] == []
    assert body["additions"][0]["rrdatas"] == [DR_TARGET]
    assert body["additions"][0]["ttl"] == 300
    assert body["additions"][0]["type"] == "CNAME"


def test_drifted_record_is_corrected(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """If something else moved the record, the function re-asserts intent.

    Terraform owns the record too; a manual edit must not defeat the
    failover.
    """
    service = fake_dns(_existing("stale.example.com."))

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert len(service.applied) == 1
    body = service.applied[0]
    assert body["additions"][0]["rrdatas"] == [DR_TARGET]
    assert body["deletions"][0]["rrdatas"] == ["stale.example.com."]


def test_dns_call_uses_the_configured_project_and_zone(
    monkeypatch, failover_env, log_sink, fake_dns, cloud_event
):
    """The function must act on the zone it was given, not a default."""
    service = fake_dns(_existing())

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    assert service.list_calls[0]["name"] == "app.dr-demo.example.com."
    assert service.list_calls[0]["type"] == "CNAME"


def test_payload_decoding_matches_eventarc_shape(
    failover_env, log_sink, fake_dns, cloud_event
):
    """The alert JSON lives one level deep in the Eventarc wrapper.

    Regression guard for the Day 9 gotcha: the functions-framework docs
    suggest ``cloud_event.data`` directly, but Eventarc delivers
    ``data["message"]["data"]`` (base64).
    """
    service = fake_dns(_existing())

    event = cloud_event(_incident("open"))
    failover.handle_monitor_alert(event)

    assert len(service.applied) == 1
    entries = log_sink.read()
    assert entries[0]["message"].startswith("FAILOVER_ACTIVATED")
    assert entries[0]["incident_id"] == "inc-1"


def test_log_entries_are_valid_json(
    failover_env, log_sink, fake_dns, cloud_event
):
    """Everything on stdout must be a JSON object for the metric filters."""
    fake_dns([])

    failover.handle_monitor_alert(cloud_event(_incident("open")))

    for entry in log_sink.read():
        assert isinstance(entry, dict)
        assert "severity" in entry
        assert "message" in entry
        json.dumps(entry)  # must be serialisable


def test_split_targets_ignores_blanks():
    """Empty env values must not become empty target strings."""
    assert failover._split_targets("") == []
    assert failover._split_targets("  ,  ") == []
    assert failover._split_targets("a,b") == ["a.", "b."]
    assert failover._split_targets(" a , b ") == ["a.", "b."]


def test_split_targets_strips_scheme_and_path():
    """A URL accidentally configured as a CNAME target must be normalised.

    Cloud DNS rejects a CNAME whose rdata still carries "https://" with
    a 400, and that would crash the failover path. The function has to
    cope with a mis-configured target, not die on it.
    """
    assert failover._split_targets("https://svc.a.run.app/") == ["svc.a.run.app."]
    assert failover._split_targets("http://svc.a.run.app") == ["svc.a.run.app."]
    assert failover._split_targets("svc.a.run.app/") == ["svc.a.run.app."]
    assert failover._split_targets("svc.a.run.app.") == ["svc.a.run.app."]


def test_probe_health_reports_unreachable(monkeypatch):
    """A health probe against a dead host must return (False, reason)."""

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def _raise(url, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr(failover.urllib.request, "urlopen", _raise)
    ok, detail = failover._probe_health("https://nope.invalid/health")
    assert ok is False
    assert "unreachable" in detail
