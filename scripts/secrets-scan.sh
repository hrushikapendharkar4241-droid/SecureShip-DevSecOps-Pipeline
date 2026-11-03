#!/usr/bin/env bash
# Scan the full Git history of the ShopPilot branch being released for hard-coded secrets
# (API keys, tokens, passwords). Scoped to HEAD: Jenkins fetches every branch, and a demo or
# feature branch must not block a release that doesn't contain its commits.
# Findings are recorded, the policy gate decides whether they block the release.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

out="$REPORTS_DIR/gitleaks.json"
if ! command -v gitleaks >/dev/null 2>&1; then
  write_status "$REPORTS_DIR/secrets.status.json" ERROR "gitleaks not installed"
  die "gitleaks is not installed"
fi

log "Gitleaks: scanning all $(git -C "$APP_DIR" rev-list --count HEAD 2>/dev/null || echo '?') commits in the history of the release"
set +e
gitleaks detect --source "$APP_DIR" --log-opts="HEAD" --report-format json --report-path "$out" \
  --redact --no-banner --exit-code 0 --log-level warn
rc=$?
set -e

if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
  write_status "$REPORTS_DIR/secrets.status.json" ERROR "gitleaks exited with $rc"
  die "gitleaks failed (exit $rc)"
fi

count="$(jq 'length' "$out")"
write_status "$REPORTS_DIR/secrets.status.json" OK "$count finding(s)" "{\"findings\": $count}"
if [ "$count" -gt 0 ]; then
  warn "$count potential secret(s) found (values redacted):"
  jq -r '.[] | "   - \(.RuleID) in \(.File):\(.StartLine) (commit \(.Commit[0:8]))"' "$out" >&2
else
  ok "No secrets found"
fi
