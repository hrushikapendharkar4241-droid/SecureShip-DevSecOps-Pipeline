"""SecureShip – release-decision engine for the ShopPilot DevSecOps pipeline.

Sub-modules:
    parsers  – read raw tool output (JUnit, Cobertura, Trivy, Gitleaks, SonarQube, ZAP)
    policy   – policy-as-code security gate with expiring risk acceptances
    ledger   – tamper-evident, hash-chained deployment ledger
    report   – per-build deployment evidence report (JSON + HTML)
"""

__version__ = "1.0.0"
