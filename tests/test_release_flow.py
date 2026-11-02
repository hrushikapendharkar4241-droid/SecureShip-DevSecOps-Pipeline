"""Tests for the self-healing release controller (scripts/remote/release.sh).

The real script runs on the deployment server. Here `docker` and `curl` are replaced by
small fakes on PATH, so every branch (deploy, auto-rollback, failed rollback, aborted
backup, stale version) is exercised in milliseconds without a server.
A backend tag containing "bad" simulates a release that never becomes healthy.
"""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

FAKE_DOCKER = r"""#!/usr/bin/env bash
S="$FAKE_STATE"; echo "docker $*" >> "$S/calls.log"
args=" $* "
if [[ "$1" == "compose" ]]; then
  case "$args" in
    *" up -d "*)  echo "${BACKEND_TAG}" > "$S/running"; touch "$S/db_running"; exit 0 ;;
    *" ps -q db "*) [ -f "$S/db_running" ] && echo dbcontainer; exit 0 ;;
    *" exec -T db "*) [ -f "$S/backup_fails" ] && exit 1; echo "-- PostgreSQL dump"; exit 0 ;;
    *" logs "*)   echo "backend | Traceback: simulated failure"; exit 0 ;;
    *" stop "*)   : > "$S/running"; exit 0 ;;
  esac
  exit 0
fi
case "$1" in
  images) cat "$S/images" 2>/dev/null; exit 0 ;;
  rmi)    echo "$2" >> "$S/removed"; exit 0 ;;
esac
exit 0
"""

FAKE_CURL = r"""#!/usr/bin/env bash
S="$FAKE_STATE"; out=/dev/null; fmt=""; head=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -w) fmt="$2"; shift ;; --max-time) shift ;;
    -sI|-I) head=1 ;; -s) ;; *) url="$1" ;;
  esac; shift
done
tag="$(cat "$S/running" 2>/dev/null)"
if [ $head = 1 ]; then printf 'HTTP/1.1 200 OK\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n\r\n'; exit 0; fi
code=200; body='<div id="root"></div>'
if [[ "$url" == */health ]]; then
  if [ -z "$tag" ] || [[ "$tag" == *bad* ]]; then code=502; body="502 Bad Gateway"
  else
    v="$tag"; [ -f "$S/stale" ] && v="old-version"
    body="{\"status\":\"ok\",\"version\":\"$v\",\"checks\":{\"database\":{\"ok\":true,\"latency_ms\":1.2}}}"
  fi
fi
printf '%s' "$body" > "$out"
[ -n "$fmt" ] && printf '%s' "$code"
exit 0
"""


@pytest.fixture
def target(tmp_path):
    deploy = tmp_path / "opt-secureship"
    (deploy / "scripts").mkdir(parents=True)
    shutil.copytree(ROOT / "scripts" / "remote", deploy / "scripts" / "remote")
    (deploy / "docker").mkdir()
    shutil.copy(ROOT / "docker" / "docker-compose.yml", deploy / "docker")
    (deploy / ".env").write_text("POSTGRES_USER=shoppilot\nPUBLIC_PORT=8080\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, src in (("docker", FAKE_DOCKER), ("curl", FAKE_CURL)):
        p = bin_dir / name
        p.write_text(src)
        p.chmod(p.stat().st_mode | stat.S_IEXEC)
    state = tmp_path / "fake"
    state.mkdir()
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_STATE": str(state),
           "HEALTH_TIMEOUT": "1", "HEALTH_INTERVAL": "0.2", "BUILD_NUMBER": "9"}

    class Target:
        dir = deploy
        fake = state

        def run(self, *args):
            p = subprocess.run(["bash", str(deploy / "scripts" / "remote" / "release.sh"), *args],
                               env=env, capture_output=True, text=True, timeout=60)
            result = None
            for line in p.stdout.splitlines():
                if line.startswith("SECURESHIP_RESULT "):
                    result = json.loads(line.split(" ", 1)[1])
            return p.returncode, result, p.stderr

        def current(self):
            f = deploy / "state" / "current"
            return f.read_text().strip() if f.exists() else None

        def previous(self):
            f = deploy / "state" / "previous"
            return f.read_text().strip() if f.exists() else None

        def running(self):
            return (state / "running").read_text().strip()

    return Target()


def test_first_deploy_succeeds(target):
    rc, res, _ = target.run("deploy", "1-aaaa", "1-aaaa")
    assert rc == 0 and res["status"] == "DEPLOYED"
    assert res["health"]["passed"] and res["health"]["version_seen"] == "1-aaaa"
    assert res["previous_release"] is None
    assert "skipped" in res["backup"]                      # no database yet on first deploy
    assert target.current() == "1-aaaa 1-aaaa"


def test_upgrade_records_previous_and_backs_up_db(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    rc, res, _ = target.run("deploy", "2-bbbb", "2-bbbb")
    assert rc == 0 and res["status"] == "DEPLOYED"
    assert res["previous_release"] == {"backend": "1-aaaa", "frontend": "1-aaaa"}
    assert res["backup"]["file"].endswith(".sql.gz")
    assert target.previous() == "1-aaaa 1-aaaa" and target.current() == "2-bbbb 2-bbbb"


def test_unhealthy_release_is_rolled_back_automatically(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    rc, res, err = target.run("deploy", "2-bad", "2-bbbb")
    assert rc == 2 and res["status"] == "ROLLED_BACK"
    assert res["health"]["passed"] is False and "502" in res["health"]["detail"]
    assert res["rollback"]["performed"] and res["rollback"]["success"]
    assert res["rollback"]["health_after_rollback"]["version_seen"] == "1-aaaa"
    assert target.running() == "1-aaaa"                    # old version is serving again
    assert target.current() == "1-aaaa 1-aaaa"             # state still points at the good release
    assert (target.dir / "state" / "failed-2-bad.log").exists()
    assert "ROLLING BACK" in err


def test_first_deploy_failure_cannot_roll_back(target):
    rc, res, _ = target.run("deploy", "1-bad", "1-aaaa")
    assert rc == 3 and res["status"] == "FAILED"
    assert res["rollback"]["performed"] is False
    assert target.current() is None


def test_rollback_failure_is_reported(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    (target.dir / "state" / "current").write_text("0-bad 0-bad\n")   # previous release is broken too
    rc, res, _ = target.run("deploy", "2-bad", "2-bbbb")
    assert rc == 3 and res["status"] == "ROLLBACK_FAILED"
    assert res["rollback"]["success"] is False


def test_failed_backup_aborts_before_touching_the_app(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    (target.fake / "backup_fails").touch()
    calls_before = (target.fake / "calls.log").read_text().count(" up -d ")
    rc, res, _ = target.run("deploy", "2-bbbb", "2-bbbb")
    assert rc == 3 and res["status"] == "FAILED" and "backup failed" in res["detail"]
    assert (target.fake / "calls.log").read_text().count(" up -d ") == calls_before
    assert target.running() == "1-aaaa"


def test_stale_version_is_not_accepted_as_healthy(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    (target.fake / "stale").touch()                        # /health answers, but with an old version
    rc, res, _ = target.run("deploy", "2-bbbb", "2-bbbb")
    assert rc in (2, 3)
    assert "expected '2-bbbb'" in res["health"]["detail"]


def test_manual_rollback_and_status(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    target.run("deploy", "2-bbbb", "2-bbbb")
    p = subprocess.run(["bash", str(target.dir / "scripts" / "remote" / "release.sh"), "rollback"],
                       env={**os.environ, "PATH": f"{target.fake.parent / 'bin'}:{os.environ['PATH']}",
                            "FAKE_STATE": str(target.fake), "HEALTH_TIMEOUT": "1", "HEALTH_INTERVAL": "0.2"},
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert target.current() == "1-aaaa 1-aaaa" and target.previous() == "2-bbbb 2-bbbb"
    rc, _, _ = target.run("status")
    assert rc == 0


def test_history_log_records_every_attempt(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    target.run("deploy", "2-bad", "2-bbbb")
    history = (target.dir / "state" / "history.log").read_text().splitlines()
    assert history[0].split()[1] == "DEPLOYED" and history[1].split()[1] == "ROLLED_BACK"


def test_old_images_are_pruned_keeping_current_and_previous(target):
    target.run("deploy", "1-aaaa", "1-aaaa")
    target.run("deploy", "2-bbbb", "2-bbbb")
    (target.fake / "images").write_text("\n".join(
        f"shoppilot-{r}:{t}" for r in ("backend", "frontend") for t in ("1-aaaa", "2-bbbb", "3-cccc")) + "\nother:latest\n")
    rc, _, _ = target.run("deploy", "3-cccc", "3-cccc")
    assert rc == 0
    removed = set((target.fake / "removed").read_text().split())
    assert removed == {"shoppilot-backend:1-aaaa", "shoppilot-frontend:1-aaaa"}
