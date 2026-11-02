"""Integration test for scripts/evidence.sh + scripts/anchor-lib.sh.

`ssh` is replaced by a shim that runs the remote command locally (so the
"deployment server" is a temp directory) and the Git anchor store is a real
local bare repository. Three builds are recorded; then the newest ledger entries
are deleted and the next build must report a ledger integrity problem (exit 2).
"""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from conftest import ROOT

FAKE_SSH = r"""#!/usr/bin/env bash
# ssh shim: drop options and destination, run the remote command locally
while [ $# -gt 1 ]; do
  case "$1" in -p|-i|-o) shift 2 ;; -*) shift ;; *) shift; break ;; esac
done
exec bash -c "$1"
"""

pytestmark = pytest.mark.skipif(shutil.which("git") is None or shutil.which("jq") is None,
                                reason="needs git and jq")


@pytest.fixture
def env(tmp_path, reports):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    ssh = bin_dir / "ssh"
    ssh.write_text(FAKE_SSH)
    ssh.chmod(ssh.stat().st_mode | stat.S_IEXEC)

    server = tmp_path / "server"                       # stands in for /opt/secureship on the target
    server.mkdir()
    bare = tmp_path / "anchors.git"                    # stands in for the GitHub anchor repo
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
    seed = tmp_path / "seed"
    subprocess.run(["git", "clone", "-q", str(bare), str(seed)], check=True, capture_output=True)
    (seed / "README.md").write_text("anchors\n")
    subprocess.run("git add . && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin HEAD:main",
                   shell=True, cwd=seed, check=True, capture_output=True)

    return {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "WORKSPACE": str(ROOT), "REPORTS_DIR": str(reports),
        "LEDGER_PATH": str(tmp_path / "jenkins" / "ledger.jsonl"), "LEDGER_KEY": "test-key",
        "DEPLOY_HOST": "lab-target", "DEPLOY_DIR": str(server),
        "ANCHOR_GIT_REPO": str(bare), "ANCHOR_GIT_BRANCH": "main",
        "PIPELINE_RESULT": "SUCCESS", "BUILD_NUMBER": "1",
        "_server": str(server), "_bare": str(bare),
    }


def run_evidence(env, build):
    env = {**env, "BUILD_NUMBER": str(build)}
    # every real build records its own number (otherwise two runs within one second could
    # produce byte-identical entries, which would correctly match an old anchor)
    reports = Path(env["REPORTS_DIR"])
    meta = json.loads((reports / "build.json").read_text())
    meta.update(build_number=str(build), app_tag=f"{build}-a1b2c3d4")
    (reports / "build.json").write_text(json.dumps(meta))
    return subprocess.run(["bash", str(ROOT / "scripts" / "evidence.sh")], env=env,
                          capture_output=True, text=True, timeout=60)


def git_anchor_lines(env, tmp_path):
    out = tmp_path / f"check-{len(list(tmp_path.iterdir()))}"
    subprocess.run(["git", "clone", "-q", env["_bare"], str(out)], check=True, capture_output=True)
    f = out / "ledger-anchors.jsonl"
    return f.read_text().splitlines() if f.exists() else []


def test_each_build_is_anchored_in_both_stores(env, reports, tmp_path):
    for build in (1, 2, 3):
        p = run_evidence(env, build)
        assert p.returncode == 0, p.stdout + p.stderr
    server_lines = (Path(env["_server"]) / "anchors" / "ledger-anchors.jsonl").read_text().splitlines()
    assert [json.loads(l)["seq"] for l in server_lines] == [1, 2, 3]
    assert [json.loads(l)["seq"] for l in git_anchor_lines(env, tmp_path)] == [1, 2, 3]
    status = json.loads((reports / "anchor-status.json").read_text())
    assert status["deploy_server"] == "written" and status["git"] == "written"
    verify = json.loads((reports / "ledger-verify.json").read_text())
    assert verify["ok"] and verify["anchor_check"]["anchored_through"] == 2   # #3 anchored after its report
    assert verify["anchor_sources"] == ["deploy-server", "git"]


def test_deleting_newest_entries_fails_the_next_build(env, reports):
    for build in (1, 2, 3):
        assert run_evidence(env, build).returncode == 0
    ledger = Path(env["LEDGER_PATH"])
    ledger.write_text("\n".join(ledger.read_text().splitlines()[:1]) + "\n")    # attacker keeps only #1
    p = run_evidence(env, 4)
    assert p.returncode == 2, p.stdout + p.stderr
    verify = json.loads((reports / "ledger-verify.json").read_text())
    # build 4 re-used number #2 after the truncation, so #2 no longer matches its anchor and #3 is gone
    assert any("#2" in x and "differs from its external anchor" in x for x in verify["problems"]), verify["problems"]
    assert any("#3" in x and "missing" in x for x in verify["problems"]), verify["problems"]
    assert "LEDGER INTEGRITY PROBLEM" in p.stderr


def test_unreachable_anchor_store_is_reported_not_silent(env, reports):
    env = {**env, "ANCHOR_GIT_REPO": "/nonexistent/repo.git"}
    p = run_evidence(env, 1)
    assert p.returncode == 3, p.stdout + p.stderr            # entry written, but not fully anchored
    assert json.loads((reports / "anchor-status.json").read_text())["git"] == "failed"


def test_entries_written_while_store_was_down_are_anchored_later(env, reports, tmp_path):
    assert run_evidence(env, 1).returncode == 0
    assert run_evidence({**env, "ANCHOR_GIT_REPO": "/nonexistent.git", "ANCHOR_SSH": "false"}, 2).returncode == 3
    assert run_evidence(env, 3).returncode == 0                  # catches up on #2
    seqs = sorted(json.loads(l)["seq"] for l in git_anchor_lines(env, tmp_path))
    assert seqs == [1, 2, 3]
    assert json.loads((reports / "anchor-status.json").read_text())["anchors_written"] == 2
