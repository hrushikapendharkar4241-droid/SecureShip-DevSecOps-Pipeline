#!/usr/bin/env bash
# Dynamic application security testing: OWASP ZAP baseline (passive) scan of the LIVE app.
# Static scans (Sonar, Trivy) look at code and packages; ZAP looks at what an attacker sees:
# missing headers, cookie flags, information leaks, etc. Report-only by default.
# Exit 1 when HIGH-risk alerts are found (Jenkins marks the build UNSTABLE).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq

TARGET="${APP_PUBLIC_URL:?APP_PUBLIC_URL not set (lab: http://lab-target:8080)}"
[[ "$TARGET" =~ ^https?://[A-Za-z0-9.:_/-]+$ ]] || die "unsafe APP_PUBLIC_URL: $TARGET"
ZAP_IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
OUT="$REPORTS_DIR/dast"
mkdir -p "$OUT"
cid="secureship-zap-${BUILD_NUMBER}-$$"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

log "OWASP ZAP baseline scan of $TARGET (passive, ~2 minutes)"
docker create --name "$cid" --network "$(helper_network)" --user root "$ZAP_IMAGE" \
  sh -c "mkdir -p /zap/wrk && chown zap /zap/wrk && \
         su zap -c 'zap-baseline.py -t $TARGET -m 2 -I -J zap.json -r zap.html -w zap.md'" >/dev/null
set +e
docker start -a "$cid"
rc=$?
set -e
docker cp "$cid:/zap/wrk/." "$OUT/" >/dev/null 2>&1 || true

if [ ! -s "$OUT/zap.json" ]; then
  write_status "$OUT/dast.status.json" ERROR "ZAP produced no report (exit $rc)" "{\"target\": \"$TARGET\"}"
  warn "ZAP scan failed (exit $rc)"; exit 0
fi
high="$(jq '[.site[]?.alerts[]? | select(.riskcode == "3")] | length' "$OUT/zap.json")"
medium="$(jq '[.site[]?.alerts[]? | select(.riskcode == "2")] | length' "$OUT/zap.json")"
write_status "$OUT/dast.status.json" OK "high=$high medium=$medium" \
  "{\"target\": \"$TARGET\", \"high\": $high, \"medium\": $medium, \"zap_exit\": $rc}"
jq -r '.site[]?.alerts[]? | "   [\(.riskdesc)] \(.name // .alert)"' "$OUT/zap.json" | sort -u | head -20

if [ "$high" -gt 0 ]; then warn "$high HIGH-risk DAST alert(s)"; exit 1; fi
ok "DAST complete: no high-risk alerts ($medium medium)"
