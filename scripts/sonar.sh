#!/usr/bin/env bash
# SonarQube static analysis + quality gate. Writes reports/sonar.json for the policy gate.
# Source code is copied into a scanner container (docker cp) so this works the same whether
# Jenkins runs on the host or inside a container that talks to the host Docker engine.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq curl

SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}"
SONAR_PUBLIC_URL="${SONAR_PUBLIC_URL:-$SONAR_HOST_URL}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-shoppilot}"
SONAR_SCANNER_IMAGE="${SONAR_SCANNER_IMAGE:-sonarsource/sonar-scanner-cli:latest}"
OUT="$REPORTS_DIR/sonar.json"

if [ -z "${SONAR_TOKEN:-}" ]; then
  write_status "$OUT" SKIPPED "SONAR_TOKEN not configured"
  warn "SonarQube skipped: no token (the policy gate will treat this as a failure)"; exit 0
fi
if [ "$(curl -fsS "$SONAR_HOST_URL/api/system/status" 2>/dev/null | jq -r '.status' 2>/dev/null)" != "UP" ]; then
  write_status "$OUT" ERROR "SonarQube at $SONAR_HOST_URL is not reachable/UP"
  warn "SonarQube not reachable at $SONAR_HOST_URL"; exit 0
fi

TEST_PATTERNS='**/tests/**,**/test/**,**/test_*.py,**/*_test.py,**/*.test.js,**/*.test.jsx,**/*.test.ts,**/*.test.tsx,**/*.spec.js,**/*.spec.ts'
EXCLUDES="**/scanner_test_images/**,**/test_notes/**,**/node_modules/**,**/dist/**,**/build/**,**/migrations/**,**/alembic/versions/**,**/*.min.js,**/__pycache__/**,**/.secureship-coverage.xml,**/static/vendor/**"

cid="secureship-sonar-${BUILD_NUMBER}-$$"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

log "SonarQube analysis of ShopPilot ($SONAR_PROJECT_KEY, version $APP_TAG)"
docker create --name "$cid" --network "$(helper_network)" \
  -e SONAR_HOST_URL="$SONAR_HOST_URL" -e SONAR_TOKEN="$SONAR_TOKEN" -e SONAR_USER_HOME=/tmp/.sonar \
  "$SONAR_SCANNER_IMAGE" \
  -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
  -Dsonar.projectName="ShopPilot" \
  -Dsonar.projectVersion="$APP_TAG" \
  -Dsonar.projectBaseDir=/usr/src \
  -Dsonar.working.directory=/tmp/scannerwork \
  -Dsonar.sources=. \
  -Dsonar.tests=. \
  -Dsonar.test.inclusions="$TEST_PATTERNS" \
  -Dsonar.exclusions="$EXCLUDES,$TEST_PATTERNS" \
  -Dsonar.python.coverage.reportPaths=/usr/src/.secureship-coverage.xml \
  -Dsonar.python.version=3.12 \
  -Dsonar.qualitygate.wait=true \
  -Dsonar.qualitygate.timeout=300 >/dev/null

docker cp "$APP_DIR/." "$cid:/usr/src/"
if [ -f "$REPORTS_DIR/tests/coverage.xml" ]; then
  # Coverage was measured at /srv/app inside the test image; point it at the backend sources.
  sed "s#<source>/srv/app</source>#<source>/usr/src/$BACKEND_SUBDIR</source>#" \
    "$REPORTS_DIR/tests/coverage.xml" > "$REPORTS_DIR/tests/coverage.sonar.xml"
  docker cp "$REPORTS_DIR/tests/coverage.sonar.xml" "$cid:/usr/src/.secureship-coverage.xml"
fi

set +e
docker start -a "$cid"
scanner_rc=$?
set -e
docker cp "$cid:/tmp/scannerwork/report-task.txt" "$REPORTS_DIR/sonar-report-task.txt" >/dev/null 2>&1 || true

task_id="$(sed -n 's/^ceTaskId=//p' "$REPORTS_DIR/sonar-report-task.txt" 2>/dev/null || true)"
if [ -z "$task_id" ]; then
  write_status "$OUT" ERROR "scanner failed before submitting an analysis (exit $scanner_rc)"
  warn "Sonar scanner failed (exit $scanner_rc)"; exit 0
fi

api() { curl -fsS -u "$SONAR_TOKEN:" "$SONAR_HOST_URL$1"; }
analysis_id=""
for _ in $(seq 1 60); do
  task="$(api "/api/ce/task?id=$task_id")"
  case "$(jq -r '.task.status' <<<"$task")" in
    SUCCESS) analysis_id="$(jq -r '.task.analysisId' <<<"$task")"; break ;;
    FAILED|CANCELED) break ;;
  esac
  sleep 5
done
if [ -z "$analysis_id" ]; then
  write_status "$OUT" ERROR "analysis task $task_id did not complete"
  warn "SonarQube background task did not complete"; exit 0
fi

gate="$(api "/api/qualitygates/project_status?analysisId=$analysis_id")"
status="$(jq -r '.projectStatus.status' <<<"$gate")"
jq --arg url "$SONAR_PUBLIC_URL/dashboard?id=$SONAR_PROJECT_KEY" --arg aid "$analysis_id" --argjson rc "$scanner_rc" \
   '{status: .projectStatus.status, conditions: (.projectStatus.conditions // []),
     dashboard_url: $url, analysis_id: $aid, scanner_exit: $rc, at: (now | todate)}' <<<"$gate" > "$OUT"

if [ "$status" = "OK" ]; then ok "SonarQube quality gate: OK"; else warn "SonarQube quality gate: $status"; fi
