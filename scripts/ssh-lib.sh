#!/usr/bin/env bash
# SSH helpers for talking to the deployment target. Source after lib.sh.
# shellcheck shell=bash

DEPLOY_HOST="${DEPLOY_HOST:?DEPLOY_HOST is not set (lab: lab-target, EC2: its public IP/DNS)}"
DEPLOY_USER="${DEPLOY_USER:-${SSH_USER:-deploy}}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/secureship}"
assert_safe DEPLOY_HOST "$DEPLOY_HOST"
assert_safe DEPLOY_USER "$DEPLOY_USER"
assert_safe DEPLOY_DIR "$DEPLOY_DIR"
[[ "$DEPLOY_PORT" =~ ^[0-9]+$ ]] || die "DEPLOY_PORT must be numeric"

KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")" && chmod 700 "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true

SSH_OPTS=(-p "$DEPLOY_PORT" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30
          -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS")
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)

remote() { ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" "$@"; }
