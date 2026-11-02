# Start here: first real run on your Windows laptop

This is the exact order. Each step has a check, so you know it worked before moving on.
Total time: about 1–2 hours, most of it downloads and the first build.

---

## Step 0: Free space (needs about 25 GB)

The lab needs roughly 25 GB on C:. That covers:
- Jenkins and SonarQube
- the scanner build
- ShopPilot's images, which include PyTorch
- the vulnerability database

**Check:** Settings → System → Storage. Free space should be **≥ 25 GB**.

If you're short, the Kali VM folder in Downloads (48.8 GB) is the only item big enough on its own. Move it to another drive, or remove it through VMware (right-click the VM → Manage → Delete from Disk) if you no longer need it.

## Step 1: Docker Desktop

1. Install it with `Docker Desktop Installer.exe` (in Downloads). Keep **"Use WSL 2"** ticked.
2. Start Docker Desktop and wait for **"Engine running"**.
3. Docker Desktop → Settings → Resources: give it **8 GB RAM**. If there's no slider (WSL 2 mode), create `C:\Users\Hrushika\.wslconfig` with:
   ```
   [wsl2]
   memory=8GB
   ```
   then run `wsl --shutdown` in PowerShell and restart Docker Desktop.

**Check:** in Git Bash, `docker run --rm hello-world` prints "Hello from Docker!".

## Step 2: Push ShopPilot's health endpoint

The `/health` files were already added to your `SareeERP-Pro` folder. They only need committing:

```bash
cd ~/SareeERP-Pro
git status                      # shows: main.py modified, health.py + test_health.py new
git add backend/app/routers/health.py backend/tests/test_health.py backend/app/main.py
git commit -m "Add /health endpoint for deployment health checks"
git push origin master
```

**Check:** on GitHub, `shoppilot/backend/app/routers/health.py` exists on `master`.
Without it, *every* deployment fails its health check and rolls back. The pre-flight check (step 4) catches this.

## Step 3: Put SecureShip on GitHub

1. On GitHub, create a new **empty** repository named `SecureShip-DevSecOps-Pipeline`: public, no README.
2. In Git Bash, inside the SecureShip folder (unzipped from `SecureShip-DevSecOps-Pipeline.zip`):

```bash
cd ~/Documents/SecureShip-DevSecOps-Pipeline     # wherever you unzipped it
git init -b main
git add .
git status                      # make sure NO ci/.env and NO ci/keys/ are listed
git commit -m "SecureShip: security-gated DevSecOps pipeline for ShopPilot"
git remote add origin https://github.com/hrushikapendharkar4241-droid/SecureShip-DevSecOps-Pipeline.git
git push -u origin main
```

**Check:** the repository page on GitHub shows the README with the architecture diagram.

## Step 4: Pre-flight check

```bash
./ci/preflight.sh
```

Every line should be **PASS**. A FAIL line tells you exactly what to fix. It checks:
- tools
- that Docker is running, with enough RAM
- free disk
- ports 8080, 9000, 8088 and 2222
- both repos, and that ShopPilot on GitHub has `/health`

## Step 5: Start the lab

ShopPilot's GitHub repository (`hrushikapendharkar4241-droid/shoppilot`) is **private**. Jenkins runs in a container without your GitHub login, so it needs its own **read-only token**. Create it first (2 minutes):

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Repository access: **Only select repositories → `shoppilot`**.
3. Permissions: Repository permissions → **Contents → Read-only**. Nothing else.
4. Expiration: 90 days. Copy the token.

```bash
./ci/bootstrap.sh
```

When asked, paste the token. The input is hidden. Bootstrap checks the token against GitHub, then stores it:
- in `ci/.env`, which is git-ignored
- as the Jenkins credential `shoppilot-git`

The token never goes into a URL, a log or Git.

The first run takes 15–40 minutes, depending on your internet. It builds Trivy and Gitleaks from source and downloads SonarQube. At the end it prints the Jenkins password.

**Check:**

| Open | You should see |
|---|---|
| http://localhost:8080 | Jenkins login. Log in with the printed password; a job named **SecureShip** exists. |
| http://localhost:9000 | SonarQube. Password = `SONAR_ADMIN_PASSWORD` in `ci/.env`. |

Optional: once it works, `docker builder prune -a` gives back a few GB of build cache. The next `bootstrap.sh` rebuild will then be slower.

## Step 6: First pipeline run

1. Jenkins → **SecureShip** → **Build Now**. The first run also registers the parameters.
2. Watch it in **Stage View**. The first build takes 20–40 minutes because of the PyTorch download and the Trivy DB; later builds are much faster.
3. When it's green, open **http://localhost:8088**. That's ShopPilot, deployed by the pipeline. Sign up and use it.
4. Build page → **Artifacts → reports/evidence.html**. That's your release passport.

If a stage fails, open the stage log. Then check the troubleshooting table in [SETUP.md](SETUP.md), or send me the console output.

**A first-run gate failure is not a bug.** If the gate blocks on real HIGH/CRITICAL CVEs in ShopPilot's dependencies, the pipeline is doing its job:
- Read `reports/gate.json`.
- Upgrade the package if a fixed version exists.
- Otherwise, add an honest, expiring entry to `security/exceptions.yaml`.

## Step 7: Demo scenarios and screenshots

Run them as written in [DEMO_SCENARIOS.md](DEMO_SCENARIOS.md):

| # | Scenario | Screenshot |
|---|---|---|
| 1 | Clean release (run it **twice**) | green Stage View + evidence `DEPLOYED` |
| 2 | Vulnerable dependency (`demo/vulnerable-dep` branch) | gate FAIL + `BLOCKED_BY_GATE` |
| 3 | Failing test | gate FAIL listing the test |
| 4 | Hard-coded fake token | gate FAIL `github-pat` |
| 5 | `CHAOS_MODE=crash` | console "ROLLING BACK" + evidence `ROLLED_BACK` while :8088 keeps working |
| 6 | Delete the newest ledger entries | chain-only check says OK, `verify-ledger.sh` says FAILED |
| 7 | Expired risk acceptance | finding blocks again |

Create `docs/screenshots/` and save them there. Link the best 3–4 from the README.

## Step 8: Update the README honestly

In README → **Verification status**, change the ⏳ rows you actually completed to ✅. Name the evidence, for example "Jenkins build #7, screenshot `docs/screenshots/rollback.png`".

Then use **Version A** of [RESUME.md](RESUME.md).

## Stopping and starting

```bash
docker compose -f ci/docker-compose.yml stop     # frees RAM; everything is kept
docker compose -f ci/docker-compose.yml start    # resume later
```

Stop the lab when you're not using it, because Jenkins and SonarQube use about 4 GB of RAM.

To remove everything (images, data, secrets):

```bash
docker compose -f ci/docker-compose.yml down -v && rm -rf ci/.env ci/keys
```
