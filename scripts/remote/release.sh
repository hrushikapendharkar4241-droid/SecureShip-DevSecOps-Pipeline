#!/usr/bin/env bash
# Runs ON the deployment target. Self-healing release controller for ShopPilot.
#
#   release.sh deploy <backend_tag> <frontend_tag>   deploy, verify, auto-rollback on failure
#   release.sh rollback                              manually return to the previous release
#   release.sh status                                show current / previous release + history
#
# State lives in $DEPLOY_DIR/state:  current, previous (each "<backend_tag> <frontend_tag>"),
# history.log (one line per release attempt). The last line printed by `deploy` is
#   SECURESHIP_RESULT {json}
# which the pipeline turns into reports/deploy.json.
#
# Exit codes: 0 success · 2 new release failed, rolled back · 3 failed and could not recover
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker/docker-compose.yml}"
ENV_FILE="$DEPLOY_DIR/.env"
STATE="$DEPLOY_DIR/state"
BACKUPS="$DEPLOY_DIR/backups"
HEALTH="$(dirname "$0")/health-check.sh"
BACKEND_IMAGE="${BACKEND_IMAGE:-shoppilot-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-shoppilot-frontend}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-150}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
PROJECT="${COMPOSE_PROJECT:-shoppilot}"

mkdir -p "$STATE" "$BACKUPS"
chmod 700 "$BACKUPS"

log()  { printf '[target %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
env_value() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

PUBLIC_PORT="$(env_value PUBLIC_PORT)"; PUBLIC_PORT="${PUBLIC_PORT:-8080}"
BASE_URL="${BASE_URL:-http://127.0.0.1:$PUBLIC_PORT}"

compose() {  # compose <backend_tag> <frontend_tag> <compose args...>
  local b="$1" f="$2"; shift 2
  BACKEND_IMAGE="$BACKEND_IMAGE" FRONTEND_IMAGE="$FRONTEND_IMAGE" BACKEND_TAG="$b" FRONTEND_TAG="$f" \
    docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

release_json() {  # release_json "<b> <f>"  -> {"backend":..,"frontend":..} or null
  local b f; read -r b f <<<"${1:-}"
  if [ -z "${b:-}" ]; then echo null; else jq -nc --arg b "$b" --arg f "$f" '{backend: $b, frontend: $f}'; fi
}

health_check() {  # health_check <expected_backend_tag> <outfile>
  bash "$HEALTH" "$BASE_URL" "$1" "$HEALTH_TIMEOUT" "$2"
}

backup_db() {  # backup_db <label> -> prints JSON
  local db_id file
  db_id="$(compose x x ps -q db 2>/dev/null || true)"
  if [ -z "$db_id" ]; then echo '{"skipped": "database not running yet (first deployment)"}'; return 0; fi
  file="$BACKUPS/pre-$1-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
  log "Backing up database before release → $file"
  if compose x x exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' | gzip > "$file" \
     && [ "$(gzip -dc "$file" | head -c 1 | wc -c)" -gt 0 ]; then
    chmod 600 "$file"
    # keep only the newest $KEEP_BACKUPS backups
    find "$BACKUPS" -name 'pre-*.sql.gz' -type f | sort | head -n -"$KEEP_BACKUPS" | xargs -r rm -f
    jq -nc --arg f "$file" --arg s "$(du -h "$file" | cut -f1)" '{file: $f, size: $s}'
  else
    rm -f "$file"
    return 1
  fi
}

prune_images() {  # keep only images used by current + previous release
  local keep=() line img
  for line in "$(cat "$STATE/current" 2>/dev/null || true)" "$(cat "$STATE/previous" 2>/dev/null || true)"; do
    [ -n "$line" ] || continue
    read -r b f <<<"$line"; keep+=("$BACKEND_IMAGE:$b" "$FRONTEND_IMAGE:$f")
  done
  { docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^($BACKEND_IMAGE|$FRONTEND_IMAGE):" || true; } \
    | while read -r img; do
      printf '%s\n' "${keep[@]}" | grep -qxF "$img" || docker rmi "$img" >/dev/null 2>&1 || true
    done
  return 0
}

finish() {  # finish <status> <exit> <detail> <health_json> <rollback_json> <backup_json>
  local status="$1" code="$2" detail="$3"
  printf '%s %s build=%s new="%s %s" prev="%s"\n' "$(now)" "$status" "${BUILD_NUMBER:-?}" \
    "$NEW_B" "$NEW_F" "$PREV" >> "$STATE/history.log"
  echo "SECURESHIP_RESULT $(jq -nc \
    --arg status "$status" --arg detail "$detail" \
    --argjson new "$(release_json "$NEW_B $NEW_F")" --argjson prev "$(release_json "$PREV")" \
    --argjson health "${4:-null}" --argjson rollback "${5:-null}" --argjson backup "${6:-null}" \
    --arg started "$STARTED" --arg finished "$(now)" --argjson dur "$(( $(date +%s) - START_S ))" \
    '{status: $status, detail: $detail, new_release: $new, previous_release: $prev, health: $health,
      rollback: $rollback, backup: $backup, started_at: $started, finished_at: $finished, duration_s: $dur}')"
  exit "$code"
}

cmd_deploy() {
  NEW_B="${1:?backend tag required}"; NEW_F="${2:?frontend tag required}"
  STARTED="$(now)"; START_S=$(date +%s)
  PREV="$(cat "$STATE/current" 2>/dev/null || true)"
  [ -f "$ENV_FILE" ] || finish FAILED 3 "missing $ENV_FILE on target"

  log "Current release : ${PREV:-<none – first deployment>}"
  log "New release     : $NEW_B $NEW_F"

  # 1. Safety net for data: refuse to deploy if the backup fails
  local backup
  if ! backup="$(backup_db "$NEW_B")"; then
    finish FAILED 3 "pre-deployment database backup failed – release aborted, nothing changed"
  fi

  # 2. Roll out the new version (database container is left untouched)
  log "Starting new version"
  if ! compose "$NEW_B" "$NEW_F" up -d --remove-orphans >&2; then
    log "docker compose up failed"
  fi

  # 3. Prove it is healthy AND that the new version is the one answering
  local h_new; h_new="$(mktemp)"
  if health_check "$NEW_B" "$h_new"; then
    if [ -n "$PREV" ]; then printf '%s\n' "$PREV" > "$STATE/previous"; fi
    printf '%s %s\n' "$NEW_B" "$NEW_F" > "$STATE/current"
    prune_images
    log "Release $NEW_B is healthy – done"
    finish DEPLOYED 0 "healthy" "$(cat "$h_new")" '{"performed": false}' "$backup"
  fi

  log "HEALTH CHECK FAILED for $NEW_B – collecting logs"
  compose "$NEW_B" "$NEW_F" logs --no-color --tail 60 backend frontend > "$STATE/failed-$NEW_B.log" 2>&1 || true
  tail -n 25 "$STATE/failed-$NEW_B.log" >&2 || true

  # 4. Automatic rollback
  if [ -z "$PREV" ]; then
    log "No previous release to restore – stopping the broken application containers"
    compose "$NEW_B" "$NEW_F" stop backend frontend >&2 || true
    finish FAILED 3 "first deployment failed its health check; nothing to roll back to" "$(cat "$h_new")" \
      '{"performed": false, "reason": "no previous release"}' "$backup"
  fi

  local pb pf h_old; read -r pb pf <<<"$PREV"; h_old="$(mktemp)"
  log "ROLLING BACK to $pb $pf"
  compose "$pb" "$pf" up -d --remove-orphans >&2 || true
  if health_check "$pb" "$h_old"; then
    finish ROLLED_BACK 2 "new release unhealthy; previous release restored and verified" "$(cat "$h_new")" \
      "$(jq -nc --argjson r "$(release_json "$PREV")" --argjson h "$(cat "$h_old")" \
         '{performed: true, success: true, restored_release: $r, health_after_rollback: $h}')" "$backup"
  fi
  finish ROLLBACK_FAILED 3 "new release unhealthy AND previous release failed to recover – manual action required" \
    "$(cat "$h_new")" "$(jq -nc --argjson r "$(release_json "$PREV")" --argjson h "$(cat "$h_old")" \
       '{performed: true, success: false, restored_release: $r, health_after_rollback: $h}')" "$backup"
}

cmd_rollback() {
  local cur prev b f h
  cur="$(cat "$STATE/current" 2>/dev/null || true)"; prev="$(cat "$STATE/previous" 2>/dev/null || true)"
  [ -n "$prev" ] || { log "no previous release recorded"; exit 3; }
  read -r b f <<<"$prev"
  log "Manual rollback: $cur → $prev"
  compose "$b" "$f" up -d --remove-orphans >&2
  h="$(mktemp)"
  if health_check "$b" "$h"; then
    printf '%s\n' "$prev" > "$STATE/current"; printf '%s\n' "$cur" > "$STATE/previous"
    printf '%s MANUAL_ROLLBACK to="%s" from="%s"\n' "$(now)" "$prev" "$cur" >> "$STATE/history.log"
    log "Rollback complete and healthy"
  else
    log "Rolled-back release is NOT healthy – investigate: docker compose -p $PROJECT logs"
    exit 3
  fi
}

cmd_status() {
  echo "current : $(cat "$STATE/current" 2>/dev/null || echo none)"
  echo "previous: $(cat "$STATE/previous" 2>/dev/null || echo none)"
  echo "history :"; tail -n 10 "$STATE/history.log" 2>/dev/null | sed 's/^/  /' || true
}

case "${1:-}" in
  deploy)   shift; cmd_deploy "$@" ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  *) echo "usage: $0 deploy <backend_tag> <frontend_tag> | rollback | status" >&2; exit 64 ;;
esac
