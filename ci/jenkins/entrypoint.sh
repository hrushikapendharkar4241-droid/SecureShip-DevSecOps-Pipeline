#!/bin/bash
# Give the unprivileged `jenkins` user access to the host Docker socket, then drop root.
set -euo pipefail

SOCK=/var/run/docker.sock
if [ -S "$SOCK" ]; then
  gid="$(stat -c %g "$SOCK")"
  if [ "$gid" = "0" ]; then
    # Docker Desktop exposes the socket as root:root (mode 660)
    usermod -aG root jenkins
  else
    group="$(getent group "$gid" | cut -d: -f1 || true)"
    if [ -z "$group" ]; then
      group=docker-host
      groupadd -g "$gid" "$group"
    fi
    usermod -aG "$group" jenkins
  fi
else
  echo "[secureship] WARNING: $SOCK not mounted – pipeline stages that use Docker will fail" >&2
fi

mkdir -p /var/jenkins_home/secureship
chown jenkins:jenkins /var/jenkins_home /var/jenkins_home/secureship

exec gosu jenkins /usr/bin/tini -- /usr/local/bin/jenkins.sh "$@"
