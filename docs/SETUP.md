# Setup guide (free local lab)

## 0. What you need

| | Minimum | Notes |
|---|---|---|
| Docker Desktop | 8 GB RAM assigned (16 GB recommended) | Settings → Resources. SonarQube needs ~2 GB and the ShopPilot backend with EasyOCR ~1.5 GB |
| Disk | **~25 GB free** | Jenkins, SonarQube, the PyTorch layers, the Go build of the scanners and the Trivy DB add up. Check before you start: Docker Desktop fails in confusing ways when the disk fills up. |
| Shell | bash | Linux/macOS terminal, **WSL2** or **Git Bash** on Windows |
| GitHub | two repos | `ShopPilot` (the app) and `SecureShip-DevSecOps-Pipeline` (this repo) |

Everything is free. No cloud account is needed.

## 1. Put the code on GitHub

```bash
cd SecureShip-DevSecOps-Pipeline
git init && git add . && git commit -m "SecureShip DevSecOps pipeline"
git branch -M main
git remote add origin https://github.com/<you>/SecureShip-DevSecOps-Pipeline.git
git push -u origin main
```

**ShopPilot is private.** `ci/bootstrap.sh` detects this and asks for a read-only fine-grained token (Contents: Read-only on `shoppilot` only). It stores the token as the Jenkins credential `shoppilot-git` and uses it automatically. Nothing else is needed.

If the **SecureShip** repo is also private (keep it public, it's your portfolio), add a GitHub fine-grained token as a Jenkins credential:
- type: *Username with password*
- username: your GitHub user
- password: the token

Then:
- For **SecureShip**: add `credentials('<id>')` inside `remote { }` in `ci/jenkins/casc.yaml`.

Public repos need nothing extra.

## 2. Prepare ShopPilot

Follow [SHOPPILOT_INTEGRATION.md](SHOPPILOT_INTEGRATION.md). In short:
- add the `/health` endpoint
- check the folder names (`backend/`, `frontend/`)
- push

## 3. Start the lab

```bash
# from the repo root; set the URLs once (they are written to ci/.env)
SECURESHIP_REPO_URL=https://github.com/<you>/SecureShip-DevSecOps-Pipeline.git \
APP_REPO_URL=https://github.com/<you>/ShopPilot.git \
./ci/bootstrap.sh
```

The script:
1. Creates `ci/.env` with random secrets (git-ignored).
2. Creates `ci/keys/deploy_ed25519` (git-ignored).
3. Starts SonarQube, changes its admin password and creates an analysis token.
4. Builds the Jenkins image: Jenkins LTS, the Docker CLI (repository key pinned by fingerprint), and Trivy & Gitleaks **built from source and verified against Go's checksum database** (adds ~5–10 minutes to the first build; see docs/SUPPLY_CHAIN.md).
5. Starts Jenkins, configured as code:
   - the admin user
   - three credentials: `deploy-ssh-key`, `sonar-token`, `ledger-hmac-key`
   - the `SecureShip` pipeline job
6. Starts `lab-target`: a Linux container with its own Docker engine and an SSH server, standing in for a real server.

## 4. Run the pipeline

1. Open Jenkins at http://localhost:8080 and log in with the credentials the script printed.
2. Open **SecureShip** → **Build Now**.
3. The first run builds with default parameters. From then on, use **Build with Parameters**.

The first build is slow (10–20 minutes) because it downloads the Python/PyTorch layers, the Trivy DB, the scanner and the ZAP images. Later builds reuse the caches.

**Where the results are:**
- Build page → **Artifacts** → `reports/evidence.html`
- `reports/gate.json`, `reports/trivy-backend.json`, and the rest
- The deployed app at http://localhost:8088

New commits to ShopPilot are picked up automatically every ~5 minutes (`pollSCM`).

## 5. Useful commands

```bash
# lab status / logs
docker compose -f ci/docker-compose.yml ps
docker logs -f secureship-jenkins

# what is running on the target
docker exec secureship-lab-target su deploy -c "bash /opt/secureship/scripts/remote/release.sh status"

# manual health check / rollback from your machine
DEPLOY_HOST=localhost DEPLOY_PORT=2222 SSH_KEY=ci/keys/deploy_ed25519 scripts/health-check.sh
DEPLOY_HOST=localhost DEPLOY_PORT=2222 SSH_KEY=ci/keys/deploy_ed25519 scripts/rollback.sh

# verify the tamper-evident ledger (chain + HMAC + external anchors on the target)
docker exec -e LEDGER_KEY="$(grep ^LEDGER_HMAC_KEY ci/.env | cut -d= -f2)" -e SSH_KEY=/run/secrets/deploy_key \
  -e DEPLOY_HOST=lab-target -w /var/jenkins_home/workspace/SecureShip secureship-jenkins scripts/verify-ledger.sh
docker exec -w /var/jenkins_home/workspace/SecureShip secureship-jenkins \
  python3 -m secureship ledger show --ledger /var/jenkins_home/secureship/ledger.jsonl

# stop / start the lab (data is kept in Docker volumes)
docker compose -f ci/docker-compose.yml stop
docker compose -f ci/docker-compose.yml start

# wipe everything and start over
docker compose -f ci/docker-compose.yml down -v && rm -rf ci/.env ci/keys
```

## 6. Optional: public demo URL with Cloudflare Tunnel (free, no account)

Use this to show the deployed ShopPilot to someone without opening any port:

```bash
docker run --rm --network secureship-ci cloudflare/cloudflared:latest tunnel --no-autoupdate --url http://lab-target:8080
# prints https://<random>.trycloudflare.com
```

Quick tunnels are temporary and meant for demos. For a permanent URL, create a named tunnel in a free Cloudflare account.

You can also expose Jenkins the same way and use a **GitHub webhook** instead of polling:
1. Add the webhook in the ShopPilot repo → Settings → Webhooks, with payload URL `https://<tunnel>/github-webhook/`.
2. In the Jenkinsfile, replace `pollSCM` with `githubPush()`.

Only do this with a strong Jenkins password, and stop the tunnel when you are done.

## 7. Lab trade-offs (know these for interviews)

| Shortcut in the lab | Why | Production equivalent |
|---|---|---|
| Jenkins mounts the host Docker socket | Simplest way to build images locally | Dedicated build agents, rootless BuildKit or Kaniko |
| `lab-target` runs privileged (Docker-in-Docker) | Simulates a server without a VM | A real VM/EC2 instance with normal Docker (`target/setup-target.sh`) |
| SSH host key accepted on first use | No pre-provisioned known_hosts | Pin the host key in Jenkins |
| Images streamed over SSH, no registry | Zero accounts or cost | Private registry (GHCR/ECR) with image signing (cosign) |
| `SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true` | Docker Desktop kernel limits | Set `vm.max_map_count` properly |

## 8. Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied ... docker.sock` in Jenkins | Restart the container: `docker restart secureship-jenkins`. The entrypoint adds the jenkins user to the socket's group at start. |
| SonarQube exits / restarts | Give Docker more memory (≥ 6 GB). Check `docker logs secureship-sonarqube`. |
| `Could not create a Sonar token` | You changed the Sonar admin password manually. Put it in `SONAR_ADMIN_PASSWORD` in `ci/.env` and rerun. |
| JCasC error about `/run/secrets/deploy_key` | The key file must exist: rerun `./ci/bootstrap.sh`. On Linux, check the file is readable by UID 1000. |
| `backend not found at app/backend` | ShopPilot uses different folder names. Set the `BACKEND_SUBDIR` / `FRONTEND_SUBDIR` env vars (see the integration doc). |
| Health check times out on a correct release | First start can be slow (EasyOCR model download). Raise `HEALTH_TIMEOUT` (default 150 s) in Jenkins global env vars. |
| Gate fails on HIGH CVEs in the base image | Expected sometimes. Rebuild to get newer base packages. Otherwise add a **justified, expiring** entry to `security/exceptions.yaml`. |
| `evidence.html` shows no styling in Jenkins | The init script relaxes Jenkins' artifact CSP for inline CSS. Download the file, or restart Jenkins. |
