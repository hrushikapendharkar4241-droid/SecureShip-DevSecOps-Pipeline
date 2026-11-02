#!/usr/bin/env bash
# External anchor stores for the deployment ledger. Source after lib.sh.
#
# A hash chain cannot show that its NEWEST entries were deleted, so after every
# ledger entry its (seq, hash, hmac) is appended to stores Jenkins can add to but
# not rewrite:
#   ssh  – $DEPLOY_DIR/anchors/ledger-anchors.jsonl on the deployment server,
#          made append-only with `chattr +a` (even its owner cannot truncate or delete it)
#   git  – ledger-anchors.jsonl in a separate Git repository whose branch forbids
#          force-pushes and deletion (optional: set ANCHOR_GIT_REPO)
# shellcheck shell=bash

ANCHOR_FILE_NAME="ledger-anchors.jsonl"
ANCHOR_GIT_BRANCH="${ANCHOR_GIT_BRANCH:-main}"
ANCHOR_SOURCES=()
_ANCHOR_GIT_DIR=""

anchor_ssh_enabled() { [ -n "${DEPLOY_HOST:-}" ] && [ "${ANCHOR_SSH:-true}" = "true" ]; }
anchor_git_enabled() { [ -n "${ANCHOR_GIT_REPO:-}" ]; }

_git_auth() {  # credentials go in an HTTP header, never in the URL or the logs
  if [ -n "${ANCHOR_GIT_TOKEN:-}" ]; then
    printf '%s\n' -c "http.extraHeader=Authorization: Basic $(printf '%s:%s' "${ANCHOR_GIT_USER:-x-access-token}" "$ANCHOR_GIT_TOKEN" | base64 | tr -d '\n')"
  fi
}

# anchors_fetch <outfile> – collect anchors from every configured store into one file
anchors_fetch() {
  local out="$1" auth=()
  : > "$out"
  if anchor_ssh_enabled; then
    # shellcheck source=scripts/ssh-lib.sh
    source "$SECURESHIP_ROOT/scripts/ssh-lib.sh"
    if remote "cat '$DEPLOY_DIR/anchors/$ANCHOR_FILE_NAME' 2>/dev/null || true" >> "$out"; then
      ANCHOR_SOURCES+=("deploy-server")
    else
      warn "could not read ledger anchors from $DEPLOY_HOST"
    fi
  fi
  if anchor_git_enabled; then
    mapfile -t auth < <(_git_auth)
    _ANCHOR_GIT_DIR="$(mktemp -d)"
    if git "${auth[@]}" clone -q --depth 1 --branch "$ANCHOR_GIT_BRANCH" "$ANCHOR_GIT_REPO" "$_ANCHOR_GIT_DIR" 2>/dev/null; then
      cat "$_ANCHOR_GIT_DIR/$ANCHOR_FILE_NAME" >> "$out" 2>/dev/null || true
      ANCHOR_SOURCES+=("git")
    else
      warn "could not clone anchor repository (branch $ANCHOR_GIT_BRANCH)"
      _ANCHOR_GIT_DIR=""
    fi
  fi
}

# anchors_push <anchor-json-lines> <status-json-out> – append the anchor line(s) everywhere
anchors_push() {
  local line="$1" status_out="$2" ssh_status="disabled" git_status="disabled" append_only="unknown" seq count auth=()
  seq="$(tail -n1 <<<"$line" | jq -r .seq)"
  count="$(grep -c . <<<"$line")"
  if anchor_ssh_enabled; then
    # shellcheck source=scripts/ssh-lib.sh
    source "$SECURESHIP_ROOT/scripts/ssh-lib.sh"
    if remote "mkdir -p '$DEPLOY_DIR/anchors' && cat >> '$DEPLOY_DIR/anchors/$ANCHOR_FILE_NAME'" <<<"$line"; then
      ssh_status="written"
      if remote "lsattr '$DEPLOY_DIR/anchors/$ANCHOR_FILE_NAME' 2>/dev/null" | awk '{print $1}' | grep -q a; then
        append_only="true"
      else
        append_only="false"
        warn "anchor file on $DEPLOY_HOST is NOT append-only (chattr +a unsupported or not set) – see docs/SECURITY_POLICY.md"
      fi
    else
      ssh_status="failed"; warn "failed to write ledger anchor #$seq to $DEPLOY_HOST"
    fi
  fi
  if anchor_git_enabled; then
    if [ -n "$_ANCHOR_GIT_DIR" ] && [ -d "$_ANCHOR_GIT_DIR/.git" ]; then
      mapfile -t auth < <(_git_auth)
      printf '%s\n' "$line" >> "$_ANCHOR_GIT_DIR/$ANCHOR_FILE_NAME"
      if git -C "$_ANCHOR_GIT_DIR" add "$ANCHOR_FILE_NAME" \
         && git -C "$_ANCHOR_GIT_DIR" -c user.name="SecureShip" -c user.email="secureship@users.noreply.github.com" \
              commit -q -m "Anchor ledger entry #$seq (build ${BUILD_NUMBER:-local}, $count line(s))" \
         && git -C "$_ANCHOR_GIT_DIR" "${auth[@]}" push -q origin "HEAD:$ANCHOR_GIT_BRANCH"; then
        git_status="written"
      else
        git_status="failed"; warn "failed to push ledger anchor #$seq to the anchor repository"
      fi
    else
      git_status="failed"
    fi
    rm -rf "$_ANCHOR_GIT_DIR"
  fi
  jq -n --argjson seq "$seq" --argjson count "$count" --arg ssh "$ssh_status" --arg git "$git_status" --arg ao "$append_only" \
     '{seq: $seq, anchors_written: $count, deploy_server: $ssh, deploy_server_append_only: $ao, git: $git, at: (now | todate)}' > "$status_out"
  [ "$ssh_status" != "failed" ] && [ "$git_status" != "failed" ]
}
