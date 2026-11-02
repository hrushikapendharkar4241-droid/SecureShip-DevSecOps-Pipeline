"""Policy-as-code security gate.

The gate combines every signal the pipeline produced (tests, coverage, SonarQube,
Trivy image vulnerabilities, Trivy Dockerfile misconfigurations, Gitleaks secrets
and image hardening metadata) into ONE release decision: PASS or FAIL.

What makes it more than "trivy --exit-code 1":
  * A single, versioned YAML policy decides what blocks a release.
  * Risk acceptances (exceptions) MUST carry an owner, a reason and an expiry date.
    Expired or over-long acceptances stop waiving findings, so nothing is ignored forever.
  * Missing evidence is treated as a failure for required checks (fail-closed).
  * A weighted risk score summarises residual risk even when the gate passes.
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path
from typing import Any

import yaml

from secureship import parsers

PASS, FAIL, WARN, SKIP = "PASS", "FAIL", "WARN", "SKIP"

DEFAULT_POLICY: dict[str, Any] = {
    "version": 1,
    "images": ["backend", "frontend"],
    "tests": {"required": True, "max_failures": 0, "min_coverage": 0},
    "sonar": {"required": True},
    "secrets": {"required": True, "max_findings": 0},
    "vulnerabilities": {
        "block": {"CRITICAL": {"max": 0, "only_fixable": False},
                  "HIGH": {"max": 0, "only_fixable": True}},
    },
    "misconfiguration": {"required": True, "block_severities": ["CRITICAL", "HIGH"]},
    "image": {"require_non_root": True, "max_size_mb": None, "size_blocking": False},
    "exceptions": {"max_days": 90, "warn_days": 14},
    "risk_score": {"weights": {"CRITICAL": 10, "HIGH": 4, "MEDIUM": 1, "LOW": 0.2, "UNKNOWN": 0.2},
                   "unfixable_multiplier": 0.5, "misconfig_weight": 2, "block_above": None},
}


# ------------------------------------------------------------------ loading
def _deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load_policy(path: Path | None) -> dict:
    data = {}
    if path and Path(path).exists():
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    return _deep_merge(DEFAULT_POLICY, data)


def _to_date(value: Any) -> dt.date | None:
    if isinstance(value, dt.datetime):
        return value.date()
    if isinstance(value, dt.date):
        return value
    try:
        return dt.date.fromisoformat(str(value))
    except ValueError:
        return None


def load_exceptions(path: Path | None, policy: dict, today: dt.date) -> dict:
    """Validate risk acceptances. Returns active / expired / invalid lists."""
    result = {"active": [], "expired": [], "invalid": [], "expiring_soon": []}
    if not path or not Path(path).exists():
        return result
    with open(path, encoding="utf-8") as fh:
        raw = (yaml.safe_load(fh) or {}).get("exceptions") or []
    max_days = policy["exceptions"].get("max_days")
    warn_days = policy["exceptions"].get("warn_days", 14)
    for idx, exc in enumerate(raw):
        if not isinstance(exc, dict):
            result["invalid"].append({"index": idx, "reason": "entry is not a mapping"})
            continue
        missing = [k for k in ("id", "reason", "owner", "expires") if not exc.get(k)]
        expires = _to_date(exc.get("expires"))
        created = _to_date(exc.get("created")) or today
        entry = {**exc, "type": exc.get("type", "vulnerability"), "expires": str(exc.get("expires"))}
        if missing or expires is None:
            entry["problem"] = f"missing/invalid fields: {', '.join(missing) or 'expires'}"
            result["invalid"].append(entry)
            continue
        if max_days and (expires - created).days > int(max_days):
            entry["problem"] = f"acceptance window {(expires - created).days}d exceeds policy max {max_days}d"
            result["invalid"].append(entry)
            continue
        if expires < today:
            entry["problem"] = f"expired on {expires.isoformat()}"
            result["expired"].append(entry)
            continue
        entry["days_left"] = (expires - today).days
        if entry["days_left"] <= warn_days:
            result["expiring_soon"].append(entry)
        result["active"].append(entry)
    return result


def _waiver_for(finding: dict, kind: str, image: str | None, exceptions: list[dict]) -> dict | None:
    for exc in exceptions:
        if exc.get("type", "vulnerability") != kind or exc["id"] != finding["id"]:
            continue
        if exc.get("package") and exc["package"] != finding.get("package"):
            continue
        if exc.get("image") and image and exc["image"] != image:
            continue
        return exc
    return None


# ------------------------------------------------------------------ evaluation
def evaluate(reports: Path, policy: dict, exceptions: dict, today: dt.date | None = None) -> dict:
    today = today or dt.date.today()
    reports = Path(reports)
    checks: list[dict] = []
    active = exceptions["active"]

    def add(check_id: str, name: str, status: str, detail: str, **extra):
        checks.append({"id": check_id, "name": name, "status": status, "detail": detail, **extra})

    # ---- tests ------------------------------------------------------------
    tpol = policy["tests"]
    tstatus = parsers.load_json(reports / "tests" / "tests.status.json") or {}
    junit = parsers.parse_junit(reports / "tests" / "junit.xml")
    cov = parsers.parse_cobertura(reports / "tests" / "coverage.xml")
    if not junit["present"] or junit["tests"] == 0:
        why = tstatus.get("detail") or "no JUnit results produced"
        add("tests", "Automated tests", FAIL if tpol["required"] else WARN, f"No test results: {why}")
    else:
        bad = junit["failures"] + junit["errors"]
        if bad > int(tpol["max_failures"]):
            add("tests", "Automated tests", FAIL,
                f'{bad} failing of {junit["tests"]} (allowed {tpol["max_failures"]})',
                failed_cases=junit["failed_cases"])
        else:
            add("tests", "Automated tests", PASS, f'{junit["passed"]}/{junit["tests"]} passed, {junit["skipped"]} skipped')
    min_cov = float(tpol.get("min_coverage") or 0)
    if min_cov > 0:
        if cov["line_coverage_pct"] is None:
            add("coverage", "Line coverage", FAIL, f"coverage report missing (min {min_cov}%)")
        elif cov["line_coverage_pct"] < min_cov:
            add("coverage", "Line coverage", FAIL, f'{cov["line_coverage_pct"]}% < required {min_cov}%')
        else:
            add("coverage", "Line coverage", PASS, f'{cov["line_coverage_pct"]}% ≥ {min_cov}%')
    elif cov["line_coverage_pct"] is not None:
        add("coverage", "Line coverage", PASS, f'{cov["line_coverage_pct"]}% (no minimum set)')

    # ---- sonar ------------------------------------------------------------
    sonar = parsers.parse_sonar(reports / "sonar.json")
    if sonar["status"] == "OK":
        add("sonar", "SonarQube quality gate", PASS, "Quality gate passed")
    elif sonar["status"] in ("ERROR", "FAILED"):
        failed = [c.get("metricKey") for c in sonar["conditions"] if c.get("status") == "ERROR"]
        add("sonar", "SonarQube quality gate", FAIL,
            f'Quality gate failed{": " + ", ".join(failed) if failed else ""}')
    elif sonar["status"] == "WARN":
        add("sonar", "SonarQube quality gate", WARN, "Quality gate returned WARN")
    else:
        detail = f'Quality gate not evaluated ({sonar["status"]}{": " + sonar.get("detail", "") if sonar.get("detail") else ""})'
        add("sonar", "SonarQube quality gate", FAIL if policy["sonar"]["required"] else WARN, detail)

    # ---- secrets ----------------------------------------------------------
    leaks = parsers.parse_gitleaks(reports / "gitleaks.json")
    spol = policy["secrets"]
    if not leaks["present"]:
        add("secrets", "Secret scanning", FAIL if spol["required"] else WARN, "Gitleaks report missing")
        open_leaks, waived_leaks = [], []
    else:
        open_leaks, waived_leaks = [], []
        for f in leaks["findings"]:
            w = _waiver_for(f, "secret", None, active)
            (waived_leaks if w else open_leaks).append({**f, **({"waived_by": w["owner"]} if w else {})})
        if len(open_leaks) > int(spol["max_findings"]):
            add("secrets", "Secret scanning", FAIL,
                f"{len(open_leaks)} hard-coded secret(s) found: " + ", ".join(sorted({f['rule'] for f in open_leaks})))
        else:
            add("secrets", "Secret scanning", PASS, f"No secrets ({len(waived_leaks)} accepted)")

    # ---- vulnerabilities (per image) -------------------------------------
    vpol = policy["vulnerabilities"]["block"]
    weights = policy["risk_score"]["weights"]
    unfix_mult = float(policy["risk_score"]["unfixable_multiplier"])
    risk = 0.0
    vuln_summary: dict[str, dict] = {}
    for image in policy["images"]:
        rep = parsers.parse_trivy_vulns(reports / f"trivy-{image}.json")
        counts = {s: 0 for s in parsers.SEVERITIES}
        fixable = {s: 0 for s in parsers.SEVERITIES}
        open_f, waived_f = [], []
        if not rep["present"]:
            add(f"vulns-{image}", f"Image vulnerabilities ({image})", FAIL,
                "Trivy report missing – cannot prove the image is safe")
            vuln_summary[image] = {"present": False}
            continue
        for f in rep["findings"]:
            w = _waiver_for(f, "vulnerability", image, active)
            if w:
                waived_f.append({**f, "waived_by": w["owner"], "waiver_expires": w["expires"]})
                continue
            open_f.append(f)
            counts[f["severity"]] += 1
            if f["fixable"]:
                fixable[f["severity"]] += 1
            risk += float(weights.get(f["severity"], 0)) * (1 if f["fixable"] else unfix_mult)
        violations = []
        for sev, rule in vpol.items():
            sev = sev.upper()
            n = fixable[sev] if rule.get("only_fixable") else counts[sev]
            if n > int(rule.get("max", 0)):
                violations.append(f'{n} {sev}{" fixable" if rule.get("only_fixable") else ""} (max {rule.get("max", 0)})')
        summary = ", ".join(f"{s[0]}:{counts[s]}" for s in ("CRITICAL", "HIGH", "MEDIUM", "LOW"))
        add(f"vulns-{image}", f"Image vulnerabilities ({image})", FAIL if violations else PASS,
            ("Blocked – " + "; ".join(violations) if violations else "Within policy") + f" [{summary}]"
            + (f", {len(waived_f)} accepted" if waived_f else ""))
        sev_rank = {s: i for i, s in enumerate(parsers.SEVERITIES)}
        open_f.sort(key=lambda f: (sev_rank[f["severity"]], not f["fixable"]))
        vuln_summary[image] = {"present": True, "artifact": rep["artifact"], "os": rep["os"],
                               "counts": counts, "fixable": fixable, "total": len(open_f),
                               "top": open_f[:20], "waived": waived_f}

    # ---- misconfiguration -------------------------------------------------
    mpol = policy["misconfiguration"]
    mis = parsers.parse_trivy_config(reports / "trivy-config.json")
    open_m, waived_m = [], []
    if not mis["present"]:
        add("misconfig", "Dockerfile misconfiguration", FAIL if mpol["required"] else WARN,
            "Trivy config report missing")
    else:
        for f in mis["findings"]:
            w = _waiver_for(f, "misconfiguration", None, active)
            (waived_m if w else open_m).append(f)
        blocking = [f for f in open_m if f["severity"] in [s.upper() for s in mpol["block_severities"]]]
        risk += float(policy["risk_score"]["misconfig_weight"]) * len(blocking)
        add("misconfig", "Dockerfile misconfiguration", FAIL if blocking else PASS,
            (f"{len(blocking)} blocking: " + ", ".join(sorted({f['check'] for f in blocking})))
            if blocking else f"{len(open_m)} non-blocking finding(s)")

    # ---- image hardening --------------------------------------------------
    meta = parsers.load_json(reports / "image-meta.json") or {}
    ipol = policy["image"]
    for image in policy["images"]:
        m = meta.get(image)
        if not m:
            add(f"image-{image}", f"Image hardening ({image})", FAIL, "image metadata missing")
            continue
        problems, warnings = [], []
        user = str(m.get("user") or "").strip()
        if ipol.get("require_non_root") and user.split(":")[0] in ("", "root", "0"):
            problems.append(f"runs as root (USER='{user or 'unset'}')")
        max_mb = ipol.get("max_size_mb")
        if max_mb and float(m.get("size_mb") or 0) > float(max_mb):
            (problems if ipol.get("size_blocking") else warnings).append(
                f'size {m.get("size_mb")} MB > {max_mb} MB')
        status = FAIL if problems else WARN if warnings else PASS
        add(f"image-{image}", f"Image hardening ({image})", status,
            "; ".join(problems + warnings) or f"non-root user '{user}', {m.get('size_mb')} MB")

    # ---- exceptions governance -------------------------------------------
    if exceptions["expired"] or exceptions["invalid"]:
        add("exceptions", "Risk acceptances", WARN,
            f'{len(exceptions["expired"])} expired, {len(exceptions["invalid"])} invalid – they no longer waive anything')
    elif exceptions["expiring_soon"]:
        add("exceptions", "Risk acceptances", WARN,
            f'{len(exceptions["expiring_soon"])} acceptance(s) expire within {policy["exceptions"]["warn_days"]} days')
    elif active:
        add("exceptions", "Risk acceptances", PASS, f"{len(active)} active, all valid")

    # ---- risk score -------------------------------------------------------
    risk = round(min(risk, 100.0), 1)
    band = "LOW" if risk < 10 else "MODERATE" if risk < 30 else "HIGH" if risk < 60 else "CRITICAL"
    block_above = policy["risk_score"].get("block_above")
    if block_above is not None:
        add("risk", "Residual risk score", FAIL if risk > float(block_above) else PASS,
            f"{risk}/100 ({band}), limit {block_above}")

    failed = [c for c in checks if c["status"] == FAIL]
    return {
        "decision": FAIL if failed else PASS,
        "evaluated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "policy_version": policy.get("version"),
        "risk_score": risk,
        "risk_band": band,
        "blocking_reasons": [f'{c["name"]}: {c["detail"]}' for c in failed],
        "checks": checks,
        "tests": {**junit, "coverage_pct": cov["line_coverage_pct"], "runner_status": tstatus.get("status")},
        "sonar": sonar,
        "secrets": {"open": open_leaks, "waived": waived_leaks},
        "vulnerabilities": vuln_summary,
        "misconfigurations": {"open": open_m, "waived": waived_m},
        "exceptions": {k: v for k, v in exceptions.items()},
        "image_meta": meta,
    }
