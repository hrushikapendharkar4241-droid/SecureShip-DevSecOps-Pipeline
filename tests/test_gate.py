import datetime as dt
import json

import yaml

from conftest import JUNIT_FAIL, trivy_report, vuln, write
from secureship import cli, policy

TODAY = dt.date(2026, 11, 2)


def run_gate(reports, policy_file, exceptions=None, tmp=None):
    pol = policy.load_policy(policy_file)
    exc_path = None
    if exceptions is not None:
        exc_path = reports.parent / "exceptions.yaml"
        exc_path.write_text(yaml.safe_dump({"exceptions": exceptions}))
    exc = policy.load_exceptions(exc_path, pol, TODAY)
    return policy.evaluate(reports, pol, exc, TODAY)


def status_of(result, check_id):
    return next(c["status"] for c in result["checks"] if c["id"] == check_id)


def test_clean_build_passes(reports, policy_file):
    res = run_gate(reports, policy_file)
    assert res["decision"] == "PASS", res["blocking_reasons"]
    assert res["risk_score"] > 0          # medium + low still count toward residual risk
    assert res["tests"]["coverage_pct"] == 73.4


def test_critical_vulnerability_blocks(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL", fixed="")]))
    res = run_gate(reports, policy_file)
    assert res["decision"] == "FAIL"
    assert status_of(res, "vulns-backend") == "FAIL"


def test_only_fixable_high_blocks(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-1111", "HIGH", fixed="")]))
    assert run_gate(reports, policy_file)["decision"] == "PASS"     # unfixable HIGH: reported, not blocking
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-1111", "HIGH", fixed="2.0")]))
    assert run_gate(reports, policy_file)["decision"] == "FAIL"     # fixable HIGH: blocks


def test_duplicate_findings_counted_once(reports, policy_file):
    v = vuln("CVE-2024-2222", "HIGH", fixed="")
    write(reports / "trivy-backend.json", trivy_report([v, v, v]))
    res = run_gate(reports, policy_file)
    assert res["vulnerabilities"]["backend"]["counts"]["HIGH"] == 1


def test_valid_exception_waives_finding(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL")]))
    exc = [{"id": "CVE-2024-9999", "package": "openssl", "image": "backend", "reason": "not reachable",
            "owner": "Hrushika", "created": "2026-11-01", "expires": "2026-12-15"}]
    res = run_gate(reports, policy_file, exc)
    assert res["decision"] == "PASS"
    assert res["vulnerabilities"]["backend"]["waived"][0]["waived_by"] == "Hrushika"


def test_expired_exception_no_longer_waives(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL")]))
    exc = [{"id": "CVE-2024-9999", "reason": "temporary", "owner": "Hrushika",
            "created": "2026-09-01", "expires": "2026-10-31"}]
    res = run_gate(reports, policy_file, exc)
    assert res["decision"] == "FAIL"
    assert res["exceptions"]["expired"][0]["id"] == "CVE-2024-9999"
    assert status_of(res, "exceptions") == "WARN"


def test_exception_longer_than_policy_is_rejected(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL")]))
    exc = [{"id": "CVE-2024-9999", "reason": "forever", "owner": "x", "created": "2026-11-01", "expires": "2027-11-01"}]
    res = run_gate(reports, policy_file, exc)
    assert res["decision"] == "FAIL"
    assert "exceeds policy max" in res["exceptions"]["invalid"][0]["problem"]


def test_exception_without_owner_is_invalid(reports, policy_file):
    exc = [{"id": "CVE-2024-9999", "reason": "x", "expires": "2026-12-01"}]
    res = run_gate(reports, policy_file, exc)
    assert res["exceptions"]["invalid"]


def test_exception_scoped_to_other_image_does_not_apply(reports, policy_file):
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL")]))
    exc = [{"id": "CVE-2024-9999", "image": "frontend", "reason": "x", "owner": "y",
            "created": "2026-11-01", "expires": "2026-12-01"}]
    assert run_gate(reports, policy_file, exc)["decision"] == "FAIL"


def test_missing_trivy_report_fails_closed(reports, policy_file):
    (reports / "trivy-frontend.json").unlink()
    res = run_gate(reports, policy_file)
    assert res["decision"] == "FAIL"
    assert status_of(res, "vulns-frontend") == "FAIL"


def test_failing_tests_block(reports, policy_file):
    write(reports / "tests" / "junit.xml", JUNIT_FAIL)
    res = run_gate(reports, policy_file)
    assert res["decision"] == "FAIL"
    blocked = next(c for c in res["checks"] if c["id"] == "tests")
    assert "tests.test_stock::test_no_negative_stock" in blocked["failed_cases"]


def test_no_tests_blocks(reports, policy_file):
    (reports / "tests" / "junit.xml").unlink()
    write(reports / "tests" / "tests.status.json", {"status": "no_tests", "detail": "pytest collected 0 items"})
    res = run_gate(reports, policy_file)
    assert status_of(res, "tests") == "FAIL"


def test_hardcoded_secret_blocks(reports, policy_file):
    write(reports / "gitleaks.json", [{"RuleID": "github-pat", "File": "backend/config.py", "StartLine": 4,
                                       "Commit": "abc123", "Fingerprint": "abc123:backend/config.py:github-pat:4"}])
    res = run_gate(reports, policy_file)
    assert res["decision"] == "FAIL"
    assert "github-pat" in next(c["detail"] for c in res["checks"] if c["id"] == "secrets")


def test_root_image_blocks(reports, policy_file):
    meta = json.loads((reports / "image-meta.json").read_text())
    meta["backend"]["user"] = ""
    write(reports / "image-meta.json", meta)
    assert status_of(run_gate(reports, policy_file), "image-backend") == "FAIL"


def test_sonar_failed_and_missing(reports, policy_file):
    write(reports / "sonar.json", {"status": "ERROR", "conditions": [{"metricKey": "new_coverage", "status": "ERROR"}]})
    res = run_gate(reports, policy_file)
    assert status_of(res, "sonar") == "FAIL" and "new_coverage" in res["blocking_reasons"][0]
    (reports / "sonar.json").unlink()
    assert status_of(run_gate(reports, policy_file), "sonar") == "FAIL"


def test_high_misconfiguration_blocks(reports, policy_file):
    write(reports / "trivy-config.json", {"Results": [{"Target": "Dockerfile.backend", "Misconfigurations": [
        {"ID": "DS002", "AVDID": "AVD-DS-0002", "Severity": "HIGH", "Status": "FAIL", "Title": "Image user should not be 'root'"}]}]})
    res = run_gate(reports, policy_file)
    assert status_of(res, "misconfig") == "FAIL"


def test_cli_exit_codes(reports, policy_file, tmp_path, capsys):
    rc = cli.main(["gate", "--reports", str(reports), "--policy", str(policy_file),
                   "--exceptions", str(tmp_path / "none.yaml"), "--today", "2026-11-02"])
    assert rc == 0 and (reports / "gate.json").exists()
    write(reports / "trivy-backend.json", trivy_report([vuln("CVE-2024-9999", "CRITICAL")]))
    rc = cli.main(["gate", "--reports", str(reports), "--policy", str(policy_file),
                   "--exceptions", str(tmp_path / "none.yaml"), "--today", "2026-11-02"])
    assert rc == 1
    assert "DECISION: FAIL" in capsys.readouterr().out
