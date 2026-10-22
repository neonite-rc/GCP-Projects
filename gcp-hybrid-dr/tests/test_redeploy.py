"""Tests for redeploy.sh — shipping a code change to the primary site.

Why this script exists
----------------------
The primary's code is delivered through instance metadata and fetched
once at first boot, so a change in the repository does not reach the
running VM by itself. ``redeploy.sh`` is the missing operation.

It is also the one script in the project that can take the site down,
so its safety properties are what matter:

  * a candidate that does not compile is never installed
  * a candidate nginx config that nginx rejects is never installed
  * a candidate that compiles but fails at runtime is rolled back
  * the database is never touched

Every path, command and URL it uses is overridable through the
environment, so these tests exercise the real script against a
temporary directory with stub ``curl``, ``systemctl`` and ``nginx`` on
PATH — no VM, no metadata server, no root.
"""

import os
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "src" / "scripts"

GOOD_APP = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    def health():
        return "ok"
    """
)

BAD_SYNTAX_APP = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    def health(:
        return "ok"
    """
)

# Compiles cleanly, but blows up when the app is imported. This is the
# case a syntax check cannot catch and the rollback exists for.
BAD_RUNTIME_APP = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import module_that_does_not_exist_xyz
    def health():
        return "ok"
    """
)

GOOD_NGINX_CONF = "server { listen 80; location / { proxy_pass http://127.0.0.1:8000; } }\n"
BAD_NGINX_CONF = "this is not a valid nginx configuration\n"


@pytest.fixture
def vm(tmp_path, monkeypatch):
    """A fake VM: a temp install dir, a metadata server, and stub binaries."""
    app_dir = tmp_path / "opt-dr"
    app_dir.mkdir()
    nginx_site = tmp_path / "nginx" / "dr-app"
    nginx_site.parent.mkdir()
    nginx_site.write_text(GOOD_NGINX_CONF)

    stage = tmp_path / "stage"
    stage.mkdir()

    # The metadata server: a directory of files, served by a stub curl
    # that copies the requested attribute into place.
    meta_dir = tmp_path / "meta"
    meta_dir.mkdir()

    bindir = tmp_path / "bin"
    bindir.mkdir()

    # Stub curl: serves metadata attributes, and answers the health probe.
    # Setting HEALTH_FAIL makes the health probe fail, which is how the
    # rollback path is exercised.
    curl = bindir / "curl"
    curl.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            url="${{@: -1}}"
            if [[ "$url" == *"/health" ]]; then
              if [[ -n "${{HEALTH_FAIL:-}}" ]]; then
                echo "curl: (7) Failed to connect" >&2
                exit 7
              fi
              echo '{{"status":"ok"}}'
              exit 0
            fi
            for arg in "$@"; do
              if [[ "$arg" == *"metadata.google.internal"* ]]; then
                url="$arg"
              fi
            done
            attr="${{url##*/}}"
            if [[ -f "{meta_dir}/$attr" ]]; then
              cat "{meta_dir}/$attr"
              exit 0
            fi
            echo "curl: (22) The requested URL returned error: 404" >&2
            exit 22
            """
        )
    )
    curl.chmod(0o755)

    # Stub systemctl: records the calls, always succeeds.
    calls = tmp_path / "systemctl-calls"
    systemctl = bindir / "systemctl"
    systemctl.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            echo "$@" >> "{calls}"
            exit 0
            """
        )
    )
    systemctl.chmod(0o755)

    # Stub nginx: `-t` succeeds unless the staged config is the bad one.
    nginx = bindir / "nginx"
    nginx.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ "$1" == "-t" ]]; then
              if grep -q "not a valid nginx" /etc/nginx/sites-available/dr-app 2>/dev/null \
                 || grep -rq "not a valid nginx" "$REDEPLOY_NGINX_SITE" 2>/dev/null; then
                echo "nginx: [emerg] invalid configuration" >&2
                exit 1
              fi
              exit 0
            fi
            exit 0
            """
        )
    )
    nginx.chmod(0o755)

    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{bindir}:{env['PATH']}",
            "REDEPLOY_META_URL": "http://metadata.test/instance/attributes",
            "REDEPLOY_APP_DIR": str(app_dir),
            "REDEPLOY_NGINX_SITE": str(nginx_site),
            "REDEPLOY_NGINX_BIN": str(nginx),
            "REDEPLOY_SERVICE": "dr-app.service",
            "REDEPLOY_NGINX_SERVICE": "nginx",
            "REDEPLOY_HEALTH_URL": "http://127.0.0.1:8000/health",
            "REDEPLOY_STAGE": str(stage),
        }
    )
    monkeypatch.setenv("REDEPLOY_NGINX_SITE", str(nginx_site))

    return {
        "env": env,
        "app_dir": app_dir,
        "nginx_site": nginx_site,
        "meta_dir": meta_dir,
        "stage": stage,
        "calls": calls,
    }


def _publish(vm, app=GOOD_APP, nginx=GOOD_NGINX_CONF, backup="#!/usr/bin/env bash\n", verify="#!/usr/bin/env bash\n"):
    """Put a candidate release into the fake metadata server."""
    (vm["meta_dir"] / "app-py").write_text(app)
    (vm["meta_dir"] / "nginx-conf").write_text(nginx)
    (vm["meta_dir"] / "backup-script").write_text(backup)
    (vm["meta_dir"] / "verify-script").write_text(verify)


def _install_live(vm, app=GOOD_APP, nginx=GOOD_NGINX_CONF, backup="#!/usr/bin/env bash\n", verify="#!/usr/bin/env bash\n"):
    """Put the same release into the fake VM, so nothing has changed."""
    (vm["app_dir"] / "app.py").write_text(app)
    (vm["app_dir"] / "backup.sh").write_text(backup)
    (vm["app_dir"] / "verify-backup.sh").write_text(verify)
    vm["nginx_site"].write_text(nginx)


def _run(vm, extra_args=()):
    return subprocess.run(
        ["bash", str(SCRIPTS / "redeploy.sh"), *extra_args],
        env=vm["env"],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------


def test_redeploy_rejects_unknown_flags(vm):
    """A typo must not be silently ignored."""
    result = _run(vm, extra_args=("--nonsense",))

    assert result.returncode == 1
    assert "unknown argument" in result.stderr.lower()


def test_redeploy_help_exits_zero(vm):
    result = _run(vm, extra_args=("--help",))

    assert result.returncode == 0
    assert "redeploy" in result.stdout.lower()


# ---------------------------------------------------------------------------
# The safety properties
# ---------------------------------------------------------------------------


def test_syntax_error_is_never_installed(vm):
    """A candidate that does not compile must not replace the running code."""
    _install_live(vm)
    _publish(vm, app=BAD_SYNTAX_APP)

    result = _run(vm)

    assert result.returncode == 1
    assert "does not compile" in result.stderr
    # The live file is untouched.
    assert (vm["app_dir"] / "app.py").read_text() == GOOD_APP


def test_shell_script_syntax_error_is_never_installed(vm):
    """The same applies to the shell scripts it ships."""
    _publish(vm, backup="#!/usr/bin/env bash\nif [ then fi\n")

    result = _run(vm)

    assert result.returncode == 1
    assert "not valid bash" in result.stderr
    assert not (vm["app_dir"] / "backup.sh").exists()


def test_a_rejected_nginx_config_is_never_installed(vm):
    """nginx -t must be able to veto the deploy before anything changes."""
    original = vm["nginx_site"].read_text()
    _publish(vm, nginx=BAD_NGINX_CONF)

    result = _run(vm)

    assert result.returncode == 1
    assert "nginx rejected" in result.stderr.lower()
    # The original config is back in place.
    assert vm["nginx_site"].read_text() == original


def test_a_missing_metadata_attribute_is_a_hard_error(vm):
    """Silently skipping a file would leave a mix of old and new code."""
    _publish(vm)
    (vm["meta_dir"] / "verify-script").unlink()

    result = _run(vm)

    assert result.returncode == 1
    assert "verify-script" in result.stderr


def test_an_empty_metadata_attribute_is_a_hard_error(vm):
    """An empty attribute is as broken as a missing one."""
    _publish(vm)
    (vm["meta_dir"] / "app-py").write_text("")

    result = _run(vm)

    assert result.returncode == 1
    assert "empty" in result.stderr.lower()


# ---------------------------------------------------------------------------
# The happy paths
# ---------------------------------------------------------------------------


def test_check_reports_without_installing(vm):
    """--check must not change anything."""
    _install_live(vm)
    _publish(vm, app=GOOD_APP + "\n# changed\n")

    result = _run(vm, extra_args=("--check",))

    assert result.returncode == 0
    assert "app.py: CHANGED" in result.stdout
    # Nothing was installed.
    assert (vm["app_dir"] / "app.py").read_text() == GOOD_APP


def test_dry_run_installs_nothing(vm):
    _install_live(vm)
    _publish(vm, app=GOOD_APP + "\n# changed\n")

    result = _run(vm, extra_args=("--dry-run",))

    assert result.returncode == 0
    assert "dry run" in result.stdout.lower()
    assert (vm["app_dir"] / "app.py").read_text() == GOOD_APP


def test_a_valid_change_is_installed_and_the_service_restarted(vm):
    """The whole point of the script."""
    _install_live(vm)
    _publish(vm, app=GOOD_APP + "\n# a real change\n")

    result = _run(vm)

    assert result.returncode == 0, result.stderr
    assert "# a real change" in (vm["app_dir"] / "app.py").read_text()
    assert "restart dr-app.service" in vm["calls"].read_text()


def test_an_unchanged_release_is_a_no_op(vm):
    """Re-running with the same code must not churn the service."""
    _install_live(vm)
    _publish(vm, app=GOOD_APP)

    result = _run(vm)

    assert result.returncode == 0
    assert "nothing to do" in result.stdout.lower()
    # The service was never touched.
    calls = vm["calls"].read_text() if vm["calls"].exists() else ""
    assert calls == ""


def test_the_database_is_never_touched(vm):
    """The rollout must not disturb the data the DR strategy protects."""
    _install_live(vm)
    _publish(vm, app=GOOD_APP + "\n# changed\n")
    db = vm["app_dir"] / "app.db"
    db.write_text("rows")

    _run(vm)

    assert db.read_text() == "rows"


def test_a_release_that_does_not_start_is_rolled_back(vm):
    """The case a syntax check cannot catch.

    A candidate that compiles but fails at runtime passes every static
    check, so the only defence left is to watch the app come back. If it
    does not, the previous version is restored — because "rolling back"
    by re-fetching from the metadata server would just fetch the same
    broken code again.
    """
    _install_live(vm)
    _publish(vm, app=BAD_RUNTIME_APP)
    # The app is installed, but the health probe never succeeds.
    vm["env"]["HEALTH_FAIL"] = "1"

    result = _run(vm)

    assert result.returncode == 1
    assert "rolled back" in result.stderr.lower()
    # The previous, working version is back in place.
    assert (vm["app_dir"] / "app.py").read_text() == GOOD_APP
    assert "module_that_does_not_exist_xyz" not in (
        vm["app_dir"] / "app.py"
    ).read_text()
