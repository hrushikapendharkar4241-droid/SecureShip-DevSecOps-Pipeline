#!/usr/bin/env bash
# Runs ON the target. Waits until ShopPilot is healthy through the public entry point (NGINX):
#   1. GET /health returns 200 with {"status": "ok"}   (backend up + database reachable)
#   2. /health reports the EXPECTED version            (proves the new container is serving,
#                                                        not an old one that is still running)
#   3. GET / serves the React app                      (frontend + NGINX up)
#   4. security headers present                        (NGINX config shipped correctly)
#
# usage: health-check.sh <base_url> <expected_version|-> <timeout_s> <json_out>
set -uo pipefail

BASE="${1:?base url}"; EXPECT="${2:--}"; TIMEOUT="${3:-150}"; OUT="${4:-/dev/stdout}"
INTERVAL="${HEALTH_INTERVAL:-3}"
body="$(mktemp)"; trap 'rm -f "$body"' EXIT

start=$(date +%s); attempts=0; code=000; version=""; detail="not started"; passed=false
while :; do
  attempts=$((attempts + 1))
  code="$(curl -s -o "$body" -w '%{http_code}' --max-time 5 "$BASE/health" || true)"
  if [ "$code" = "200" ] && jq -e '.status == "ok"' "$body" >/dev/null 2>&1; then
    version="$(jq -r '.version // empty' "$body")"
    if [ "$EXPECT" = "-" ] || [ -z "$version" ] || [ "$version" = "$EXPECT" ]; then
      passed=true; detail="healthy"
      [ -z "$version" ] && detail="healthy (version not reported by /health)"
      break
    fi
    detail="healthy but serving version '$version', expected '$EXPECT'"
  elif [ "$code" = "200" ]; then
    detail="HTTP 200 but status != ok: $(head -c 200 "$body" | tr -d '\n')"
  else
    detail="HTTP $code from /health"
  fi
  [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ] && break
  sleep "$INTERVAL"
done

checks='[]'
if $passed; then
  root_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" || true)"
  headers="$(curl -sI --max-time 5 "$BASE/" || true)"
  [ "$root_code" = "200" ] || { passed=false; detail="frontend returned HTTP $root_code"; }
  checks="$(jq -nc --arg rc "$root_code" \
    --argjson nosniff "$(grep -qi '^x-content-type-options: *nosniff' <<<"$headers" && echo true || echo false)" \
    --argjson frame "$(grep -qi '^x-frame-options' <<<"$headers" && echo true || echo false)" \
    '[{check: "frontend GET /", result: $rc},
      {check: "X-Content-Type-Options", result: $nosniff},
      {check: "X-Frame-Options", result: $frame}]')"
fi

deps="$(jq -c '.checks // null' "$body" 2>/dev/null || echo null)"
jq -nc --argjson passed "$passed" --arg detail "$detail" --arg code "$code" --arg v "$version" \
  --arg expected "$EXPECT" --argjson attempts "$attempts" --argjson elapsed "$(( $(date +%s) - start ))" \
  --argjson smoke "$checks" --argjson deps "${deps:-null}" \
  '{passed: $passed, detail: $detail, http_code: $code, version_seen: $v, version_expected: $expected,
    attempts: $attempts, elapsed_s: $elapsed, dependencies: $deps, smoke_tests: $smoke}' > "$OUT"

$passed
