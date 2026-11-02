#!/usr/bin/env bash
# Build versioned, labelled images for ShopPilot (backend runtime + test target, frontend).
# Tag = <build number>-<commit> so every image traces back to exact source and pipeline run.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq

cd "$WORKSPACE"
[ -d "$APP_DIR/$BACKEND_SUBDIR" ]  || die "backend not found at app/$BACKEND_SUBDIR (set BACKEND_SUBDIR)"
[ -d "$APP_DIR/$FRONTEND_SUBDIR" ] || die "frontend not found at app/$FRONTEND_SUBDIR (set FRONTEND_SUBDIR)"
[ -f "$APP_DIR/$BACKEND_SUBDIR/requirements.txt" ] || die "app/$BACKEND_SUBDIR/requirements.txt not found"

export DOCKER_BUILDKIT=1
labels=(
  --label "org.opencontainers.image.title=ShopPilot"
  --label "org.opencontainers.image.revision=${APP_COMMIT:-unknown}"
  --label "org.opencontainers.image.version=$APP_TAG"
  --label "org.opencontainers.image.source=${APP_REPO:-}"
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  --label "io.secureship.build=$BUILD_NUMBER"
)

start=$(date +%s)
log "Building backend runtime image $BACKEND_IMAGE:$APP_TAG"
docker build -f docker/Dockerfile.backend --target runtime \
  --build-arg BACKEND_DIR="app/$BACKEND_SUBDIR" --build-arg APP_VERSION="$APP_TAG" \
  ${PYTHON_VERSION:+--build-arg PYTHON_VERSION="$PYTHON_VERSION"} \
  "${labels[@]}" -t "$BACKEND_IMAGE:$APP_TAG" .

# Smoke test the runtime image offline: native libraries (PyTorch, OpenCV, EasyOCR,
# psycopg2) must load and the PDF font must exist. Catches a missing system package
# here instead of as a broken scanner in production.
log "Smoke test: native libraries and fonts inside the runtime image"
docker run --rm --network none --entrypoint python "$BACKEND_IMAGE:$APP_TAG" -c '
import importlib.util, os, sys
mods = [m for m in ("torch", "cv2", "easyocr", "psycopg2", "reportlab") if importlib.util.find_spec(m)]
for m in mods:
    __import__(m)
font = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
if not os.path.exists(font):
    sys.exit("missing PDF font " + font)
print("   imports ok:", ", ".join(mods), "| font ok")
' || die "runtime image failed the smoke test (see the error above)"

log "Building backend test image (same layers + pytest)"
docker build -f docker/Dockerfile.backend --target test \
  --build-arg BACKEND_DIR="app/$BACKEND_SUBDIR" --build-arg APP_VERSION="$APP_TAG" \
  ${PYTHON_VERSION:+--build-arg PYTHON_VERSION="$PYTHON_VERSION"} \
  -t "$BACKEND_IMAGE:$APP_TAG-test" .

log "Building frontend image $FRONTEND_IMAGE:$APP_TAG"
docker build -f docker/Dockerfile.frontend \
  --build-arg FRONTEND_DIR="app/$FRONTEND_SUBDIR" \
  --build-arg BUILD_DIR="${FRONTEND_BUILD_DIR:-dist}" \
  --build-arg API_URL="${FRONTEND_API_URL:-/api}" \
  "${labels[@]}" -t "$FRONTEND_IMAGE:$APP_TAG" .

# Image metadata for the hardening checks (user, size, immutable image ID)
meta() {
  local img="$1"
  docker image inspect "$img" | jq --arg img "$img" '.[0] | {
      image: $img, id: .Id, user: (.Config.User // ""),
      size_mb: ((.Size / 1048576) | floor), created: .Created,
      revision: (.Config.Labels["org.opencontainers.image.revision"] // "")}'
}
jq -n --argjson b "$(meta "$BACKEND_IMAGE:$APP_TAG")" --argjson f "$(meta "$FRONTEND_IMAGE:$APP_TAG")" \
   '{backend: $b, frontend: $f}' > "$REPORTS_DIR/image-meta.json"

write_status "$REPORTS_DIR/build.status.json" OK "built in $(( $(date +%s) - start ))s" \
  "{\"backend\": \"$BACKEND_IMAGE:$APP_TAG\", \"frontend\": \"$FRONTEND_IMAGE:$APP_TAG\"}"
ok "Images built: $(jq -r '"backend \(.backend.size_mb) MB (user \(.backend.user)), frontend \(.frontend.size_mb) MB (user \(.frontend.user))"' "$REPORTS_DIR/image-meta.json")"
