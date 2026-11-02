#!/usr/bin/env bash
# Policy gate: combine all evidence into one PASS/FAIL release decision.
# Exit 0 = cleared for deployment, 1 = blocked.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd python3

python3 -m secureship gate \
  --reports "$REPORTS_DIR" \
  --policy "${SECURESHIP_POLICY:-$SECURESHIP_ROOT/security/policy.yaml}" \
  --exceptions "${SECURESHIP_EXCEPTIONS:-$SECURESHIP_ROOT/security/exceptions.yaml}"
