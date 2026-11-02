# SecureShip Jenkins controller: Jenkins LTS + Docker CLI + Trivy + Gitleaks + Python,
# configured entirely as code (plugins.txt + casc.yaml) – no click-through setup wizard.
#
# Supply-chain note (see docs/SUPPLY_CHAIN.md)
# --------------------------------------------
# A checksum only helps if the checksum itself comes from a source the attacker cannot
# also change. A SHA256SUMS file downloaded from the SAME GitHub release as the binary
# does not meet that bar: whoever can replace the binary can replace the checksum file.
#
# So the scanners are built from source, and every module is authenticated by Go's
# checksum database (sum.golang.org): a public, append-only transparency log whose
# signing key is compiled into the Go toolchain. `go mod download` refuses any module
# whose content differs from what the log recorded the first time anyone fetched that
# version. A release re-tagged or replaced later therefore fails the build instead of
# silently entering the pipeline.
#
# Version pinning still matters: Trivy v0.69.4 was a malicious release (March 2026,
# CVE-2026-33634). A pinned, reviewed version + an authenticated source is the control.

# ---------------------------------------------------------------- scanners (from source)
FROM golang:1.26 AS tools
ARG TRIVY_VERSION=v0.69.3
ARG GITLEAKS_VERSION=v8.21.2
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Checksum-database verification must stay ON: refuse to build if anything disables it.
# hadolint ignore=DL3064
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto GOFLAGS=-trimpath GOSUMDB=sum.golang.org GONOSUMDB="" GOPRIVATE="" GOINSECURE=""
WORKDIR /src
# hadolint ignore=DL3003,SC3043
RUN set -eux; \
    test "$(go env GOSUMDB)" = "sum.golang.org"; \
    mkdir -p /out /provenance; \
    build() { \
      local mod="$1" ver="$2" pkg="$3" out="$4" ldflags="$5"; \
      rm -rf /tmp/probe && mkdir /tmp/probe && cd /tmp/probe && go mod init probe >/dev/null 2>&1; \
      go mod download -json "${mod}@${ver}" | tee "/provenance/${out}.module.json"; \
      local dir; dir="$(go env GOMODCACHE)/${mod}@${ver}"; \
      cp -r "$dir" "/src/${out}" && chmod -R u+w "/src/${out}" && cd "/src/${out}"; \
      go build -mod=readonly -ldflags "-s -w ${ldflags}" -o "/out/${out}" "./${pkg}"; \
      go version -m "/out/${out}" > "/provenance/${out}.buildinfo.txt"; \
    }; \
    build github.com/aquasecurity/trivy "$TRIVY_VERSION" cmd/trivy trivy \
      "-X github.com/aquasecurity/trivy/pkg/version/app.ver=${TRIVY_VERSION#v}"; \
    build github.com/zricethezav/gitleaks/v8 "$GITLEAKS_VERSION" . gitleaks \
      "-X github.com/zricethezav/gitleaks/v8/version.Version=${GITLEAKS_VERSION} -X github.com/zricethezav/gitleaks/v8/cmd.Version=${GITLEAKS_VERSION}"; \
    /out/trivy --version; /out/gitleaks version || true

# ---------------------------------------------------------------- Jenkins controller
FROM jenkins/jenkins:lts-jdk21

# Root is intentional at build time; the entrypoint drops to the `jenkins` user (gosu).
# hadolint ignore=DL3002
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Docker's apt signing key, pinned by fingerprint (published in Docker's install docs).
# The key is fetched over HTTPS, then REJECTED unless its fingerprint matches – so a
# substituted key cannot be used to sign a malicious docker CLI package.
ARG DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq git python3 python3-yaml openssh-client gosu \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && actual="$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '/^fpr/ {print $10; exit}')" \
 && { [ "$actual" = "$DOCKER_GPG_FINGERPRINT" ] || { echo "Docker apt key fingerprint mismatch: $actual" >&2; exit 1; }; } \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

COPY --from=tools /out/trivy /out/gitleaks /usr/local/bin/
COPY --from=tools /provenance/ /usr/local/share/secureship/provenance/
RUN trivy --version && docker --version

# Plugins: jenkins-plugin-cli verifies each download against the SHA-256 published in the
# signed Jenkins update-center metadata.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY casc.yaml /usr/share/jenkins/casc/casc.yaml
COPY init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
COPY entrypoint.sh /usr/local/bin/secureship-entrypoint.sh
RUN chmod 0755 /usr/local/bin/secureship-entrypoint.sh

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
    CASC_JENKINS_CONFIG=/usr/share/jenkins/casc/casc.yaml

# Starts as root only to grant the jenkins user access to the Docker socket, then drops privileges.
ENTRYPOINT ["/usr/local/bin/secureship-entrypoint.sh"]
