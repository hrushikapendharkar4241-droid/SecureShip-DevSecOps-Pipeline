#!/usr/bin/env bash
# Ship the gate-approved images to the target over SSH and run a self-healing release:
#   record current version → DB backup → start new version → health check →
#   keep it, or automatically roll back to the previous version.
#
# Exit codes: 0 deployed & healthy · 2 failed health check, rolled back · 3 failed, could not recover
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/ssh-lib.sh
source "$(dirname "$0")/ssh-lib.sh"
require_cmd docker ssh jq gzip tar

CHAOS_MODE="${CHAOS_MODE:-none}"
BACKEND_TAG="$APP_TAG"
FRONTEND_TAG="$APP_TAG"

# ---------------------------------------------------------------- chaos (demo only)
# Derive a broken image from the real one so the rollback path can be demonstrated
# on demand without touching ShopPilot's code.
if [ "$CHAOS_MODE" != "none" ]; then
  case "$CHAOS_MODE" in
    crash)     cmd='["python","-c","import sys; print(\"[chaos] simulated start-up crash\"); sys.exit(1)"]' ;;
    unhealthy) cmd='["python","-m","http.server","8000"]' ;;   # process runs, but /health answers 404
    *) die "unknown CHAOS_MODE '$CHAOS_MODE'" ;;
  esac
  BACKEND_TAG="$APP_TAG-chaos-$CHAOS_MODE"
  warn "CHAOS MODE '$CHAOS_MODE': deploying deliberately broken backend $BACKEND_IMAGE:$BACKEND_TAG"
  printf 'FROM %s\nLABEL io.secureship.chaos="%s"\nCMD %s\n' "$BACKEND_IMAGE:$APP_TAG" "$CHAOS_MODE" "$cmd" \
    | docker build -q -t "$BACKEND_IMAGE:$BACKEND_TAG" - >/dev/null
fi
assert_safe BACKEND_TAG "$BACKEND_TAG"; assert_safe FRONTEND_TAG "$FRONTEND_TAG"
assert_safe BACKEND_IMAGE "$BACKEND_IMAGE"; assert_safe FRONTEND_IMAGE "$FRONTEND_IMAGE"

log "Target: $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PORT ($DEPLOY_DIR)"
remote "docker version --format 'target docker {{.Server.Version}}' && test -f '$DEPLOY_DIR/.env'" \
  || die "target not ready: SSH failed, Docker missing, or $DEPLOY_DIR/.env does not exist (see target/setup-target.sh)"

# ---------------------------------------------------------------- release files
log "Uploading compose file and release scripts"
tar -C "$WORKSPACE" -czf - docker/docker-compose.yml scripts/remote \
  | remote "mkdir -p '$DEPLOY_DIR' && tar -C '$DEPLOY_DIR' -xzf - && chmod +x '$DEPLOY_DIR'/scripts/remote/*.sh"

# ---------------------------------------------------------------- images
# No registry needed: images are streamed over the SSH connection (docker save | docker load).
to_send=()
for img in "$BACKEND_IMAGE:$BACKEND_TAG" "$FRONTEND_IMAGE:$FRONTEND_TAG"; do
  local_id="$(docker image inspect -f '{{.Id}}' "$img")"
  remote_id="$(remote "docker image inspect -f '{{.Id}}' '$img' 2>/dev/null" || true)"
  if [ "$local_id" = "$remote_id" ]; then log "target already has $img"; else to_send+=("$img"); fi
done
if [ ${#to_send[@]} -gt 0 ]; then
  log "Transferring ${to_send[*]} (compressed)"
  start=$(date +%s)
  docker save "${to_send[@]}" | gzip -1 | remote "gunzip | docker load -q"
  ok "Images transferred in $(( $(date +%s) - start ))s"
fi

# ---------------------------------------------------------------- release
log "Starting release on target"
set +e
remote "BACKEND_IMAGE='$BACKEND_IMAGE' FRONTEND_IMAGE='$FRONTEND_IMAGE' \
        HEALTH_TIMEOUT='${HEALTH_TIMEOUT:-150}' BUILD_NUMBER='$BUILD_NUMBER' \
        bash '$DEPLOY_DIR/scripts/remote/release.sh' deploy '$BACKEND_TAG' '$FRONTEND_TAG'" \
  2>&1 | tee "$REPORTS_DIR/deploy.log"
rc=${PIPESTATUS[0]}
set -e

result="$(grep '^SECURESHIP_RESULT ' "$REPORTS_DIR/deploy.log" | tail -1 | cut -d' ' -f2- || true)"
if [ -n "$result" ] && jq -e . >/dev/null 2>&1 <<<"$result"; then
  jq --arg chaos "$CHAOS_MODE" --arg host "$DEPLOY_HOST" '. + {chaos_mode: $chaos, host: $host}' \
     <<<"$result" > "$REPORTS_DIR/deploy.json"
else
  jq -n --arg host "$DEPLOY_HOST" --arg chaos "$CHAOS_MODE" --argjson rc "$rc" \
     '{status: "FAILED", host: $host, chaos_mode: $chaos, detail: "no result reported by target (exit \($rc))"}' \
     > "$REPORTS_DIR/deploy.json"
  [ "$rc" -eq 0 ] && rc=3
fi

case "$(jq -r .status "$REPORTS_DIR/deploy.json")" in
  DEPLOYED)    ok "ShopPilot $APP_TAG is live and healthy on $DEPLOY_HOST" ;;
  ROLLED_BACK) warn "Release $BACKEND_TAG failed its health check – previous version restored" ;;
  *)           warn "Deployment failed: $(jq -r '.detail // .status' "$REPORTS_DIR/deploy.json")" ;;
esac
exit "$rc"
