# Release security policy

The policy lives in [`security/policy.yaml`](../security/policy.yaml). `python3 -m secureship gate` evaluates it on every build. **Any FAIL blocks deployment.** Changes to the policy go through Git, so they are reviewed and versioned.

## Checks

| Check | Blocks when | Evidence file |
|---|---|---|
| Automated tests | any failing/erroring test, or no tests at all | `tests/junit.xml` |
| Line coverage | below `tests.min_coverage` (0 by default; raise as tests grow) | `tests/coverage.xml` |
| SonarQube quality gate | status `ERROR`, or the gate could not be evaluated | `sonar.json` |
| Secret scanning | any non-accepted Gitleaks finding in the Git history | `gitleaks.json` |
| Image vulnerabilities (per image) | any **CRITICAL** (fixable or not); any **fixable HIGH** | `trivy-<image>.json` |
| Dockerfile misconfiguration | any CRITICAL/HIGH Trivy config finding | `trivy-config.json` |
| Image hardening | image runs as root; optionally image too large | `image-meta.json` |
| Residual risk score | optional: score above `risk_score.block_above` | computed |

**Fail-closed:** a required check with **no evidence** counts as a failure. For example, Trivy timing out does not let a release through.

## Why "fixable HIGH"?

A HIGH-severity CVE with a published fix can be resolved today by upgrading, so it blocks. A HIGH with no fix available (common in base OS packages) cannot be fixed by the team right now. Blocking every release on it would push people to switch the gate off. Instead, it:
- is listed in the evidence report
- adds to the residual risk score (weighted ×0.5)
- starts blocking automatically once a fix is published and the next build sees a `FixedVersion`

CRITICALs block regardless.

## Residual risk score (0–100)

Sum over open findings of `weight[severity] × (1 if fixable else 0.5)`, plus 2 per blocking misconfiguration, capped at 100.

Default weights: CRITICAL 10, HIGH 4, MEDIUM 1, LOW 0.2.

| Score | Band |
|---|---|
| < 10 | LOW |
| < 30 | MODERATE |
| < 60 | HIGH |
| ≥ 60 | CRITICAL |

The score is reported on every build. Set `block_above` to also gate on accumulated risk.

## Risk acceptances (exceptions)

[`security/exceptions.yaml`](../security/exceptions.yaml) records accepted risks. The gate enforces governance on each entry:

- **Mandatory fields:** `id`, `reason`, `owner`, `expires`. Entries missing any of these are invalid and waive nothing.
- **Maximum window:** `expires − created` must not exceed `exceptions.max_days` (90). An "accept forever" entry is rejected.
- **Automatic expiry:** after `expires`, the entry stops working and the finding blocks again.
- **Early warning:** entries expiring within `warn_days` (14) produce a WARN on every build.
- **Scoping:** `package` and `image` narrow an acceptance so it cannot accidentally cover a different package or image.
- **Types:**
  - `vulnerability` (CVE/GHSA ID)
  - `misconfiguration` (AVD ID, for example `AVD-DS-0026`)
  - `secret` (Gitleaks fingerprint, only for verified false positives)

A good reason states **why the risk is acceptable**, for example "vulnerable XML parser code path is not used by ShopPilot". It also states **when to re-check**.

## Deployment safety rules (enforced by `release.sh`)

1. The database backup must succeed, or the release is aborted before anything changes.
2. The new release must answer `GET /health` with HTTP 200, `"status": "ok"` and the **new version tag**, through NGINX, within `HEALTH_TIMEOUT`.
3. The frontend must serve `/`.
4. On failure, the previous release is restored and re-verified. The result is recorded as `ROLLED_BACK` or `ROLLBACK_FAILED`.
5. Only the current and previous releases' images are kept on the server.

## Deployment ledger

Every build appends one entry to `/var/jenkins_home/secureship/ledger.jsonl`. The entry holds:
- the build number, commit and image tag
- the gate decision, risk score and deployment result
- the SHA-256 of that build's `evidence.json`

### What each layer detects

| Layer | Detects | Does **not** detect |
|---|---|---|
| Hash chain (each entry includes the previous entry's hash) | an entry edited, re-ordered or removed **in the middle** | the **newest** entries deleted, since a shorter chain is still valid; a whole file rewritten with recomputed hashes |
| HMAC-SHA256 per entry (`ledger-hmac-key` in Jenkins Credentials) | a whole file rewritten with recomputed hashes by someone without the key | deletion of the newest entries; an attacker who holds the key |
| **External anchors** (each entry's `seq` + `hash` + `hmac`, appended after every build) | **deletion of the newest entries**, deletion of the whole ledger, and any entry that no longer matches its anchor | an attacker who controls Jenkins **and** every anchor store |

### Anchor stores

1. **Deployment server** (always on when a deploy target is configured): `/opt/secureship/anchors/ledger-anchors.jsonl`. The file is made append-only with `chattr +a` by `target/setup-target.sh` (or the lab target's entrypoint).
   - The `deploy` user, and so a compromised Jenkins holding its SSH key, can add lines but cannot truncate, overwrite or delete the file.
   - Only root on that server can lift the attribute.
   - The pipeline checks the attribute on every write and warns if it is missing (`reports/anchor-status.json`).
2. **Git repository** (optional, recommended): set `ANCHOR_GIT_REPO` (and optionally `ANCHOR_GIT_BRANCH`, default `main`) as a Jenkins global env var. Then add a *Username with password* credential `ledger-anchor-git`:
   - Use a GitHub fine-grained token with **Contents: read and write** on that one repository only.
   - Protect the branch with a ruleset that **blocks force pushes and deletion**, with no bypass.
   - The token cannot change rulesets, which needs the Administration permission, so it can only add commits.
   - GitHub's commit history also gives every anchor an independent timestamp.

### How verification runs

- **Every build** (`scripts/evidence.sh`):
  1. Fetch the anchors from all stores.
  2. Verify chain + HMAC + anchors, then append the new entry.
  3. Anchor the new entry.

  If verification fails, the build is marked FAILURE with `LEDGER INTEGRITY PROBLEM` (`reports/ledger-verify.json`). If an anchor write fails, the build is UNSTABLE.
- **On demand:** `scripts/verify-ledger.sh` (inside the Jenkins container).

### Honest limits

- The lab is a single laptop. The anchor store sits in a different container but under the same administrator. The lab demonstrates the mechanism; real independence needs a separate server or the Git store.
- If the anchor filesystem doesn't support `chattr +a`, anchors are protected only by file permissions, and the pipeline says so.
- Entries written while no anchor store was reachable stay *unanchored* until the next successful build anchors them. They are listed in `ledger-verify.json`.
