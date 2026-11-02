#!/bin/sh
# Create the server-side .env for ShopPilot with random secrets – only if it doesn't exist yet.
# The same script is used by target/setup-target.sh for a real Ubuntu server / EC2.
set -e
DIR="${1:-/opt/secureship}"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] && exit 0

rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
umask 077
DB_PASS="$(rand 32)"
cat > "$ENV_FILE" <<EOF
# ShopPilot runtime configuration – lives ONLY on the server (chmod 600). Never commit.
# Settings are read by backend/app/core/config.py (see backend/.env.example in ShopPilot).
POSTGRES_USER=shoppilot
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=shoppilot
DATABASE_URL=postgresql://shoppilot:${DB_PASS}@db:5432/shoppilot
SECRET_KEY=$(rand 64)
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
# Website and API share one origin through NGINX, so CORS only needs the public address
CORS_ORIGINS=http://localhost:8088
APP_URL=http://localhost:8088
DOCS_ENABLED=false
PRELOAD_OCR=true
# No SMTP configured in the lab: email features stay off
ALERTS_ENABLED=false
PUBLIC_PORT=8080
PUBLIC_BIND=0.0.0.0
# Optional email (owner alerts, forgot password):
# SMTP_HOST=smtp.gmail.com
# SMTP_PORT=587
# SMTP_USER=
# SMTP_PASSWORD=
# SMTP_FROM=
EOF
echo "[secureship] created $ENV_FILE with fresh random secrets"
