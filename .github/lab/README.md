# Lab run helpers (GitHub Actions)

Used by `.github/workflows/lab-e2e.yml`, which runs the full SecureShip lab on a GitHub-hosted runner:

| File | Does |
|---|---|
| `screenshots.mjs` | Playwright screenshots: Jenkins stage view, the rollback console, SonarQube, the deployed ShopPilot, evidence reports and the ledger tamper demo |
| `collect.sh` | gathers each build's reports and console tail, diagnostics, and annotations for anything that went wrong |
| `publish.sh` | pushes the results to the `lab-results` branch as `runs/<run number>/` |

Start a run from **Actions → Lab end-to-end run → Run workflow**. It needs the `SHOPPILOT_TOKEN` repository secret (read-only token for ShopPilot).
