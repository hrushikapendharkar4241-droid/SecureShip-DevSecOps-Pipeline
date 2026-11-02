# Supply chain: what SecureShip trusts, and why

A pipeline that scans for vulnerabilities is itself a high-value target. If the scanner is compromised, it can report "clean" for anything.

In March 2026, attackers compromised Trivy's release process and published a malicious **v0.69.4** (CVE-2026-33634). Pipelines that pulled the latest version ran it.

## Why the first version was not good enough

The first version downloaded the Trivy/Gitleaks release binary and checked it against the `checksums.txt` from **the same GitHub release**. That catches corruption, but not a compromised release: whoever can replace the binary can replace the checksum file next to it. A checksum is only as trustworthy as the channel it came from.

## What SecureShip does now

| Component | How it is obtained | Who/what you trust |
|---|---|---|
| **Trivy, Gitleaks** | Built from source in `ci/jenkins/Dockerfile`. `go mod download` fetches each module and verifies it against **Go's checksum database** (`sum.golang.org`), and the build runs with `-mod=readonly` against the module's own `go.sum`. The build refuses to start if checksum verification is disabled. | The Go toolchain's built-in sum.golang.org public key. The log is public and append-only, so a version's content cannot change after it was first recorded. Plus **your review of the pinned version** (v0.69.3 predates the compromised v0.69.4). |
| Scanner provenance | `go version -m` output and the module hashes are saved in the image. Every build copies them to `reports/tool-provenance/`. | — (evidence, so a reviewer can see exactly which scanner build produced a report) |
| Docker CLI (Jenkins image) and Docker Engine (`target/setup-target.sh`) | Docker's apt repository, signed with Docker's GPG key, **pinned by fingerprint** `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`. The build fails if the downloaded key differs. | The fingerprint published in Docker's install documentation. |
| Jenkins plugins | `jenkins-plugin-cli`, which checks each plugin against the SHA-256 in the **signed** Jenkins update-center metadata. | The Jenkins project's update-center signing key. |
| Python packages (ShopPilot) | `pip` with ShopPilot's exact pinned versions from PyPI and the PyTorch CPU index. | PyPI / download.pytorch.org over TLS. **Not hash-pinned yet.** See next steps. |
| Base images (`python`, `node`, `nginx-unprivileged`, `postgres`, `golang`, `jenkins`, `sonarqube`, `zaproxy`) | By **tag** from Docker Hub / GHCR. | The registry and the publisher. **Tags are mutable.** See next steps. |

## Honest gaps and next steps

1. **Pin base images by digest.** Run `docker buildx imagetools inspect <image:tag>` (or `docker pull`) once, review it, and replace `image:tag` with `image:tag@sha256:…`. Then rebuilds use exactly the reviewed image, and Trivy tells you when it ages.
2. **Hash-pin Python dependencies.** `pip-compile --generate-hashes` in ShopPilot, then `pip install --require-hashes`.
3. **Verify signatures where publishers sign.** For example, `cosign verify` for images and release artifacts that are signed through Sigstore.
4. **Sign SecureShip's own output.** `cosign sign` the ShopPilot images and verify the signature on the target before `docker compose up`.

## If the Trivy source build fails

The source build is written but has not yet been run in this project. If `go build` of the pinned version fails on the first lab run:
- Don't fall back to an unverified download.
- Check the error, which is usually a Go toolchain version (`GOTOOLCHAIN=auto` fetches the required one, verified the same way).
- Or pin a different reviewed Trivy release and rebuild.
