# Interview notes: explaining SecureShip

## 30-second pitch

"I built a Jenkins pipeline for my ShopPilot app that doesn't just deploy, it decides whether a release is allowed to run.

Every push is secret-scanned, built into a non-root container, tested inside that exact image, analysed by SonarQube, and scanned by Trivy for CVEs and Dockerfile mistakes. A policy-as-code gate I wrote in Python combines all of that into one pass/fail decision.

If it passes, it's deployed over SSH. The new version must prove it's healthy *and* that it's actually the version serving, or the previous release is restored automatically. Every run produces an evidence report that's hashed into a tamper-evident ledger."

## Likely questions

**Why not just use `trivy --exit-code 1`?**
That checks one tool in isolation. My gate combines tests, coverage, Sonar, secrets, CVEs, misconfigurations and image hardening under one versioned policy. It fails closed when evidence is missing. It supports exceptions with owners and expiry dates, which is how real vulnerability management works.

**What does fail-closed mean here?**
If Trivy crashes or Sonar is down, there's no report. A naive pipeline treats that as "no problems". Mine treats missing evidence for a required check as a failure.

**Why block only *fixable* HIGH vulnerabilities?**
If no patch exists, the team can't act on it, and blocking every release trains people to disable the gate. Unfixable HIGHs still raise the risk score and appear in the report. CRITICALs always block.

**How does rollback work?**
`release.sh` runs on the server:
1. Record the current version.
2. Back up Postgres; abort if the backup fails.
3. `docker compose up` with the new tags.
4. Poll `/health` through NGINX until it returns 200, `status ok` and the new version tag.
5. If that times out, save the logs, start the previous tags again, and re-verify them.

The outcome (DEPLOYED / ROLLED_BACK / ROLLBACK_FAILED) is printed as JSON for the pipeline. I unit-tested every branch with fake docker and curl binaries.

**Why check the version in `/health`?**
During a deploy the old container might still answer. A plain 200 could come from the old version. Requiring the exact new tag proves the new release is the one serving.

**What about database migrations on rollback?**
Rolling back the image doesn't roll back the schema. So migrations should be backward-compatible (expand, then contract), and there's a `pg_dump` before every release for disaster recovery.

**What is the ledger, and is it tamper-proof?**
No. It's *tamper-evident*, and I can say exactly against whom. Each entry stores the SHA-256 of that build's evidence and the hash of the previous entry:
- **Editing or reordering** an old entry breaks the chain.
- **Rewriting the whole file** with recomputed hashes is caught by the HMAC, whose key lives in Jenkins Credentials.
- **Deleting the newest entries** is the gap a hash chain can't see, because a shorter chain is still valid. So after every build the entry's hash is also **anchored outside Jenkins**: in an append-only file on the deploy server (`chattr +a`, so even the deploy user can't truncate it), and optionally in a Git repo with force-push blocked. Verification compares the ledger with those anchors.

To rewrite history undetected, an attacker now needs Jenkins **and** root on the server (and the Git repo's admin account). That's the honest boundary.

**How are secrets handled?**
- Jenkins Credentials: SSH key, Sonar token, HMAC key.
- A `chmod 600` `.env` on the server for app secrets.
- Never in Git (Gitleaks enforces it) and never in images (`.dockerignore` excludes `.env`).

**What's insecure about your lab, honestly?**
- Jenkins has the Docker socket, which is root-equivalent on that host.
- The DinD target is privileged.
- The SSH host key is trusted on first use.

In production I'd use isolated build agents with rootless BuildKit or Kaniko, a real VM, a pinned host key, and a private registry with signed images.

**How do you know your scanners themselves aren't compromised?**
In March 2026, attackers compromised Trivy's release process and published a malicious v0.69.4. My first version checked the binary against the checksum file *from the same release*. I realised that proves nothing if the release is compromised, because whoever replaces the binary replaces the checksum too.

So now:
- Trivy and Gitleaks are pinned to reviewed versions and **built from source**.
- Every module is verified against Go's checksum database, a public append-only log whose key ships in the Go toolchain, so a version's content can't be swapped later.
- Docker's apt key is pinned by fingerprint.
- Each build records the scanners' module hashes as provenance.

Remaining gaps I'd close next: base images pinned by digest and hash-pinned Python dependencies.

**Has the whole pipeline been run end to end?**
Answer truthfully with your status. The engine's logic has 45 automated tests. ShopPilot's 303 tests pass with the health endpoint. The release/rollback logic is tested against simulated Docker. The full Docker run is what the demo screenshots show, so do it before the interview.

**What does DAST add?**
SAST and SCA look at code and packages. ZAP probes the running app like an attacker would: headers, cookies, information leaks. It runs after a healthy deploy and is report-only by default.

**What would you add next?**
- Image signing with cosign, verified on the target
- A private registry
- A Kubernetes (Minikube) deployment with readiness probes
- Blue-green deploys for zero downtime
- Slack or email notifications
- Raising the coverage threshold as ShopPilot's tests grow
