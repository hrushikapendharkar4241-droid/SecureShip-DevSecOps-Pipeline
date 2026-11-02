"""Parsers that turn raw tool output into small, normalised Python dicts.

Every parser is defensive: a missing or corrupt file never raises, it returns
``{"present": False, ...}`` so the gate can decide what "missing evidence" means
(by default: missing evidence for a required check = FAIL).
"""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")


def load_json(path: Path) -> Any | None:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# --------------------------------------------------------------------------- tests
def parse_junit(path: Path) -> dict:
    """Aggregate a JUnit XML file (pytest --junitxml)."""
    result = {"present": False, "tests": 0, "failures": 0, "errors": 0, "skipped": 0,
              "time_s": 0.0, "failed_cases": []}
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return result
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    for suite in suites:
        result["tests"] += int(suite.get("tests", 0))
        result["failures"] += int(suite.get("failures", 0))
        result["errors"] += int(suite.get("errors", 0))
        result["skipped"] += int(suite.get("skipped", 0))
        result["time_s"] += float(suite.get("time", 0) or 0)
        for case in suite.iter("testcase"):
            if case.find("failure") is not None or case.find("error") is not None:
                result["failed_cases"].append(f'{case.get("classname", "")}::{case.get("name", "")}')
    result["present"] = True
    result["passed"] = result["tests"] - result["failures"] - result["errors"] - result["skipped"]
    result["time_s"] = round(result["time_s"], 2)
    result["failed_cases"] = result["failed_cases"][:25]
    return result


def parse_cobertura(path: Path) -> dict:
    try:
        root = ET.parse(path).getroot()
        rate = float(root.get("line-rate"))
        return {"present": True, "line_coverage_pct": round(rate * 100, 1)}
    except (OSError, ET.ParseError, TypeError, ValueError):
        return {"present": False, "line_coverage_pct": None}


# --------------------------------------------------------------------- trivy vulns
def parse_trivy_vulns(path: Path) -> dict:
    """Flatten a `trivy image --format json` report into a de-duplicated finding list."""
    data = load_json(path)
    out = {"present": data is not None, "artifact": None, "os": None, "findings": []}
    if not isinstance(data, dict):
        out["present"] = False
        return out
    out["artifact"] = data.get("ArtifactName")
    meta_os = (data.get("Metadata") or {}).get("OS") or {}
    if meta_os:
        out["os"] = f'{meta_os.get("Family", "")} {meta_os.get("Name", "")}'.strip()
    seen = set()
    for res in data.get("Results") or []:
        for v in res.get("Vulnerabilities") or []:
            key = (v.get("VulnerabilityID"), v.get("PkgName"), v.get("InstalledVersion"))
            if key in seen:
                continue
            seen.add(key)
            sev = (v.get("Severity") or "UNKNOWN").upper()
            fixed = v.get("FixedVersion") or ""
            out["findings"].append({
                "id": v.get("VulnerabilityID", "?"),
                "package": v.get("PkgName", "?"),
                "installed": v.get("InstalledVersion", ""),
                "fixed": fixed,
                "fixable": bool(fixed) or v.get("Status") == "fixed",
                "severity": sev if sev in SEVERITIES else "UNKNOWN",
                "title": (v.get("Title") or "")[:160],
                "url": v.get("PrimaryURL") or "",
                "target": res.get("Target", ""),
                "class": res.get("Class", ""),
            })
    return out


def parse_trivy_config(path: Path) -> dict:
    """Misconfigurations from `trivy config --format json` (only FAIL results)."""
    data = load_json(path)
    out = {"present": isinstance(data, dict), "findings": []}
    if not isinstance(data, dict):
        return out
    for res in data.get("Results") or []:
        for m in res.get("Misconfigurations") or []:
            if (m.get("Status") or "FAIL").upper() != "FAIL":
                continue
            out["findings"].append({
                "id": m.get("AVDID") or m.get("ID") or "?",
                "check": m.get("ID") or "",
                "severity": (m.get("Severity") or "UNKNOWN").upper(),
                "title": m.get("Title") or "",
                "message": (m.get("Message") or "")[:200],
                "target": res.get("Target", ""),
                "resolution": m.get("Resolution") or "",
            })
    return out


# ------------------------------------------------------------------------ secrets
def parse_gitleaks(path: Path) -> dict:
    data = load_json(path)
    if not isinstance(data, list):
        return {"present": False, "findings": []}
    findings = [{
        "id": f.get("Fingerprint") or f'{f.get("File")}:{f.get("RuleID")}:{f.get("StartLine")}',
        "rule": f.get("RuleID", "?"),
        "file": f.get("File", "?"),
        "line": f.get("StartLine"),
        "commit": (f.get("Commit") or "")[:12],
        "author": f.get("Author", ""),
    } for f in data]
    return {"present": True, "findings": findings}


# ------------------------------------------------------------------------- sonar
def parse_sonar(path: Path) -> dict:
    data = load_json(path)
    if not isinstance(data, dict):
        return {"present": False, "status": "MISSING", "conditions": []}
    return {
        "present": True,
        "status": str(data.get("status", "MISSING")).upper(),
        "detail": data.get("detail", ""),
        "conditions": data.get("conditions", []),
        "dashboard_url": data.get("dashboard_url", ""),
    }


# --------------------------------------------------------------------------- zap
ZAP_RISK = {"3": "HIGH", "2": "MEDIUM", "1": "LOW", "0": "INFO"}


def parse_zap(path: Path) -> dict:
    data = load_json(path)
    out = {"present": isinstance(data, dict), "counts": {k: 0 for k in ZAP_RISK.values()}, "alerts": []}
    if not isinstance(data, dict):
        return out
    for site in data.get("site") or []:
        for a in site.get("alerts") or []:
            risk = ZAP_RISK.get(str(a.get("riskcode")), "INFO")
            out["counts"][risk] += 1
            out["alerts"].append({"risk": risk, "name": a.get("name") or a.get("alert", "?"),
                                  "instances": int(a.get("count", 0) or 0),
                                  "plugin": a.get("pluginid", "")})
    order = list(ZAP_RISK.values())
    out["alerts"].sort(key=lambda a: order.index(a["risk"]))
    return out
