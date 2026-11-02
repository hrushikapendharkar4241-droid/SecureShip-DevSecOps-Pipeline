#!/usr/bin/env bash
# Shared helpers for SecureShip pipeline scripts. Source it, don't run it.
# shellcheck shell=bash
set -euo pipefail

SECURESHIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$SECURESHIP_ROOT}"
REPORTS_DIR="${REPORTS_DIR:-$WORKSPACE/reports}"
APP_DIR="${APP_DIR:-$WORKSPACE/app}"
BACKEND_SUBDIR="${BACKEND_SUBDIR:-backend}"
FRONTEND_SUBDIR="${FRONTEND_SUBDIR:-frontend}"
IMAGE_PREFIX="${IMAGE_PREFIX:-shoppilot}"
BACKEND_IMAGE="${BACKEND_IMAGE:-$IMAGE_PREFIX-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-$IMAGE_PREFIX-frontend}"
APP_TAG="${APP_TAG:-local-$(date +%Y%m%d%H%M%S)}"
CI_NETWORK="${CI_NETWORK:-secureship-ci}"
BUILD_NUMBER="${BUILD_NUMBER:-local}"
export PYTHONPATH="$SECURESHIP_ROOT${PYTHONPATH:+:$PYTHONPATH}"

mkdir -p "$REPORTS_DIR"

log()  { printf '\033[1;36m[secureship]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[secureship] ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[secureship] !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[secureship] ✘\033[0m %s\n' "$*" >&2; exit 1; }

# write_status <file> <status> <detail> [extra-json-object]
write_status() {
  local file="$1" status="$2" detail="${3:-}" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$(dirname "$file")"
  jq -n --arg s "$status" --arg d "$detail" --argjson x "$extra" \
     '{status: $s, detail: $d, at: (now | todate)} + $x' > "$file"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# docker network to attach helper containers to (falls back to the default bridge)
helper_network() {
  if docker network inspect "$CI_NETWORK" >/dev/null 2>&1; then echo "$CI_NETWORK"; else echo bridge; fi
}

# Tags and hostnames are passed to remote shells – only allow a safe character set
assert_safe() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9._:/@-]+$ ]] || die "unsafe value for $name: '$value'"
}
