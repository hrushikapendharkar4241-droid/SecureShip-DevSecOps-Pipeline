#!/bin/sh
set -e

ssh-keygen -A >/dev/null

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
if [ -f /run/secrets/authorized_keys ]; then
  install -m 600 -o deploy -g deploy /run/secrets/authorized_keys /home/deploy/.ssh/authorized_keys
else
  echo "[lab-target] WARNING: no authorized_keys mounted – run ci/bootstrap.sh" >&2
fi

install -d -o deploy -g deploy /opt/secureship

# External anchor store for the deployment ledger: the deploy user may APPEND but never
# truncate or delete (chattr +a; only root can lift it). Needs a filesystem that supports
# the append-only attribute (ext4 on Docker Desktop does); otherwise the pipeline warns.
install -d -m 750 -o deploy -g deploy /opt/secureship/anchors
touch /opt/secureship/anchors/ledger-anchors.jsonl
chown deploy:deploy /opt/secureship/anchors/ledger-anchors.jsonl
chmod 640 /opt/secureship/anchors/ledger-anchors.jsonl
if chattr +a /opt/secureship/anchors/ledger-anchors.jsonl 2>/dev/null; then
  echo "[lab-target] ledger anchor file is append-only"
else
  echo "[lab-target] WARNING: this filesystem does not support chattr +a – anchors are protected by permissions only" >&2
fi
su deploy -s /bin/sh -c "/usr/local/bin/bootstrap-env.sh /opt/secureship"

/usr/sbin/sshd -e
echo "[lab-target] sshd started; starting Docker engine"
exec dockerd-entrypoint.sh "$@"
