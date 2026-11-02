#!/usr/bin/env bash
# Housekeeping on the CI machine: remove test/chaos images and keep the newest N app builds.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
KEEP="${KEEP_LOCAL_BUILDS:-5}"

docker rmi "$BACKEND_IMAGE:$APP_TAG-test" >/dev/null 2>&1 || true
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E -- '-chaos-' | xargs -r docker rmi >/dev/null 2>&1 || true

for repo in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
  docker images "$repo" --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' \
    | grep -v -- '-test$' | sort -r | tail -n +"$((KEEP + 1))" | cut -f2 \
    | xargs -r docker rmi >/dev/null 2>&1 || true
done
docker image prune -f >/dev/null 2>&1 || true
log "Cleanup done (kept newest $KEEP builds)"
