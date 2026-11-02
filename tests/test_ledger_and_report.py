import json

from conftest import write
from secureship import cli, ledger


def test_ledger_chain_verifies(tmp_path):
    path = tmp_path / "ledger.jsonl"
    for i in range(3):
        ledger.append(path, {"build": i, "gate_decision": "PASS", "evidence_sha256": "x" * 64})
    res = ledger.verify(path)
    assert res["ok"] and res["entries"] == 3


def test_ledger_detects_modification(tmp_path):
    path = tmp_path / "ledger.jsonl"
    for i in range(3):
        ledger.append(path, {"build": i, "gate_decision": "FAIL", "deploy_status": "BLOCKED_BY_GATE"})
    lines = path.read_text().splitlines()
    entry = json.loads(lines[1])
    entry["gate_decision"] = "PASS"            # someone tries to rewrite history
    lines[1] = json.dumps(entry, sort_keys=True)
    path.write_text("\n".join(lines) + "\n")
    res = ledger.verify(path)
    assert not res["ok"]
    assert any("modified" in p for p in res["problems"])


def test_ledger_detects_deleted_entry(tmp_path):
    path = tmp_path / "ledger.jsonl"
    for i in range(3):
        ledger.append(path, {"build": i})
    lines = path.read_text().splitlines()
    path.write_text(lines[0] + "\n" + lines[2] + "\n")
    res = ledger.verify(path)
    assert not res["ok"] and any("chain broken" in p for p in res["problems"])


def test_hmac_prevents_full_rewrite(tmp_path):
    path = tmp_path / "ledger.jsonl"
    ledger.append(path, {"build": 1}, key="secret-key")
    assert ledger.verify(path, key="secret-key")["ok"]
    assert not ledger.verify(path, key="attacker-guess")["ok"]


def test_report_end_to_end(reports, policy_file, tmp_path, capsys):
    led = tmp_path / "jenkins_home" / "ledger.jsonl"
    cli.main(["gate", "--reports", str(reports), "--policy", str(policy_file),
              "--exceptions", str(tmp_path / "none.yaml"), "--today", "2026-11-02"])
    write(reports / "deploy.json", {
        "status": "ROLLED_BACK", "host": "lab-target", "chaos_mode": "crash",
        "new_release": {"backend": "7-a1b2c3d4-chaos-crash", "frontend": "7-a1b2c3d4"},
        "previous_release": {"backend": "6-ffff", "frontend": "6-ffff"},
        "health": {"passed": False, "attempts": 30, "elapsed_s": 90, "detail": "HTTP 502"},
        "rollback": {"performed": True, "success": True, "restored_release": {"backend": "6-ffff", "frontend": "6-ffff"}},
    })
    rc = cli.main(["report", "--reports", str(reports), "--ledger", str(led), "--result", "FAILURE"])
    assert rc == 0
    ev = json.loads((reports / "evidence.json").read_text())
    assert ev["build"]["number"] == "7"
    assert ev["source"]["commit"].startswith("a1b2c3d4")
    assert ev["gate"]["decision"] == "PASS"
    assert ev["deployment"]["status"] == "ROLLED_BACK"
    assert ev["deployment"]["rollback"]["success"] is True
    assert ev["vulnerability_counts"]["backend"]["MEDIUM"] == 1
    html = (reports / "evidence.html").read_text()
    assert "ROLLED_BACK" in html and "Tamper-evident ledger" in html
    assert ledger.verify(led, evidence=reports / "evidence.json")["evidence_recorded"]
    assert "Deployment    : ROLLED_BACK (restored backend 6-ffff" in capsys.readouterr().out


def test_report_when_gate_blocks(reports, tmp_path):
    write(reports / "gate.json", {"decision": "FAIL", "risk_score": 42, "risk_band": "HIGH",
                                  "blocking_reasons": ["Image vulnerabilities (backend): Blocked"], "checks": []})
    cli.main(["report", "--reports", str(reports), "--ledger", str(tmp_path / "l.jsonl"), "--result", "FAILURE"])
    ev = json.loads((reports / "evidence.json").read_text())
    assert ev["deployment"]["status"] == "BLOCKED_BY_GATE"


def test_report_when_build_failed_early(tmp_path):
    reports = tmp_path / "reports"
    reports.mkdir()
    rc = cli.main(["report", "--reports", str(reports), "--result", "FAILURE", "--ledger", ""])
    assert rc == 0
    ev = json.loads((reports / "evidence.json").read_text())
    assert ev["gate"]["decision"] == "NOT_REACHED" and ev["deployment"]["status"] == "NOT_REACHED"


# --- external anchors: the "delete the newest entries" attack -----------------------

def _build_ledger(tmp_path, n=4, key="k"):
    path, anchors = tmp_path / "ledger.jsonl", tmp_path / "anchors.log"
    for i in range(n):
        entry = ledger.append(path, {"build": str(i + 1), "gate_decision": "PASS"}, key=key)
        with open(anchors, "a") as fh:                       # what evidence.sh does after every build
            fh.write(ledger.anchor_line(entry) + "\n")
    return path, anchors


def test_truncating_newest_entries_is_invisible_to_the_chain_alone(tmp_path):
    path, _ = _build_ledger(tmp_path)
    lines = path.read_text().splitlines()
    path.write_text("\n".join(lines[:2]) + "\n")             # attacker deletes entries #3 and #4
    assert ledger.verify(path, key="k")["ok"]                # the remaining chain is still valid


def test_truncating_newest_entries_is_detected_by_anchors(tmp_path):
    path, anchors = _build_ledger(tmp_path)
    lines = path.read_text().splitlines()
    path.write_text("\n".join(lines[:2]) + "\n")
    res = ledger.verify(path, key="k", anchors=anchors)
    assert not res["ok"]
    assert any("#3" in p and "missing" in p for p in res["problems"])
    assert any("#4" in p and "missing" in p for p in res["problems"])


def test_deleting_the_whole_ledger_is_detected_by_anchors(tmp_path):
    path, anchors = _build_ledger(tmp_path)
    path.unlink()
    res = ledger.verify(path, key="k", anchors=anchors)
    assert not res["ok"] and len(res["problems"]) == 4


def test_rewriting_an_entry_with_recomputed_hashes_is_detected_by_anchors(tmp_path):
    # Without the HMAC key, an attacker can rebuild a fully consistent chain…
    path, anchors = _build_ledger(tmp_path, key=None)
    entries = ledger.read(path)
    entries[1]["gate_decision"] = "FAIL->PASS"
    path.unlink()
    for e in entries:
        ledger.append(path, {k: e[k] for k in ledger.LEDGER_FIELDS if k not in ("seq", "prev_hash")})
    assert ledger.verify(path)["ok"]                          # …that passes the chain check
    res = ledger.verify(path, anchors=anchors)               # …but not the external anchors
    assert not res["ok"] and any("#2" in p and "rewritten" in p for p in res["problems"])


def test_forged_anchor_is_rejected_with_key(tmp_path):
    path, anchors = _build_ledger(tmp_path, n=2)
    forged = {"seq": 3, "hash": "f" * 64, "hmac": "0" * 64, "anchored_at": "2026-11-02T00:00:00+00:00"}
    with open(anchors, "a") as fh:
        fh.write(json.dumps(forged) + "\n")
    res = ledger.verify(path, key="k", anchors=anchors)
    assert any("invalid HMAC" in p for p in res["problems"])


def test_unanchored_entries_are_reported(tmp_path):
    path, anchors = _build_ledger(tmp_path, n=2)
    ledger.append(path, {"build": "3"}, key="k")             # anchor write failed / pending
    res = ledger.verify(path, key="k", anchors=anchors)
    assert res["ok"] and res["anchor_check"]["unanchored_entries"] == [3]


def test_cli_anchor_and_verify(tmp_path, capsys):
    path, anchors = _build_ledger(tmp_path, n=2, key=None)
    assert cli.main(["ledger", "anchor", "--ledger", str(path)]) == 0
    assert json.loads(capsys.readouterr().out)["seq"] == 2
    assert cli.main(["ledger", "verify", "--ledger", str(path), "--anchors", str(anchors)]) == 0
    assert "anchored through entry #2" in capsys.readouterr().out
    path.write_text(path.read_text().splitlines()[0] + "\n")
    assert cli.main(["ledger", "verify", "--ledger", str(path), "--anchors", str(anchors)]) == 1
    assert cli.main(["ledger", "verify", "--ledger", str(path)]) == 0
    assert "deletion of the newest entries cannot be detected" in capsys.readouterr().out
