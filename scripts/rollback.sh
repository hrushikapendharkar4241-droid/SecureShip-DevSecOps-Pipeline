#!/usr/bin/env bash
# Manual rollback: switch the target back to the previously deployed release and verify it.
# (Automatic rollback happens inside deploy.sh when a new release fails its health check.)
#   DEPLOY_HOST=lab-target SSH_KEY=ci/keys/deploy_ed25519 scripts/rollback.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/ssh-lib.sh
source "$(dirname "$0")/ssh-lib.sh"

log "Release state before rollback:"
remote "bash '$DEPLOY_DIR/scripts/remote/release.sh' status"
remote "BACKEND_IMAGE='$BACKEND_IMAGE' FRONTEND_IMAGE='$FRONTEND_IMAGE' bash '$DEPLOY_DIR/scripts/remote/release.sh' rollback"
ok "Rollback finished"
remote "bash '$DEPLOY_DIR/scripts/remote/release.sh' status"
