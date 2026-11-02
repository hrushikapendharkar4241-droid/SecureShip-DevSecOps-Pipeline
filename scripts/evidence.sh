#!/usr/bin/env bash
# Build the deployment evidence report, append the ledger entry, check the ledger
# against its external anchors, then anchor the new entry.
# Runs in the pipeline's post { always } block, so failed and blocked builds get a report too.
#
# Exit codes: 0 ok · 2 ledger integrity problem (chain or anchors) · 3 anchor could not be written
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/anchor-lib.sh
source "$(dirname "$0")/anchor-lib.sh"
require_cmd python3 jq

LEDGER_PATH="${LEDGER_PATH:-${JENKINS_HOME:-$WORKSPACE}/secureship/ledger.jsonl}"
[ -n "${LEDGER_KEY:-}" ] || warn "LEDGER_KEY not set – ledger entry will be hash-chained but not HMAC-signed"

# 1. Fetch the anchors written by earlier builds (detects deleted/rewritten history)
fetched="$REPORTS_DIR/ledger-anchors.fetched.jsonl"
anchors_fetch "$fetched"
anchor_args=()
if [ ${#ANCHOR_SOURCES[@]} -gt 0 ]; then
  anchor_args=(--anchors "$fetched" --anchor-sources "$(IFS=,; echo "${ANCHOR_SOURCES[*]}")")
  log "Checking ledger against $(grep -c . "$fetched" || true) external anchor(s) from: ${ANCHOR_SOURCES[*]}"
else
  warn "no external anchor store reachable – deletion of the newest ledger entries would go undetected"
fi

# 2. Evidence + ledger entry + verification
rc=0
python3 -m secureship report --reports "$REPORTS_DIR" --ledger "$LEDGER_PATH" \
  --result "${PIPELINE_RESULT:-UNKNOWN}" --deploy-enabled "${DEPLOY_ENABLED:-true}" "${anchor_args[@]}" || rc=$?
cp "$LEDGER_PATH" "$REPORTS_DIR/ledger-snapshot.jsonl" 2>/dev/null || true

# 3. Anchor outside Jenkins: this build's entry plus any earlier entry that is not anchored yet
#    (e.g. written while the anchor store was unreachable)
if [ -s "$REPORTS_DIR/ledger-anchor.jsonl" ] && { anchor_ssh_enabled || anchor_git_enabled; }; then
  lines="$(cat "$REPORTS_DIR/ledger-anchor.jsonl")"
  pending="$(jq -r '(.anchor_check.unanchored_entries // [])[]' "$REPORTS_DIR/ledger-verify.json" 2>/dev/null || true)"
  current="$(jq -r .seq "$REPORTS_DIR/ledger-anchor.jsonl")"
  for seq in $pending; do
    [ "$seq" = "$current" ] && continue
    lines="$(python3 -m secureship ledger anchor --ledger "$LEDGER_PATH" --seq "$seq")"$'\n'"$lines"
  done
  if anchors_push "$lines" "$REPORTS_DIR/anchor-status.json"; then
    ok "Ledger entry anchored: $(jq -c 'del(.at)' "$REPORTS_DIR/anchor-status.json")"
  else
    [ "$rc" -eq 0 ] && rc=3
  fi
fi

ok "Evidence written: reports/evidence.html, reports/evidence.json (ledger: $LEDGER_PATH)"
exit $rc
