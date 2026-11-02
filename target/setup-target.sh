#!/usr/bin/env bash
# Prepare a fresh Ubuntu 22.04/24.04 server (local VM, or an AWS EC2 instance) as a
# SecureShip deployment target. Run ONCE on the server:
#
#   scp -i <key> target/setup-target.sh ci/lab-target/bootstrap-env.sh ci/keys/deploy_ed25519.pub ubuntu@<host>:
#   ssh -i <key> ubuntu@<host> 'sudo bash setup-target.sh deploy_ed25519.pub'
#
# What it does: installs Docker Engine + Compose, creates an unprivileged `deploy` user
# that only accepts the pipeline's SSH key, hardens sshd, enables the host firewall and
# automatic security updates, and creates /opt/secureship/.env with random secrets.
set -euo pipefail

PUBKEY_FILE="${1:?usage: sudo bash setup-target.sh <deploy_public_key_file>}"
APP_PORT="${APP_PORT:-8080}"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$PUBKEY_FILE" ] || { echo "public key file not found: $PUBKEY_FILE"; exit 1; }
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || echo "WARNING: tested on Ubuntu, detected '${ID:-unknown}'"

echo "==> Installing Docker Engine (official repository)"
apt-get update -q
apt-get install -y -q ca-certificates curl jq gzip ufw unattended-upgrades e2fsprogs gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "==> Docker daemon hardening (log rotation, no new privileges)"
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "live-restore": true
}
EOF
systemctl restart docker

echo "==> Creating deploy user"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy "$PUBKEY_FILE" /home/deploy/.ssh/authorized_keys
passwd -l deploy >/dev/null   # no password at all; key-only

echo "==> Hardening sshd"
cat > /etc/ssh/sshd_config.d/99-secureship.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
EOF
# With `passwd -l`, Ubuntu's sshd (UsePAM yes) still allows key login for the deploy user.
systemctl reload ssh || systemctl reload sshd

echo "==> Firewall (defence in depth – AWS Security Groups are the outer layer)"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow "${APP_PORT}/tcp"
ufw --force enable
# NOTE: Docker publishes ports through iptables and can bypass ufw. That is why the compose
# file publishes only the frontend port and never PostgreSQL, and why the Security Group
# must also restrict access.

echo "==> Automatic security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Application directory + secrets"
install -d -m 750 -o deploy -g deploy /opt/secureship

echo "==> Append-only anchor store for the deployment ledger"
# The pipeline appends each ledger entry's hash here. chattr +a means the deploy user (and so
# a compromised Jenkins holding its SSH key) can add lines but never truncate or delete the
# file; only root on this server can lift the attribute.
install -d -m 750 -o deploy -g deploy /opt/secureship/anchors
touch /opt/secureship/anchors/ledger-anchors.jsonl
chown deploy:deploy /opt/secureship/anchors/ledger-anchors.jsonl
chmod 640 /opt/secureship/anchors/ledger-anchors.jsonl
chattr +a /opt/secureship/anchors/ledger-anchors.jsonl
lsattr /opt/secureship/anchors/ledger-anchors.jsonl
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/bootstrap-env.sh" ]; then
  sudo -u deploy sh "$SCRIPT_DIR/bootstrap-env.sh" /opt/secureship
else
  echo "bootstrap-env.sh not found next to this script – create /opt/secureship/.env manually"
fi

cat <<EOF

  ✔ Target ready.
  In Jenkins (Manage Jenkins → System → Global properties → Environment variables) set:
      DEPLOY_HOST    = <this server's public DNS / IP>
      DEPLOY_USER    = deploy
      APP_PUBLIC_URL = http://<this server's public DNS / IP>:${APP_PORT}
  Then run the SecureShip job. Review /opt/secureship/.env and add ShopPilot settings if needed.
EOF
