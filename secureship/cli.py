"""Command line entry point:  python3 -m secureship <command> ...

  gate     evaluate the release policy, write reports/gate.json, exit 1 on FAIL
  report   build evidence.json + evidence.html and append the ledger entry
  ledger   verify | show the tamper-evident deployment ledger
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path

from secureship import ledger, parsers, policy, report


def _today(value: str | None) -> dt.date:
    return dt.date.fromisoformat(value) if value else dt.date.today()


def cmd_gate(args) -> int:
    pol = policy.load_policy(Path(args.policy))
    today = _today(args.today)
    exc = policy.load_exceptions(Path(args.exceptions), pol, today)
    result = policy.evaluate(Path(args.reports), pol, exc, today)
    out = Path(args.reports) / "gate.json"
    out.write_text(json.dumps(result, indent=2, default=str), encoding="utf-8")

    width = max(len(c["name"]) for c in result["checks"]) if result["checks"] else 10
    print("\n SecureShip security gate")
    print(" " + "-" * (width + 60))
    for c in result["checks"]:
        mark = {"PASS": "✔", "FAIL": "✘", "WARN": "!", "SKIP": "-"}[c["status"]]
        print(f" {mark} {c['status']:<4}  {c['name']:<{width}}  {c['detail']}")
    print(" " + "-" * (width + 60))
    print(f" Residual risk score: {result['risk_score']}/100 ({result['risk_band']})")
    print(f" DECISION: {result['decision']}" + ("  → deployment blocked" if result["decision"] == "FAIL" else "  → cleared for deployment"))
    print()
    return 0 if result["decision"] == "PASS" else 1


def cmd_report(args) -> int:
    reports = Path(args.reports)
    reports.mkdir(parents=True, exist_ok=True)
    evidence = report.build_evidence(reports, args.result, deploy_enabled=args.deploy_enabled.lower() == "true")
    ev_path = reports / "evidence.json"
    ev_path.write_text(json.dumps(evidence, indent=2, default=str), encoding="utf-8")

    entry, history, check = None, [], None
    key = os.environ.get("LEDGER_KEY") or None
    if args.ledger:
        entry = ledger.append(Path(args.ledger), {
            "build": evidence["build"]["number"],
            "commit": evidence["source"]["commit"],
            "app_tag": evidence["images"].get("tag"),
            "gate_decision": evidence["gate"]["decision"],
            "risk_score": evidence["gate"]["risk_score"],
            "deploy_status": evidence["deployment"]["status"],
            "pipeline_result": evidence["pipeline_result"],
            "images": {k: (v or {}).get("id") for k, v in evidence["images"].items() if isinstance(v, dict)},
            "evidence_sha256": ledger.sha256_file(ev_path),
        }, key=key)
        history = ledger.read(Path(args.ledger))
        check = ledger.verify(Path(args.ledger), key=key,
                              anchors=Path(args.anchors) if args.anchors else None)
        check["anchor_sources"] = [s for s in (args.anchor_sources or "").split(",") if s]
        (reports / "ledger-entry.json").write_text(json.dumps(entry, indent=2), encoding="utf-8")
        (reports / "ledger-anchor.jsonl").write_text(ledger.anchor_line(entry) + "\n", encoding="utf-8")
        (reports / "ledger-verify.json").write_text(json.dumps(check, indent=2), encoding="utf-8")

    gate = parsers.load_json(reports / "gate.json")
    (reports / "evidence.html").write_text(report.render_html(evidence, gate, entry, history, check), encoding="utf-8")
    print(report.console_summary(evidence))
    if check and not check["ok"]:
        print("!! LEDGER INTEGRITY PROBLEM:\n   " + "\n   ".join(check["problems"]), file=sys.stderr)
        return 2
    return 0


def cmd_ledger(args) -> int:
    key = os.environ.get("LEDGER_KEY") or None
    if args.action == "anchor":
        entries = ledger.read(Path(args.ledger))
        if not entries:
            print("ledger is empty", file=sys.stderr)
            return 1
        target = next((e for e in entries if e["seq"] == args.seq), None) if args.seq else entries[-1]
        if target is None:
            print(f"no entry #{args.seq}", file=sys.stderr)
            return 1
        print(ledger.anchor_line(target))
        return 0
    if args.action == "verify":
        res = ledger.verify(Path(args.ledger), key=key, evidence=Path(args.evidence) if args.evidence else None,
                            anchors=Path(args.anchors) if args.anchors else None)
        if res["ok"]:
            msg = f"✔ ledger OK – {res['entries']} entries, head {str(res['head'])[:16]}…"
            if key:
                msg += ", all HMAC signatures valid"
            if res.get("evidence_recorded"):
                msg += f"; evidence matches entry #{res['evidence_seq']}"
            print(msg)
            info = res.get("anchor_check")
            if info is None:
                print("! no external anchors checked – deletion of the newest entries cannot be detected (use --anchors)")
            else:
                print(f"✔ {info['anchors']} external anchor(s) match; anchored through entry #{info['anchored_through']}")
                if info["unanchored_entries"]:
                    print(f"! entries not yet anchored externally: {info['unanchored_entries']}")
            return 0
        print(f"✘ ledger verification FAILED ({res['entries']} entries):")
        for p in res["problems"]:
            print("   - " + p)
        return 1
    for e in ledger.read(Path(args.ledger))[-args.last:]:
        print(f"#{e['seq']:<4} build {str(e.get('build')):<5} {str(e.get('app_tag') or ''):<24} "
              f"gate={e.get('gate_decision'):<11} deploy={e.get('deploy_status'):<16} risk={e.get('risk_score')}  {e.get('timestamp')}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="secureship", description="SecureShip release-decision engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gate", help="evaluate the security gate")
    g.add_argument("--reports", default="reports")
    g.add_argument("--policy", default="security/policy.yaml")
    g.add_argument("--exceptions", default="security/exceptions.yaml")
    g.add_argument("--today", help="override today's date (YYYY-MM-DD), for tests")
    g.set_defaults(func=cmd_gate)

    r = sub.add_parser("report", help="generate the deployment evidence report")
    r.add_argument("--reports", default="reports")
    r.add_argument("--ledger", default=os.environ.get("LEDGER_PATH"))
    r.add_argument("--result", default=os.environ.get("PIPELINE_RESULT", "UNKNOWN"))
    r.add_argument("--deploy-enabled", default=os.environ.get("DEPLOY_ENABLED", "true"))
    r.add_argument("--anchors", help="external anchor file (JSON lines) to check the ledger against")
    r.add_argument("--anchor-sources", default="", help="comma-separated names of where the anchors came from")
    r.set_defaults(func=cmd_report)

    l = sub.add_parser("ledger", help="inspect the deployment ledger")
    l.add_argument("action", choices=["verify", "show", "anchor"])
    l.add_argument("--ledger", default=os.environ.get("LEDGER_PATH", "ledger.jsonl"))
    l.add_argument("--evidence", help="also check this evidence.json is recorded in the ledger")
    l.add_argument("--anchors", help="external anchor file (JSON lines) – detects deletion of the newest entries")
    l.add_argument("--seq", type=int, help="anchor: entry number (default: the newest)")
    l.add_argument("--last", type=int, default=20)
    l.set_defaults(func=cmd_ledger)

    args = p.parse_args(argv)
    return args.func(args)
