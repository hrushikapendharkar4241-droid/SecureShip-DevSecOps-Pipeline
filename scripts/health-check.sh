#!/usr/bin/env bash
# On-demand health check of the deployed ShopPilot (runs the same check the deploy uses).
#   DEPLOY_HOST=lab-target SSH_KEY=ci/keys/deploy_ed25519 scripts/health-check.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/ssh-lib.sh
source "$(dirname "$0")/ssh-lib.sh"

expected="${1:--}"
assert_safe expected "$expected"
out="$REPORTS_DIR/health.json"
if remote "port=\$(grep -E '^PUBLIC_PORT=' '$DEPLOY_DIR/.env' | cut -d= -f2); \
           bash '$DEPLOY_DIR/scripts/remote/health-check.sh' \"http://127.0.0.1:\${port:-8080}\" '$expected' '${HEALTH_TIMEOUT:-30}' /dev/stdout" > "$out"; then
  ok "ShopPilot is healthy: $(jq -c '{version_seen, elapsed_s, dependencies}' "$out")"
else
  jq . "$out" 2>/dev/null || true
  die "ShopPilot is NOT healthy"
fi
