# Demo scenarios: prove every control works

Run these after the first successful build. Each one takes a few minutes and produces an `evidence.html` you can screenshot for your portfolio or LinkedIn.

> Tip: do the "bad" scenarios on a throw-away ShopPilot branch (for example `demo/broken`) and set `APP_BRANCH` to it. Your `main` branch and its history stay clean.

---

## 1. Clean release → DEPLOYED

**Do:** *Build with Parameters* with the defaults.

**Expect:**
- every gate check is PASS
- `Deploy + Health Check` is green
- `DAST` runs
- ShopPilot is live at http://localhost:8088

`evidence.html` shows `Security gate PASS · Deployment DEPLOYED` and the version reported by `/health`.

Run it **twice**. The second release has a *previous release* to fall back to, which scenario 5 needs.

## 2. Vulnerable dependency → blocked by the gate

**Do:**

```bash
git checkout -b demo/vulnerable-dep
echo "Jinja2==2.10" >> backend/requirements.txt     # old version with known HIGH CVEs (fixed in later releases)
git commit -am "demo: add vulnerable dependency" && git push -u origin demo/vulnerable-dep
```

Build with `APP_BRANCH=demo/vulnerable-dep`.

**Expect:**
- `Security Gate` fails with `Image vulnerabilities (backend): Blocked – N HIGH fixable (max 0)`
- `Deploy` is **skipped**
- the evidence shows `BLOCKED_BY_GATE` and lists the CVEs with their fixed versions

*Talking point:* the policy blocks only **fixable** HIGHs. Unfixable ones still raise the risk score but don't stop the team, since there's nothing to upgrade to yet.

## 3. Failing test → blocked

**Do:** add `def test_demo_failure(): assert 1 == 2` to `backend/tests/test_demo.py` on a branch.

**Expect:** the gate fails with `Automated tests: 1 failing`. Jenkins' test-result view shows the failure, and the evidence lists the failing test case.

## 4. Hard-coded secret → blocked

**Do:** on a branch, add a file with a **fake** token that matches a GitHub token pattern. Generate one that isn't real:

```bash
python3 -c "import secrets,string; print('GITHUB_TOKEN = \"ghp_' + ''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(36)) + '\"')" > backend/leak_demo.py
```

**Expect:** the gate fails with `Secret scanning: 1 hard-coded secret(s) found: github-pat`. The value is redacted in all reports.

*Talking point:* Gitleaks scans the **entire history**. Deleting the file in a later commit does not remove the finding. The real fix is to rotate the credential.

## 5. Broken release → automatic rollback (the highlight)

**Do:** on `main`, *Build with Parameters* → `CHAOS_MODE=crash`.

The pipeline builds the real image, which passes the gate. It then deploys a *derived* image whose backend exits on start-up.

**Expect in the console:**

```
[target] Current release : 12-a1b2c3d4 12-a1b2c3d4
[target] HEALTH CHECK FAILED for 13-e5f6a7b8-chaos-crash – collecting logs
[target] ROLLING BACK to 12-a1b2c3d4 12-a1b2c3d4
...
New release failed its health check – AUTOMATICALLY ROLLED BACK to the previous version
```

The evidence shows `Deployment ROLLED_BACK`, the failed health detail, the restored release, and the database backup that was taken. http://localhost:8088 keeps working the whole time with the previous version.

**Variant:** `CHAOS_MODE=unhealthy`. The process stays up but `/health` doesn't answer correctly. This proves the check validates behaviour, not just "container running".

## 6. Tampering with the release history → detected (including deleting the newest entries)

Run at least three builds first. Then open a shell in Jenkins:

```bash
docker exec -it secureship-jenkins bash
cd /var/jenkins_home/workspace/SecureShip
export LEDGER_KEY=<LEDGER_HMAC_KEY from ci/.env>  SSH_KEY=/run/secrets/deploy_key
L=/var/jenkins_home/secureship/ledger.jsonl
cp $L /tmp/ledger.bak

scripts/verify-ledger.sh                       # ✔ chain OK, ✔ N anchors match

# A) Edit an old entry
sed -i '1s/"build": "[^"]*"/"build": "999"/' $L
scripts/verify-ledger.sh                       # ✘ entry #1 modified / differs from its anchor
cp /tmp/ledger.bak $L

# B) Delete the two NEWEST entries: the attack a hash chain alone cannot see
head -n -2 /tmp/ledger.bak > $L
python3 -m secureship ledger verify --ledger $L                # ✔ "OK" – the shorter chain is still valid…
scripts/verify-ledger.sh                                       # ✘ …but the anchors say entries #N-1 and #N existed
cp /tmp/ledger.bak $L                                          # restore
```

Part B is the best interview moment: it shows *why* the external anchors exist.

Then show the anchor store can't be quietly rewritten. On the lab target, the deploy user can append but not truncate:

```bash
docker exec -u deploy secureship-lab-target sh -c ': > /opt/secureship/anchors/ledger-anchors.jsonl'
# -> Operation not permitted (append-only), if the filesystem supports chattr +a
docker exec secureship-lab-target lsattr /opt/secureship/anchors/ledger-anchors.jsonl   # shows the 'a' flag
```

If the anchor check fails during a **pipeline run**, the build turns red with `LEDGER INTEGRITY PROBLEM` and `reports/ledger-verify.json` names the entries.

## 7. Expired risk acceptance → blocks again

Take a CVE ID from scenario 2's report and add it to `security/exceptions.yaml` in the SecureShip repo:

```yaml
exceptions:
  - id: CVE-XXXX-YYYY
    type: vulnerability
    reason: demo – accepted temporarily
    owner: Hrushika Pendharkar
    created: 2026-09-01
    expires: 2026-10-01      # already in the past
```

**Expect:** the finding still blocks. The *Risk acceptances* check warns `1 expired – no longer waives anything`.

Change `expires` to a date within 90 days of `created`, and the release passes, with the CVE shown as an accepted risk. Set it more than 90 days out, and the acceptance is rejected as too long.

---

## What to capture for your portfolio

1. Jenkins stage view showing a full green run, a gate-blocked run and a rolled-back run side by side
2. `evidence.html` for scenario 2 (blocked) and scenario 5 (rolled back)
3. The console output of the rollback
4. `verify-ledger.sh` output: OK, then FAILED after deleting the newest entries (while the chain-only check still says OK)
5. The SonarQube dashboard for ShopPilot
6. `architecture/architecture.png`
