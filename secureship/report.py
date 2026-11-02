"""Deployment evidence report ("release passport").

Produces, for every pipeline run:
  reports/evidence.json – machine-readable, hashed into the ledger
  reports/evidence.html – self-contained page to show in reviews / interviews
"""

from __future__ import annotations

import datetime as dt
import html
import json
from pathlib import Path

from secureship import parsers

E = html.escape


def _deploy_status(deploy: dict | None, gate: dict | None, deploy_enabled: bool) -> str:
    if deploy:
        return deploy.get("status", "UNKNOWN")
    if gate is None:
        return "NOT_REACHED"
    if gate.get("decision") == "FAIL":
        return "BLOCKED_BY_GATE"
    if not deploy_enabled:
        return "SKIPPED"
    return "NOT_RUN"


def build_evidence(reports: Path, pipeline_result: str, deploy_enabled: bool = True) -> dict:
    reports = Path(reports)
    build = parsers.load_json(reports / "build.json") or {}
    gate = parsers.load_json(reports / "gate.json")
    deploy = parsers.load_json(reports / "deploy.json")
    zap = parsers.parse_zap(reports / "dast" / "zap.json")
    dast_status = parsers.load_json(reports / "dast" / "dast.status.json")
    stage_status = {}
    for name in ("build", "secrets", "tests/tests", "scan"):
        s = parsers.load_json(reports / f"{name}.status.json")
        if s:
            stage_status[name.split("/")[-1]] = s

    vulns = (gate or {}).get("vulnerabilities", {})
    vuln_counts = {img: v.get("counts") for img, v in vulns.items() if v.get("present")}
    tests = (gate or {}).get("tests") or parsers.parse_junit(reports / "tests" / "junit.xml")
    sonar = (gate or {}).get("sonar") or parsers.parse_sonar(reports / "sonar.json")

    evidence = {
        "schema": "secureship/evidence/v1",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "pipeline_result": pipeline_result,
        "build": {
            "number": build.get("build_number"),
            "url": build.get("build_url"),
            "job": build.get("job_name"),
            "started_at": build.get("started_at"),
            "triggered_by": build.get("triggered_by"),
        },
        "source": {
            "repo": build.get("app_repo"),
            "branch": build.get("app_branch"),
            "commit": build.get("app_commit"),
            "commit_message": build.get("commit_message"),
            "commit_author": build.get("commit_author"),
            "pipeline_commit": build.get("pipeline_commit"),
        },
        "images": {
            "tag": build.get("app_tag"),
            **{img: {k: m.get(k) for k in ("image", "id", "user", "size_mb")}
               for img, m in ((gate or {}).get("image_meta") or parsers.load_json(reports / "image-meta.json") or {}).items()},
        },
        "tests": {k: tests.get(k) for k in ("present", "tests", "passed", "failures", "errors", "skipped",
                                            "time_s", "coverage_pct", "failed_cases")},
        "sonar": {"status": sonar.get("status"), "dashboard_url": sonar.get("dashboard_url"),
                  "conditions": sonar.get("conditions", [])},
        "vulnerability_counts": vuln_counts,
        "secrets_found": len(((gate or {}).get("secrets") or {}).get("open", [])) if gate else None,
        "misconfigurations": len(((gate or {}).get("misconfigurations") or {}).get("open", [])) if gate else None,
        "gate": {
            "decision": (gate or {}).get("decision", "NOT_REACHED"),
            "risk_score": (gate or {}).get("risk_score"),
            "risk_band": (gate or {}).get("risk_band"),
            "blocking_reasons": (gate or {}).get("blocking_reasons", []),
            "checks": (gate or {}).get("checks", []),
        },
        "deployment": {
            "status": _deploy_status(deploy, gate, deploy_enabled),
            "target": (deploy or {}).get("host") or build.get("deploy_host"),
            "chaos_mode": (deploy or {}).get("chaos_mode") or build.get("chaos_mode"),
            "new_release": (deploy or {}).get("new_release"),
            "previous_release": (deploy or {}).get("previous_release"),
            "health": (deploy or {}).get("health"),
            "rollback": (deploy or {}).get("rollback"),
            "backup": (deploy or {}).get("backup"),
            "duration_s": (deploy or {}).get("duration_s"),
        },
        "dast": {"ran": zap["present"], "status": (dast_status or {}).get("status"),
                 "target": (dast_status or {}).get("target"), "alert_counts": zap["counts"] if zap["present"] else None},
        "stage_status": stage_status,
        "artifacts": sorted(str(p.relative_to(reports)) for p in reports.rglob("*")
                            if p.is_file() and p.name not in ("evidence.json", "evidence.html")),
    }
    return evidence


# ======================================================================= HTML
CSS = """
:root{--bg:#f5f6f8;--card:#fff;--ink:#14181f;--muted:#5d6675;--line:#e3e6eb;--ok:#127a46;--okbg:#e5f5ec;
--bad:#b42318;--badbg:#fdecea;--warn:#9a5b00;--warnbg:#fff4e0;--info:#1d4ed8;--infobg:#e8efff;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#0f1217;--card:#171b22;--ink:#e7eaf0;--muted:#98a2b3;--line:#2a303a;
--ok:#4ade80;--okbg:#10291b;--bad:#f87171;--badbg:#2d1414;--warn:#fbbf24;--warnbg:#2b2210;--info:#93b4ff;--infobg:#141f38}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:28px 16px 60px}
header{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-end;justify-content:space-between;margin-bottom:20px}
h1{font-size:22px;margin:0}h2{font-size:15px;margin:0 0 12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
.sub{color:var(--muted);font-size:13px}
.verdict{border-radius:14px;padding:18px 22px;display:flex;flex-wrap:wrap;gap:24px;align-items:center;margin-bottom:18px;border:1px solid var(--line);background:var(--card)}
.verdict .big{font-size:26px;font-weight:700}
.pill{display:inline-block;padding:2px 10px;border-radius:999px;font-weight:600;font-size:12px;letter-spacing:.03em}
.PASS,.OK,.DEPLOYED,.SUCCESS{background:var(--okbg);color:var(--ok)}
.FAIL,.ERROR,.FAILED,.FAILURE,.ROLLBACK_FAILED,.BLOCKED_BY_GATE{background:var(--badbg);color:var(--bad)}
.WARN,.ROLLED_BACK,.UNSTABLE,.SKIPPED,.NOT_RUN,.NOT_REACHED,.MISSING{background:var(--warnbg);color:var(--warn)}
.INFO,.SKIP{background:var(--infobg);color:var(--info)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:14px;overflow-x:auto}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;font-size:13px}.kv dt{color:var(--muted)}.kv dd{margin:0;word-break:break-all}
.stat{font-size:28px;font-weight:700}.mono{font-family:var(--mono);font-size:12px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px}
.sev{display:inline-block;min-width:68px;text-align:center}
.CRITICAL{background:var(--badbg);color:var(--bad)}.HIGH{background:var(--warnbg);color:var(--warn)}
.MEDIUM{background:var(--infobg);color:var(--info)}.LOW,.UNKNOWN{background:var(--line);color:var(--muted)}
.bars{display:flex;gap:10px;flex-wrap:wrap}.bars div{flex:1;min-width:70px;border-radius:10px;padding:8px 10px}
.bars b{display:block;font-size:22px}.muted{color:var(--muted)}footer{margin-top:28px;color:var(--muted);font-size:12px}
a{color:var(--info)}
"""


def _pill(value) -> str:
    v = str(value if value is not None else "N/A")
    return f'<span class="pill {E(v)}">{E(v)}</span>'


def _kv(rows) -> str:
    return '<dl class="kv">' + "".join(f"<dt>{E(k)}</dt><dd>{v}</dd>" for k, v in rows) + "</dl>"


def _anchor_summary(check: dict | None) -> str:
    info = (check or {}).get("anchor_check")
    if not info:
        return _pill("WARN") + " none checked – deleting the newest entries would not be detected"
    sources = ", ".join((check or {}).get("anchor_sources") or []) or "anchor file"
    text = f' {info["anchors"]} anchor(s) from {sources} match; previous entries anchored through #{info["anchored_through"]}.'
    text += " This entry's anchor is written right after this report."
    return _pill("PASS" if check.get("ok") else "FAIL") + E(text)


def render_html(evidence: dict, gate: dict | None, ledger_entry: dict | None,
                history: list[dict], ledger_check: dict | None) -> str:
    b, s, img, dep = evidence["build"], evidence["source"], evidence["images"], evidence["deployment"]
    g = evidence["gate"]
    t = evidence["tests"]
    commit = s.get("commit") or ""
    title = f'SecureShip evidence · build #{b.get("number") or "?"}'

    # verdict banner
    verdict = f"""
<section class="verdict">
  <div><div class="sub">Security gate</div><div class="big">{_pill(g["decision"])}</div></div>
  <div><div class="sub">Deployment</div><div class="big">{_pill(dep["status"])}</div></div>
  <div><div class="sub">Pipeline result</div><div class="big">{_pill(evidence["pipeline_result"])}</div></div>
  <div><div class="sub">Residual risk</div><div class="big">{E(str(g.get("risk_score") if g.get("risk_score") is not None else "–"))}<span class="sub"> /100 {E(g.get("risk_band") or "")}</span></div></div>
</section>"""

    reasons = ""
    if g.get("blocking_reasons"):
        reasons = '<section class="card"><h2>Why the release was blocked</h2><ul>' + "".join(
            f"<li>{E(r)}</li>" for r in g["blocking_reasons"]) + "</ul></section>"

    meta = f"""
<div class="grid">
 <section class="card"><h2>Build</h2>{_kv([
    ("Build", E(str(b.get("number")))),
    ("Job", E(str(b.get("job") or ""))),
    ("Started", E(str(b.get("started_at") or ""))),
    ("Trigger", E(str(b.get("triggered_by") or ""))),
    ("Jenkins", f'<a href="{E(b["url"])}">open build</a>' if b.get("url") else "–")])}</section>
 <section class="card"><h2>Source</h2>{_kv([
    ("Repository", E(str(s.get("repo") or ""))),
    ("Branch", E(str(s.get("branch") or ""))),
    ("Commit", f'<span class="mono">{E(commit[:12])}</span>'),
    ("Message", E(str(s.get("commit_message") or ""))),
    ("Author", E(str(s.get("commit_author") or "")))])}</section>
 <section class="card"><h2>Images</h2>{_kv([("Tag", f'<span class="mono">{E(str(img.get("tag")))}</span>')] + [
    (name, f'<span class="mono">{E(str((img.get(name) or {}).get("id") or "")[:19])}</span> · user {E(str((img.get(name) or {}).get("user") or "?"))} · {E(str((img.get(name) or {}).get("size_mb") or "?"))} MB')
    for name in ("backend", "frontend") if img.get(name)])}</section>
</div>"""

    # gate checks
    checks = "".join(f"<tr><td>{_pill(c['status'])}</td><td>{E(c['name'])}</td><td>{E(c['detail'])}</td></tr>"
                     for c in g.get("checks", []))
    checks_html = (f'<section class="card"><h2>Policy checks</h2><table><tr><th>Result</th><th>Check</th><th>Detail</th></tr>{checks}</table></section>'
                   if checks else '<section class="card"><h2>Policy checks</h2><p class="muted">The security gate was not reached in this run.</p></section>')

    # tests + sonar + dast
    sonar = evidence["sonar"]
    dast = evidence["dast"]
    cov = t.get("coverage_pct")
    test_card = f"""
<div class="grid">
 <section class="card"><h2>Tests</h2>
   <div class="stat">{E(str(t.get("passed") if t.get("present") else "–"))}<span class="sub"> / {E(str(t.get("tests") or 0))} passed</span></div>
   <div class="sub">{E(str(t.get("failures") or 0))} failed · {E(str(t.get("errors") or 0))} errors · {E(str(t.get("skipped") or 0))} skipped · coverage {E(str(cov) + "%" if cov is not None else "n/a")}</div>
   {"<ul class='mono'>" + "".join(f"<li>{E(c)}</li>" for c in (t.get("failed_cases") or [])[:8]) + "</ul>" if t.get("failed_cases") else ""}
 </section>
 <section class="card"><h2>SonarQube</h2><div class="stat">{_pill(sonar.get("status"))}</div>
   <div class="sub">{"<a href='" + E(sonar["dashboard_url"]) + "'>dashboard</a>" if sonar.get("dashboard_url") else ""}</div>
   {"<table>" + "".join(f"<tr><td>{E(str(c.get('metricKey')))}</td><td>{_pill(c.get('status'))}</td><td class='mono'>{E(str(c.get('actualValue', '')))} {E(str(c.get('comparator', '')))} {E(str(c.get('errorThreshold', '')))}</td></tr>" for c in sonar.get("conditions", [])) + "</table>" if sonar.get("conditions") else ""}
 </section>
 <section class="card"><h2>DAST (OWASP ZAP baseline)</h2>
   {("<div class='bars'>" + "".join(f"<div class='{ {'HIGH': 'CRITICAL', 'MEDIUM': 'HIGH', 'LOW': 'MEDIUM', 'INFO': 'LOW'}[k] }'><b>{v}</b>{k.title()}</div>" for k, v in (dast.get("alert_counts") or {}).items()) + "</div><div class='sub' style='margin-top:8px'>Target " + E(str(dast.get("target") or "")) + "</div>") if dast.get("ran") else "<p class='muted'>Not run (runs only after a healthy deployment).</p>"}
 </section>
</div>"""

    # vulnerabilities
    vuln_html = ""
    for name, v in ((gate or {}).get("vulnerabilities") or {}).items():
        if not v.get("present"):
            vuln_html += f'<section class="card"><h2>Vulnerabilities · {E(name)}</h2><p>{_pill("MISSING")} no Trivy report</p></section>'
            continue
        c = v["counts"]
        bars = "".join(f"<div class='{sev}'><b>{c.get(sev, 0)}</b>{sev.title()} <span class='sub'>({v['fixable'].get(sev, 0)} fixable)</span></div>"
                       for sev in ("CRITICAL", "HIGH", "MEDIUM", "LOW"))
        rows = "".join(
            f"<tr><td><span class='pill sev {E(f['severity'])}'>{E(f['severity'])}</span></td>"
            f"<td class='mono'>{('<a href=' + chr(34) + E(f['url']) + chr(34) + '>' + E(f['id']) + '</a>') if f['url'] else E(f['id'])}</td>"
            f"<td>{E(f['package'])}</td><td class='mono'>{E(f['installed'])}</td><td class='mono'>{E(f['fixed'] or '—')}</td>"
            f"<td>{E(f['title'])}</td></tr>" for f in v.get("top", []))
        waived = "".join(f"<li class='mono'>{E(w['id'])} ({E(w['package'])}) – accepted by {E(str(w['waived_by']))} until {E(str(w['waiver_expires']))}</li>"
                         for w in v.get("waived", []))
        vuln_html += f"""<section class="card"><h2>Vulnerabilities · {E(name)} <span class="sub">{E(str(v.get("os") or ""))}</span></h2>
<div class="bars">{bars}</div>
{"<table style='margin-top:12px'><tr><th>Severity</th><th>ID</th><th>Package</th><th>Installed</th><th>Fixed in</th><th>Title</th></tr>" + rows + "</table>" if rows else "<p class='muted'>No open findings.</p>"}
{"<h2 style='margin-top:14px'>Accepted risks</h2><ul>" + waived + "</ul>" if waived else ""}</section>"""

    # deployment
    health = dep.get("health") or {}
    rb = dep.get("rollback") or {}
    deploy_html = f"""<section class="card"><h2>Deployment</h2>{_kv([
        ("Status", _pill(dep["status"])),
        ("Target", E(str(dep.get("target") or "–"))),
        ("New release", f'<span class="mono">{E(json.dumps(dep.get("new_release")) if dep.get("new_release") else "–")}</span>'),
        ("Previous release", f'<span class="mono">{E(json.dumps(dep.get("previous_release")) if dep.get("previous_release") else "none (first deploy)")}</span>'),
        ("Health check", (_pill("PASS" if health.get("passed") else "FAIL") + f' {E(str(health.get("detail") or ""))} · {E(str(health.get("attempts") or 0))} attempts · {E(str(health.get("elapsed_s") or 0))}s') if health else "–"),
        ("Version served", f'<span class="mono">{E(str(health.get("version_seen") or "–"))}</span>'),
        ("Rollback", (_pill("ROLLED_BACK" if rb.get("success") else "ROLLBACK_FAILED") + f' restored {E(json.dumps(rb.get("restored_release")))}') if rb.get("performed") else "not needed"),
        ("DB backup", E(str((dep.get("backup") or {}).get("file") or "–"))),
        ("Chaos mode", E(str(dep.get("chaos_mode") or "none"))),
        ("Duration", E(str(dep.get("duration_s") or "–")) + "s")])}</section>"""

    # ledger
    if ledger_entry:
        chain_ok = ledger_check["ok"] if ledger_check else None
        ledger_html = f"""<section class="card"><h2>Tamper-evident ledger</h2>{_kv([
            ("Entry", f"#{ledger_entry['seq']}"),
            ("Evidence SHA-256", f'<span class="mono">{E(ledger_entry["evidence_sha256"])}</span>'),
            ("Entry hash", f'<span class="mono">{E(ledger_entry["hash"])}</span>'),
            ("Previous hash", f'<span class="mono">{E(ledger_entry["prev_hash"])}</span>'),
            ("Signed (HMAC)", "yes" if ledger_entry.get("hmac") else "no"),
            ("Chain verification", _pill("PASS" if chain_ok else "FAIL") + (
                "" if chain_ok else " " + E("; ".join(ledger_check.get("problems", [])[:3])))),
            ("External anchors", _anchor_summary(ledger_check))])}</section>"""
    else:
        ledger_html = ""

    hist_rows = "".join(
        f"<tr><td>#{h.get('seq')}</td><td>{E(str(h.get('build')))}</td><td class='mono'>{E(str(h.get('app_tag') or ''))}</td>"
        f"<td>{_pill(h.get('gate_decision'))}</td><td>{_pill(h.get('deploy_status'))}</td><td>{E(str(h.get('risk_score')))}</td>"
        f"<td class='mono'>{E(str(h.get('timestamp'))[:19].replace('T', ' '))}</td></tr>"
        for h in reversed(history[-12:]))
    history_html = (f'<section class="card"><h2>Release history</h2><table><tr><th>Ledger</th><th>Build</th><th>Tag</th>'
                    f'<th>Gate</th><th>Deploy</th><th>Risk</th><th>UTC</th></tr>{hist_rows}</table></section>') if hist_rows else ""

    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{E(title)}</title><style>{CSS}</style></head>
<body><div class="wrap">
<header><div><h1>SecureShip · Release evidence</h1>
<div class="sub">ShopPilot · build #{E(str(b.get("number")))} · commit <span class="mono">{E(commit[:12])}</span> · generated {E(evidence["generated_at"])}</div></div>
<div class="sub">schema {E(evidence["schema"])}</div></header>
{verdict}{reasons}{meta}{checks_html}{test_card}{vuln_html}{deploy_html}{ledger_html}{history_html}
<footer>Generated by SecureShip. evidence.json is hashed into the deployment ledger; verify with
<span class="mono">python3 -m secureship ledger verify --evidence reports/evidence.json</span>.</footer>
</div></body></html>"""


def console_summary(evidence: dict) -> str:
    g, d, t = evidence["gate"], evidence["deployment"], evidence["tests"]
    lines = [
        "=" * 64,
        f" SecureShip evidence – build #{evidence['build'].get('number')}  commit {str(evidence['source'].get('commit') or '')[:12]}",
        "=" * 64,
        f" Gate decision : {g['decision']}   risk {g.get('risk_score')}/100 {g.get('risk_band') or ''}",
        f" Tests         : {t.get('passed')}/{t.get('tests')} passed, coverage {t.get('coverage_pct')}%",
        f" SonarQube     : {evidence['sonar'].get('status')}",
    ]
    for img, c in (evidence.get("vulnerability_counts") or {}).items():
        lines.append(f" Trivy {img:<8}: C={c['CRITICAL']} H={c['HIGH']} M={c['MEDIUM']} L={c['LOW']}")
    restored = (d.get("rollback") or {}).get("restored_release") or {}
    lines.append(f" Deployment    : {d['status']}" + (
        f" (restored backend {restored.get('backend')}, frontend {restored.get('frontend')})"
        if (d.get("rollback") or {}).get("performed") else ""))
    for r in g.get("blocking_reasons", []):
        lines.append(f"   ✗ {r}")
    lines.append("=" * 64)
    return "\n".join(lines)
