#!/usr/bin/env bash
# Trivy: vulnerability scan of both images (JSON for the gate), CycloneDX SBOMs,
# and a misconfiguration scan of the Dockerfiles (infrastructure-as-code checks).
# Trivy itself never fails the build here – the policy gate owns that decision.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd trivy jq

export TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}"
errors=0

log "Trivy $(trivy --version 2>/dev/null | head -1 | awk '{print $2}') – updating vulnerability DB"
# Record which scanner build produced these results (module hashes from Go's checksum DB)
if [ -d /usr/local/share/secureship/provenance ]; then
  mkdir -p "$REPORTS_DIR/tool-provenance" && cp /usr/local/share/secureship/provenance/* "$REPORTS_DIR/tool-provenance/" 2>/dev/null || true
fi
trivy image --download-db-only --quiet || warn "DB update failed, using cached DB if present"

for role in backend frontend; do
  if [ "$role" = backend ]; then img="$BACKEND_IMAGE:$APP_TAG"; else img="$FRONTEND_IMAGE:$APP_TAG"; fi
  log "Scanning $img"
  if trivy image --quiet --skip-db-update --scanners vuln --format json \
       --output "$REPORTS_DIR/trivy-$role.json" "$img"; then
    trivy convert --format table --severity CRITICAL,HIGH "$REPORTS_DIR/trivy-$role.json" || true
    jq -r --arg r "$role" '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity)
        | map("\(.[0].Severity)=\(length)") | "   \($r): " + (if length == 0 then "no vulnerabilities" else join(" ") end)' \
        "$REPORTS_DIR/trivy-$role.json"
  else
    warn "Trivy scan of $img failed"; errors=$((errors + 1))
    rm -f "$REPORTS_DIR/trivy-$role.json"
  fi
  trivy image --quiet --skip-db-update --format cyclonedx \
    --output "$REPORTS_DIR/sbom-$role.cdx.json" "$img" || warn "SBOM generation failed for $role"
done

log "Scanning Dockerfiles for misconfigurations"
if ! trivy config --quiet --format json --output "$REPORTS_DIR/trivy-config.json" "$WORKSPACE/docker"; then
  warn "Trivy config scan failed"; errors=$((errors + 1)); rm -f "$REPORTS_DIR/trivy-config.json"
fi

if [ $errors -eq 0 ]; then
  write_status "$REPORTS_DIR/scan.status.json" OK "images + Dockerfiles scanned, SBOMs generated"
  ok "Scans complete (reports/trivy-*.json, reports/sbom-*.cdx.json)"
else
  write_status "$REPORTS_DIR/scan.status.json" ERROR "$errors scan(s) failed"
  die "$errors scan(s) failed – missing reports will fail the gate"
fi
