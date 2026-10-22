"""Tests for the CMEK key version retirement function.

This function destroys key material, so the tests are about SAFETY: it
must never touch the primary version, and it must never retire a
version that a restorable backup could still need.

The bug it exists to prevent was measured, not imagined: rotating a key
leaves the superseded version ENABLED and still billed, forever.
"""

import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FUNC_PATH = (
    REPO_ROOT / "src" / "functions" / "key-version-retirement" / "main.py"
)


def _load(monkeypatch, retention_days=30, keyrings="locations/us-east1/keyRings/kr1"):
    """Import the function module with its env configured."""
    monkeypatch.setenv("RETENTION_DAYS", str(retention_days))
    monkeypatch.setenv("KEYRINGS", keyrings)
    monkeypatch.setenv("PROJECT_ID", "test-project")

    spec = importlib.util.spec_from_file_location("key_retirement", FUNC_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["key_retirement"] = module
    spec.loader.exec_module(module)
    return module


class FakeVersion:
    """A key version as the KMS API returns it."""

    # The numeric states the API uses.
    ENABLED = 1
    DISABLED = 2
    DESTROY_SCHEDULED = 3

    def __init__(self, name, state=ENABLED, age_days=0):
        self.name = name
        self.state = state
        self.create_time = datetime.now(timezone.utc) - timedelta(days=age_days)


class FakePrimary:
    """The `key.primary` field is a CryptoKeyVersion OBJECT, not a name.

    Comparing `version.name == key.primary` silently never matches, which
    would let the function destroy the primary version. The real API
    returns an object with a `.name`.
    """

    def __init__(self, name):
        self.name = name


class FakeKey:
    """A key, which owns its versions and names its primary version."""

    def __init__(self, name, versions, primary=None):
        self.name = name
        self._versions = versions
        # The real CryptoKey resource carries `primary` as a
        # CryptoKeyVersion OBJECT. There is no per-version "is primary"
        # flag; the list API rejects one.
        self.primary = FakePrimary(primary) if primary else None


class FakeClient:
    """Mirrors the surface the function actually uses.

    The real client's methods are `list_crypto_keys` and
    `list_crypto_key_versions`, both on the CLIENT — not on the key.
    """

    def __init__(
        self,
        versions,
        key_name="projects/p/locations/l/keyRings/kr/cryptoKeys/k",
        primary=None,
    ):
        self._versions = versions
        self._key_name = key_name
        self._primary = primary
        self.destroyed = []

    def list_crypto_keys(self, request=None, **kwargs):
        return [FakeKey(self._key_name, self._versions, self._primary)]

    def list_crypto_key_versions(self, request=None, **kwargs):
        return list(self._versions)

    def destroy_crypto_key_version(self, request=None, **kwargs):
        self.destroyed.append(request["name"])


def test_primary_version_is_never_destroyed(monkeypatch, log_sink):
    """Destroying the primary would break every new write. Never."""
    module = _load(monkeypatch)

    primary = FakeVersion("v1", age_days=500)
    client = FakeClient([primary], primary=primary.name)

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    assert destroyed == 0
    assert client.destroyed == [], "the primary version must never be destroyed"


def test_just_superseded_version_is_not_destroyed(monkeypatch, log_sink):
    """A version superseded YESTERDAY is still needed by live backups.

    This is the regression guard for a real data-loss bug. The first
    implementation used the version's CREATE time, so a version created
    90 days ago and superseded yesterday looked "old" and was destroyed
    — taking every restorable backup with it, because they were all
    encrypted under it. The age that matters is the SUPERSESSION time.
    """
    module = _load(monkeypatch, retention_days=30)

    # v1 was created 90 days ago and was primary for all that time.
    # v2 was created yesterday and took over.
    v1 = FakeVersion("v1", age_days=90)
    v2 = FakeVersion("v2", age_days=1)
    client = FakeClient([v1, v2], primary=v2.name)

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    assert destroyed == 0, (
        "a version superseded only yesterday must survive the retention window"
    )
    assert client.destroyed == []


def test_long_superseded_version_is_destroyed(monkeypatch, log_sink):
    """A version superseded longer ago than the window is retired."""
    module = _load(monkeypatch, retention_days=30)

    # v1 was superseded 100 days ago (v2 was created then), and v2 was
    # superseded 5 days ago by v3.
    v1 = FakeVersion("v1", age_days=200)
    v2 = FakeVersion("v2", age_days=100)
    v3 = FakeVersion("v3", age_days=5)
    client = FakeClient([v1, v2, v3], primary=v3.name)

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    # v1 was superseded 100 days ago -> past the 30-day window -> retire.
    # v2 was superseded 5 days ago  -> inside the window      -> keep.
    assert destroyed == 1
    assert client.destroyed == ["v1"]
    entries = log_sink.read()
    assert any("KEY_VERSION_RETIRED" in e["message"] for e in entries)


def test_already_scheduled_version_is_skipped(monkeypatch, log_sink):
    """A version already on its way out is free — do not touch it again."""
    module = _load(monkeypatch)

    pending = FakeVersion("v1", state=FakeVersion.DESTROY_SCHEDULED, age_days=200)
    client = FakeClient([pending])

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    assert destroyed == 0
    assert client.destroyed == []


def test_disabled_old_version_is_destroyed(monkeypatch, log_sink):
    """A DISABLED version is still billed, so it still has to go."""
    module = _load(monkeypatch, retention_days=30)

    v1 = FakeVersion("v1", state=FakeVersion.DISABLED, age_days=200)
    v2 = FakeVersion("v2", age_days=150)
    client = FakeClient([v1, v2], primary=v2.name)

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    # v1 was superseded 150 days ago -> retire. v2 is primary -> keep.
    assert destroyed == 1
    assert client.destroyed == ["v1"]


def test_one_failure_does_not_stop_the_sweep(monkeypatch, log_sink):
    """A failure on one version must not abandon the rest."""
    module = _load(monkeypatch, retention_days=30)

    class FlakyClient(FakeClient):
        def destroy_crypto_key_version(self, request=None, **kwargs):
            if request["name"] == "v1":
                raise RuntimeError("boom")
            return super().destroy_crypto_key_version(request=request, **kwargs)

    v1 = FakeVersion("v1", age_days=300)
    v2 = FakeVersion("v2", age_days=250)
    v3 = FakeVersion("v3", age_days=200)
    client = FlakyClient([v1, v2, v3], primary=v3.name)

    monkeypatch.setattr(module.kms, "KeyManagementServiceClient", lambda *a, **k: client)
    destroyed = module.retire("test-project")

    # v1 (superseded 250d ago) fails; v2 (superseded 200d ago) succeeds.
    assert destroyed == 1
    assert client.destroyed == ["v2"]
    entries = log_sink.read()
    assert any("KEY_VERSION_RETIRE_FAILED" in e["message"] for e in entries)


def test_missing_keyring_config_is_reported(monkeypatch, log_sink):
    """With no keyrings configured the function must say so, not pass silently."""
    module = _load(monkeypatch, keyrings="")

    module.run_key_version_retirement(None)

    entries = log_sink.read()
    assert any("KEY_VERSION_RETIRE_CONFIG" in e["message"] for e in entries)
