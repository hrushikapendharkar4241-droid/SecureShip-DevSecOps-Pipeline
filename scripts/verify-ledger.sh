#!/usr/bin/env bash
# Verify the deployment ledger on demand: hash chain + HMAC + every external anchor store.
# Run inside the Jenkins container (where the ledger lives):
#   docker exec -e LEDGER_KEY=... -e SSH_KEY=/run/secrets/deploy_key -w /var/jenkins_home/workspace/SecureShip \
#     secureship-jenkins scripts/verify-ledger.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/anchor-lib.sh
source "$(dirname "$0")/anchor-lib.sh"

LEDGER_PATH="${LEDGER_PATH:-${JENKINS_HOME:-$WORKSPACE}/secureship/ledger.jsonl}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"; rm -rf "${_ANCHOR_GIT_DIR:-}"' EXIT
anchors_fetch "$tmp"
args=()
if [ ${#ANCHOR_SOURCES[@]} -gt 0 ]; then
  log "Anchors from: ${ANCHOR_SOURCES[*]}"
  args=(--anchors "$tmp")
fi
python3 -m secureship ledger verify --ledger "$LEDGER_PATH" "${args[@]}" "$@"
