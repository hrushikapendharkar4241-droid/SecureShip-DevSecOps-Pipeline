#!/usr/bin/env bash
# Record build provenance (who/what/when) for the evidence report.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd git jq

commit="${APP_COMMIT:-$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
jq -n \
  --arg build_number "$BUILD_NUMBER" \
  --arg build_url "${BUILD_URL:-}" \
  --arg job_name "${JOB_NAME:-local}" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_repo "${APP_REPO:-$(git -C "$APP_DIR" config --get remote.origin.url 2>/dev/null || echo '')}" \
  --arg app_branch "${APP_BRANCH:-$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}" \
  --arg app_commit "$commit" \
  --arg app_tag "$APP_TAG" \
  --arg commit_message "$(git -C "$APP_DIR" log -1 --pretty=%s 2>/dev/null || echo '')" \
  --arg commit_author "$(git -C "$APP_DIR" log -1 --pretty='%an' 2>/dev/null || echo '')" \
  --arg pipeline_commit "$(git -C "$WORKSPACE" rev-parse --short=12 HEAD 2>/dev/null || echo '')" \
  --arg triggered_by "${BUILD_CAUSE:-${TRIGGERED_BY:-jenkins}}" \
  --arg chaos_mode "${CHAOS_MODE:-none}" \
  --arg deploy_host "${DEPLOY_HOST:-}" \
  '$ARGS.named' > "$REPORTS_DIR/build.json"

ok "Build $BUILD_NUMBER · ShopPilot ${commit:0:12} · image tag $APP_TAG"
