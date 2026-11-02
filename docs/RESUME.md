# Resume entry

Only claim what you have **run yourself and can show**: the Jenkins history, `evidence.html` files and screenshots from [DEMO_SCENARIOS.md](DEMO_SCENARIOS.md). Interviewers often ask you to walk through a failure case, so run scenarios 2, 5 and 6 at least once.

## Version A: free local lab (use this now)

**SecureShip — Security-Gated DevSecOps CI/CD Pipeline** | Jenkins, Docker, SonarQube, Trivy, Gitleaks, OWASP ZAP, Linux, Python

- Engineered a Jenkins CI/CD pipeline (configuration-as-code) for a FastAPI/React application. It runs tests inside the built image, SonarQube quality gates, Gitleaks secret scanning and Trivy image/Dockerfile scanning with CycloneDX SBOMs.
- Built a policy-as-code release gate in Python that combines all scan results into one fail-closed deployment decision, with time-boxed risk acceptances (owner, reason, ≤ 90-day expiry) and a residual risk score.
- Implemented SSH-based deployment to a hardened Linux target with pre-release database backups, version-verified health checks and automatic rollback, demonstrated with on-demand chaos testing.
- Generated per-build deployment evidence reports and a tamper-evident release ledger (SHA-256 hash chain, HMAC signatures, external append-only anchors) that detects edited or deleted release records, including truncation of the newest entries. Added post-deployment DAST with OWASP ZAP.
- Hardened the pipeline's own supply chain: scanners built from source and verified against Go's checksum transparency log, plus a fingerprint-pinned Docker repository key and per-build scanner provenance.

## Version B: only after you actually deploy to EC2 (docs/AWS_EC2.md)

Replace the third bullet with:

- Deployed the containerized application to AWS EC2 (Ubuntu) over SSH, with least-privilege Security Groups, a hardened sshd/ufw host configuration, pre-release database backups, version-verified health checks and automatic rollback.

…and add **AWS EC2** to the tech list.

## Honest-claims checklist

- ❌ Never write "tamper-proof". The ledger is **tamper-evident**, and you can explain against whom (docs/SECURITY_POLICY.md#deployment-ledger).

- ✅ "Jenkins pipeline", "SonarQube", "Trivy", "Gitleaks", "OWASP ZAP", "Docker": once the lab pipeline has run end to end
- ✅ "automatic rollback": once you've run `CHAOS_MODE=crash` and seen `ROLLED_BACK`
- ⏳ "AWS EC2": only after a real EC2 deployment
- ⏳ "Kubernetes": not part of this project. Add a Minikube stage first if you want to claim it.
- ⏳ "Cloudflare Tunnel": only if you actually used one (docs/SETUP.md §6)

## One-line summary (for LinkedIn / project section)

> A Jenkins pipeline that decides whether a release is safe *and* healthy enough to run. It blocks vulnerable or failing builds through a policy-as-code gate, rolls back unhealthy deployments automatically, and records every decision in a tamper-evident ledger.
