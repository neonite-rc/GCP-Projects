"""Tests for the disaster-drill script's DNS and probe helpers.

The drill is the thing that produces this project's headline number, so
its own logic deserves tests. Getting it wrong is subtle and happened
repeatedly during development:

  * ``dig +short <name> A`` returns the CNAME TARGET, not an address;
  * the zone's authoritative nameserver does not resolve names OUTSIDE
    the zone (the Cloud Run *.a.run.app front end) — that is correct
    DNS behaviour, not a failure;
  * names INSIDE the zone are invisible to the public resolver;
  * the standby is a TLS endpoint, so it must be probed by NAME over
    HTTPS, while the primary VM has no TLS and is probed over HTTP.

Each of those cost a real drill run. The helpers are extracted from the
script by text, so the tests exercise the actual shipped code rather
than a copy of it.
"""

import os
import re
import shutil
import subprocess

import pytest

REPO_ROOT = None
SCRIPT = None


def _script_path():
    global REPO_ROOT, SCRIPT
    if SCRIPT is None:
        from pathlib import Path

        REPO_ROOT = Path(__file__).resolve().parents[1]
        SCRIPT = REPO_ROOT / "src" / "scripts" / "disaster-drill.sh"
    return SCRIPT


def _extract_function(name: str) -> str:
    """Pull a bash function out of the script verbatim."""
    text = _script_path().read_text()
    match = re.search(
        rf"^{re.escape(name)}\(\) \{{\n(.*?)^\}}",
        text,
        re.MULTILINE | re.DOTALL,
    )
    assert match, f"function {name}() not found in the script"
    return f"{name}() {{\n{match.group(1)}}}"


def _run_bash(snippet: str, env: dict) -> str:
    """Run a bash snippet and return stdout."""
    result = subprocess.run(
        ["bash", "-c", snippet],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return result.stdout.strip()


@pytest.fixture
def helpers():
    """Load resolve() and probe_ok() from the script into a bash env."""

    def _load(zone="dr-demo.gcp-hybrid-dr.example.com", resolver=""):
        snippet = "\n\n".join(
            [
                f'ZONE_NAME="{zone}"',
                f'RESOLVER="{resolver}"',
                _extract_function("resolve"),
                _extract_function("probe_ok"),
            ]
        )
        return snippet

    return _load


@pytest.fixture
def fake_dig(tmp_path, monkeypatch):
    """Install a `dig` stub that serves a fixed zone.

    The stub answers from a small table so the tests can drive the
    resolver's behaviour exactly (CNAME chains, in-zone vs out-of-zone,
    unresolvable names) without touching real DNS.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)

    table = tmp_path / "zone.txt"
    # name -> answer. A CNAME target that is not in this table is
    # "external" and resolves via the system resolver path (which the
    # stub reports as a fixed public IP).
    table.write_text(
        "www.dr-demo.gcp-hybrid-dr.example.com. CNAME primary.dr-demo.gcp-hybrid-dr.example.com.\n"
        "primary.dr-demo.gcp-hybrid-dr.example.com. A 34.23.59.120\n"
        "standby.dr-demo.gcp-hybrid-dr.example.com. CNAME dr-demo-dr-maintenance-abc.a.run.app.\n"
    )

    stub = f"""#!/usr/bin/env bash
set -euo pipefail
TABLE="{table}"
# The drill calls: dig +short [@resolver] <name> A
# Parse the flags off the front, then the optional @resolver.
ARGS=()
RESOLVER=""
for a in "$@"; do
  case "$a" in
    +short) ;;
    @*) RESOLVER="${{a#@}}" ;;
    *) ARGS+=("$a") ;;
  esac
done
NAME="${{ARGS[0]:-}}"
# The authoritative server answers for in-zone names. A CNAME record is
# returned for an A query — that is exactly what a real server does, and
# it is the behaviour the drill has to cope with.
if [[ -n "${{RESOLVER}}" ]]; then
  LINE="$(grep -F "${{NAME}} " "${{TABLE}}" | head -1 || true)"
  if [[ -n "${{LINE}}" ]]; then
    read -r _ KIND VALUE <<<"${{LINE}}"
    echo "${{VALUE}}"
  fi
  exit 0
fi
# The public resolver answers for external names only.
case "${{NAME}}" in
  *.a.run.app.) echo "34.143.72.2" ;;
  *) exit 0 ;;
esac
"""
    (bindir / "dig").write_text(stub)
    (bindir / "dig").chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:{__import__('os').environ['PATH']}")
    return table


@pytest.fixture
def fake_curl(tmp_path, monkeypatch):
    """Install a `curl` stub that reports a chosen HTTP status.

    Records the URL it was asked for, so a test can assert on the
    scheme that was chosen.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    record = tmp_path / "curl.log"
    status = tmp_path / "status.txt"
    status.write_text("200")

    stub = f"""#!/usr/bin/env bash
set -euo pipefail
echo "$@" >> "{record}"
cat "{status}"
"""
    (bindir / "curl").write_text(stub)
    (bindir / "curl").chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:{__import__('os').environ['PATH']}")
    return {"record": record, "status": status}


def test_resolve_follows_the_cname_chain(helpers, fake_dig):
    """resolve() must return the FINAL hostname, not the CNAME target."""
    snippet = helpers(resolver="ns-cloud-b1.googledomains.com")
    out = _run_bash(
        f'{snippet}\nresolve "www.dr-demo.gcp-hybrid-dr.example.com."',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "primary.dr-demo.gcp-hybrid-dr.example.com."


def test_resolve_returns_the_external_target(helpers, fake_dig):
    """A CNAME pointing outside the zone resolves through the public path.

    The zone's authoritative nameserver does not answer for external
    names, so the second hop must go to the normal resolver.
    """
    snippet = helpers(resolver="ns-cloud-b1.googledomains.com")
    out = _run_bash(
        f'{snippet}\nresolve "standby.dr-demo.gcp-hybrid-dr.example.com."',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "dr-demo-dr-maintenance-abc.a.run.app."


def test_resolve_fails_cleanly_on_an_unknown_name(helpers, fake_dig):
    """An unresolvable name returns non-zero rather than looping forever."""
    snippet = helpers(resolver="ns-cloud-b1.googledomains.com")
    out = _run_bash(
        f'{snippet}\n'
        'if resolve "nope.example.com."; then echo "resolved"; else echo "unresolved"; fi',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "unresolved"


def test_probe_ok_uses_https_for_a_hostname(helpers, fake_curl):
    """The standby is a TLS endpoint — it must be probed over HTTPS."""
    snippet = helpers()
    out = _run_bash(
        f'{snippet}\nprobe_ok "dr-demo-dr-maintenance-abc.a.run.app." && echo OK || echo FAIL',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "OK"
    log = fake_curl["record"].read_text()
    assert "https://dr-demo-dr-maintenance-abc.a.run.app./health" in log


def test_probe_ok_uses_http_for_a_bare_ip(helpers, fake_curl):
    """The primary VM has no TLS without a registered domain."""
    snippet = helpers()
    out = _run_bash(
        f'{snippet}\nprobe_ok "34.23.59.120" && echo OK || echo FAIL',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "OK"
    log = fake_curl["record"].read_text()
    assert "http://34.23.59.120/health" in log


def test_probe_ok_accepts_a_full_url(helpers, fake_curl):
    """The 'wait for the primary' loop passes a full URL.

    Regression guard: probe_ok used to build
    "<scheme>://<target>/health", so a full URL became
    "https://http://1.2.3.4/health" and the drill hung after a
    successful failover.
    """
    snippet = helpers()
    out = _run_bash(
        f'{snippet}\nprobe_ok "http://34.23.59.120" && echo OK || echo FAIL',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "OK"
    log = fake_curl["record"].read_text()
    assert "http://34.23.59.120/health" in log
    assert "https://http://" not in log


def test_probe_ok_fails_on_a_non_200(helpers, fake_curl):
    """A 503 is not a recovery."""
    fake_curl["status"].write_text("503")
    snippet = helpers()
    out = _run_bash(
        f'{snippet}\nprobe_ok "34.23.59.120" && echo OK || echo FAIL',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "FAIL"


def test_probe_ok_resolves_an_in_zone_name_to_an_address(helpers, fake_dig, fake_curl):
    """A name inside the zone is invisible to the public resolver.

    The drill therefore has to ask the zone's authoritative server for
    the address and talk HTTP to that.
    """
    snippet = helpers(resolver="ns-cloud-b1.googledomains.com")
    out = _run_bash(
        f'{snippet}\n'
        'probe_ok "primary.dr-demo.gcp-hybrid-dr.example.com." && echo OK || echo FAIL',
        {"PATH": __import__("os").environ["PATH"]},
    )
    assert out == "OK"
    log = fake_curl["record"].read_text()
    assert "http://34.23.59.120/health" in log


def test_script_passes_shellcheck():
    """The drill script must be ShellCheck-clean (CI runs it too)."""
    if shutil.which("shellcheck") is None:
        pytest.skip("shellcheck not installed")
    result = subprocess.run(
        ["shellcheck", str(_script_path())],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout


def test_drill_rejects_a_resolver_that_does_not_serve_the_zone(tmp_path):
    """A wrong --resolver must fail fast, not report a bogus timeout.

    Without this check the drill injects a real outage, waits out its
    full timeout, and then blames the DR system for what was actually a
    mistyped argument.
    """
    env = dict(os.environ)
    env["TF_VAR_project_id"] = "test-project"

    result = subprocess.run(
        [
            "bash",
            str(_script_path()),
            "--project",
            "test-project",
            "--dns-name",
            "www.example.invalid.",
            "--resolver",
            "192.0.2.1",  # TEST-NET-1: guaranteed not to be a resolver
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode != 0
    assert "does not appear to be authoritative" in result.stderr
    # It must fail BEFORE stopping anything.
    assert "stopping" not in result.stdout
