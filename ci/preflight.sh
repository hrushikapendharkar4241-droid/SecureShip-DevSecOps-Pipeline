#!/usr/bin/env bash
# Pre-flight check for the SecureShip lab. Run BEFORE ci/bootstrap.sh (bootstrap runs it too).
# Every check prints PASS / WARN / FAIL with the fix; nothing is changed on your machine.
#
#   ./ci/preflight.sh
#
# Exit code: 0 = ready (warnings allowed), 1 = at least one FAIL.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$CI_DIR/.env"
MIN_DISK_GB="${MIN_DISK_GB:-25}"
MIN_DOCKER_MEM_GB="${MIN_DOCKER_MEM_GB:-7}"
fails=0; warns=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
env_or_default() {  # value from ci/.env, then the environment, then a default
  local v=""
  [ -f "$ENV_FILE" ] && v="$(grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "${v:-$2}"
}

echo
echo " SecureShip pre-flight"
echo " ---------------------"

# 1. tools ---------------------------------------------------------------------------
for c in docker git curl ssh-keygen; do
  if command -v "$c" >/dev/null 2>&1; then pass "$c found"; else fail "$c not found – install it (Git for Windows provides git, curl and ssh-keygen in Git Bash)"; fi
done

# 2. Docker engine -------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
  pass "Docker engine is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  if docker compose version >/dev/null 2>&1; then pass "Docker Compose v2 available"; else fail "Docker Compose v2 missing – update Docker Desktop"; fi
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if [ "$mem_gb" -ge "$MIN_DOCKER_MEM_GB" ]; then
    pass "Docker has ${mem_gb} GB RAM"
  else
    fail "Docker has only ${mem_gb} GB RAM (need ≥ ${MIN_DOCKER_MEM_GB}). Docker Desktop → Settings → Resources (or .wslconfig memory=8GB on WSL2)"
  fi
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  [ "$cpus" -ge 2 ] && pass "Docker has ${cpus} CPUs" || warn "Docker has ${cpus} CPU – builds will be slow"
else
  fail "Docker engine not reachable – start Docker Desktop and wait until it says 'Engine running'"
fi

# 3. disk ----------------------------------------------------------------------------
# Docker Desktop on Windows keeps its data on C:, so check the drive holding your home folder.
avail_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$avail_kb" ]; then
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_gb" -ge "$MIN_DISK_GB" ]; then
    pass "${avail_gb} GB free on the drive with your home folder"
  else
    fail "only ${avail_gb} GB free (need ≈ ${MIN_DISK_GB} GB for Jenkins, SonarQube, the scanner build, ShopPilot images and the Trivy DB). Free space first – see docs/START_HERE.md step 0"
  fi
else
  warn "could not measure free disk space – make sure ≈ ${MIN_DISK_GB} GB are free"
fi

# 4. ports ---------------------------------------------------------------------------
for spec in 8080:Jenkins 9000:SonarQube 8088:"ShopPilot (deployed)" 2222:"lab SSH"; do
  port="${spec%%:*}"; name="${spec#*:}"
  if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "^secureship-.*:$port->"; then
    pass "port $port already used by the SecureShip lab ($name)"
  elif (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    fail "port $port is in use by another program – stop it ($name needs it)"
  else
    pass "port $port free ($name)"
  fi
done

# 5. repositories --------------------------------------------------------------------
ss_repo="$(env_or_default SECURESHIP_REPO_URL "https://github.com/hrushikapendharkar4241-droid/SecureShip-DevSecOps-Pipeline.git")"
ss_branch="$(env_or_default SECURESHIP_BRANCH main)"
app_repo="$(env_or_default APP_REPO_URL "https://github.com/hrushikapendharkar4241-droid/shoppilot.git")"
app_branch="$(env_or_default APP_BRANCH master)"

if git ls-remote --exit-code --heads "$ss_repo" "$ss_branch" >/dev/null 2>&1; then
  pass "SecureShip repo reachable: $ss_repo ($ss_branch)"
else
  fail "SecureShip repo/branch not reachable: $ss_repo ($ss_branch) – push this folder to GitHub first (docs/START_HERE.md step 3)"
fi

if GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote --heads "$app_repo" >/dev/null 2>&1; then
  pass "ShopPilot repo is public – Jenkins needs no token"
elif [ -n "$(env_or_default APP_GIT_TOKEN "")" ]; then
  pass "ShopPilot repo is private – a token is configured in ci/.env for Jenkins"
else
  warn "ShopPilot repo is private (or unreachable without login) – bootstrap.sh will ask for a read-only GitHub token so Jenkins can clone it"
fi

# With a token configured (private repo), clone the way Jenkins will: token in a header, never in the URL
app_token="$(env_or_default APP_GIT_TOKEN "" | LC_ALL=C tr -cd 'A-Za-z0-9_')"
clone_auth=()
if [ -n "$app_token" ]; then
  app_owner="$(printf '%s' "$app_repo" | sed -E 's#https://github.com/([^/]+)/.*#\1#')"
  case "$app_token" in ghs_*) app_owner=x-access-token ;; esac   # GitHub Actions job token
  clone_auth=(-c credential.helper= -c "http.extraHeader=Authorization: Basic $(printf '%s:%s' "$app_owner" "$app_token" | base64 | tr -d '\n')")
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if GIT_TERMINAL_PROMPT=0 git "${clone_auth[@]}" clone -q --depth 1 --branch "$app_branch" "$app_repo" "$tmp/app" 2>/dev/null; then
  pass "ShopPilot repo reachable: $app_repo ($app_branch)"
  # The deploy health check needs GET /health – without it EVERY deployment fails and rolls back
  if grep -rqs --include='*.py' -E '@router\.get\("/health"' "$tmp/app/backend/app" \
     && grep -qs 'health.router' "$tmp/app/backend/app/main.py"; then
    pass "ShopPilot on GitHub has the /health endpoint"
  else
    fail "ShopPilot on GitHub has NO /health endpoint yet – commit and push backend/app/routers/health.py + main.py (docs/START_HERE.md step 2)"
  fi
  if [ -f "$tmp/app/backend/requirements.txt" ] && [ -f "$tmp/app/frontend/package-lock.json" ]; then
    pass "ShopPilot layout matches (backend/requirements.txt, frontend/package-lock.json)"
  else
    fail "ShopPilot layout differs – see docs/SHOPPILOT_INTEGRATION.md"
  fi
else
  if [ -n "$app_token" ]; then
    fail "ShopPilot repo/branch not reachable with the configured token: $app_repo ($app_branch) – check the token (Contents: Read-only on shoppilot)"
  else
    warn "ShopPilot could not be cloned without a token – bootstrap.sh will ask for one; the /health and layout checks run once it is set"
  fi
fi

# 6. line endings (Windows) ------------------------------------------------------------
if grep -q $'\r' "$CI_DIR/bootstrap.sh" "$CI_DIR/jenkins/entrypoint.sh" "$CI_DIR/lab-target/entrypoint.sh" 2>/dev/null; then
  fail "scripts have Windows (CRLF) line endings – run: git config core.autocrlf false && git rm -rq --cached . && git reset --hard"
else
  pass "scripts have Unix line endings"
fi

echo " ---------------------"
if [ "$fails" -gt 0 ]; then
  printf ' \033[31m%d problem(s)\033[0m, %d warning(s) – fix the FAIL lines, then run this again.\n\n' "$fails" "$warns"
  exit 1
fi
printf ' \033[32mReady.\033[0m %d warning(s). Next: ./ci/bootstrap.sh\n\n' "$warns"
