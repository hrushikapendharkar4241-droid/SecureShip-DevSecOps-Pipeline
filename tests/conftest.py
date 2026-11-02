"""Shared fixtures: build a realistic reports/ directory like the pipeline produces."""

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

JUNIT_OK = """<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" errors="0" failures="0" skipped="1" tests="12" time="3.21">
<testcase classname="tests.test_sales" name="test_create_sale" time="0.1"/>
</testsuite></testsuites>"""

JUNIT_FAIL = """<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" errors="0" failures="2" skipped="0" tests="12" time="3.21">
<testcase classname="tests.test_stock" name="test_no_negative_stock"><failure message="boom"/></testcase>
<testcase classname="tests.test_sales" name="test_gst_total"><failure message="boom"/></testcase>
</testsuite></testsuites>"""

COVERAGE = '<?xml version="1.0" ?><coverage line-rate="0.734" branch-rate="0" version="7.4"></coverage>'


def vuln(vid, sev, pkg="openssl", fixed="3.0.15-1", status=None):
    v = {"VulnerabilityID": vid, "PkgName": pkg, "InstalledVersion": "1.0", "FixedVersion": fixed,
         "Severity": sev, "Title": f"{vid} title", "PrimaryURL": f"https://avd.aquasec.com/nvd/{vid.lower()}"}
    if status:
        v["Status"] = status
    return v


def trivy_report(vulns, name="shoppilot-backend:1-abc"):
    return {"SchemaVersion": 2, "ArtifactName": name,
            "Metadata": {"OS": {"Family": "debian", "Name": "12.7"}},
            "Results": [{"Target": f"{name} (debian 12.7)", "Class": "os-pkgs", "Vulnerabilities": vulns}]}


def write(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")


@pytest.fixture
def reports(tmp_path):
    """A clean, passing set of pipeline reports."""
    r = tmp_path / "reports"
    write(r / "tests" / "junit.xml", JUNIT_OK)
    write(r / "tests" / "coverage.xml", COVERAGE)
    write(r / "tests" / "tests.status.json", {"status": "ran", "exit_code": 0})
    write(r / "sonar.json", {"status": "OK", "conditions": [], "dashboard_url": "http://sonarqube:9000/dashboard?id=shoppilot"})
    write(r / "gitleaks.json", [])
    write(r / "trivy-backend.json", trivy_report([vuln("CVE-2024-0001", "MEDIUM"), vuln("CVE-2024-0002", "LOW", fixed="")]))
    write(r / "trivy-frontend.json", trivy_report([], name="shoppilot-frontend:1-abc"))
    write(r / "trivy-config.json", {"Results": [{"Target": "Dockerfile.backend", "Misconfigurations": []}]})
    write(r / "image-meta.json", {
        "backend": {"image": "shoppilot-backend:1-abc", "id": "sha256:aaa", "user": "app", "size_mb": 1800},
        "frontend": {"image": "shoppilot-frontend:1-abc", "id": "sha256:bbb", "user": "101", "size_mb": 48},
    })
    write(r / "build.json", {"build_number": "7", "app_commit": "a1b2c3d4e5f6a7b8", "app_tag": "7-a1b2c3d4",
                             "app_repo": "https://github.com/x/ShopPilot.git", "app_branch": "main"})
    return r


@pytest.fixture
def policy_file():
    return ROOT / "security" / "policy.yaml"
