# A disposable Linux "server" for the lab: its own Docker engine (DinD) + OpenSSH.
# The pipeline treats it exactly like a real VM / EC2 instance: it connects over SSH
# with a key, ships images, runs docker compose, health-checks and rolls back.
FROM docker:27-dind

# Upgrade the base image first: it can ship an older openssh-client that conflicts with the
# newest openssh-server (and upgrading also picks up security fixes)
RUN apk upgrade --no-cache \
 && apk add --no-cache openssh-server bash curl jq tar gzip coreutils e2fsprogs-extra \
 && (docker compose version >/dev/null 2>&1 || apk add --no-cache docker-cli-compose) \
 && (getent group docker >/dev/null || addgroup -S docker) \
 && adduser -D -s /bin/bash deploy \
 && addgroup deploy docker \
 && sed -i 's/^deploy:!/deploy:*/' /etc/shadow \
 && mkdir -p /opt/secureship

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/lab-target-entrypoint.sh
COPY bootstrap-env.sh /usr/local/bin/bootstrap-env.sh
RUN chmod 0755 /usr/local/bin/lab-target-entrypoint.sh /usr/local/bin/bootstrap-env.sh

EXPOSE 22 8080
ENTRYPOINT ["/usr/local/bin/lab-target-entrypoint.sh"]
