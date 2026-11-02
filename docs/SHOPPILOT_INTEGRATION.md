# ShopPilot ↔ SecureShip: integration notes

This describes the **actual** ShopPilot code (`github.com/hrushikapendharkar4241-droid/shoppilot`, branch `master`) and how SecureShip is configured for it. The defaults in this repo already match. The other sections are for when ShopPilot changes.

## What was verified against ShopPilot's real code

| Item | ShopPilot | SecureShip setting |
|---|---|---|
| Repository / branch | `shoppilot.git`, **`master`**, **private**. Local copy: `C:\Users\Hrushika\SareeERP-Pro`, in sync with GitHub at commit `d710eb35` (M8d) | Jenkinsfile defaults `APP_REPO`, `APP_BRANCH=master`. Jenkins clones with the read-only token credential `shoppilot-git` that `bootstrap.sh` asks for |
| Backend | `backend/`, FastAPI app `app.main:app`, `requirements.txt` + `requirements-dev.txt` | `BACKEND_SUBDIR=backend`, `APP_MODULE=app.main:app`; the test image installs `requirements-dev.txt` |
| Python | 3.12 | `PYTHON_VERSION=3.12` |
| PyTorch | `requirements.txt` already pins the **CPU** build via the PyTorch CPU index | the Dockerfile's CPU-wheel pre-install is skipped automatically |
| PDF fonts | `pdf_brand.py` looks for DejaVu on Linux (₹ sign) | `fonts-dejavu-core` installed; the build smoke test fails if it's missing |
| API routes | **no `/api` prefix** (`/auth/login`, `/products/` …); `app/serve.py` mounts the API under `/api` | NGINX `API_UPSTREAM=http://backend:8000/` strips `/api` |
| Frontend | Vite 8 + React 19, `npm run build` → `dist/`, reads `VITE_API_URL` | built with `VITE_API_URL=/api` on Node 22 LTS |
| Database tables | created by `Base.metadata.create_all` at start-up | nothing extra needed for a fresh database |
| Uploads (scanner photos, imported files) | stored in the database, not on disk | no upload volume required |
| Tests | `backend/tests/conftest.py` refuses to run unless the test DB name ends in `_test` **and** differs from `DATABASE_URL`, and it creates that DB itself | `test.sh` sets `DATABASE_URL=…/shoppilot` and `TEST_DATABASE_URL=…/shoppilot_test` on a throw-away PostgreSQL 16 |
| Settings | `app/core/config.py` requires `DATABASE_URL` and `SECRET_KEY` (≥ 32 chars) | the server `.env` is generated with these, plus `DOCS_ENABLED=false`, `PRELOAD_OCR=true`, `ALERTS_ENABLED=false` |
| Security headers | the backend sets its own | NGINX hides the backend's copies, so the browser gets exactly one set |

## The `/health` endpoint (already added to your ShopPilot folder)

These files were added:
- `backend/app/routers/health.py` (new)
- `backend/tests/test_health.py` (new): 5 tests
- `backend/app/main.py`: two lines (`from app.routers import health`, `app.include_router(health.router)`)

What was checked before writing them to your folder:
- ShopPilot's full suite: **303 passed** (298 existing + 5 new) on PostgreSQL 16. The OCR libraries weren't installed for that run; your scanner tests fake OCR anyway.
- A live `uvicorn` run:
  - `/health` returned 200 with the database up
  - 503 `degraded` with PostgreSQL stopped
  - 200 again after restarting it
  - `/openapi.json` returned 404 with `DOCS_ENABLED=false`

**Commit and push them yourself** so the pipeline sees them:

```bash
cd SareeERP-Pro
git add backend/app/routers/health.py backend/tests/test_health.py backend/app/main.py
git commit -m "Add /health endpoint for deployment health checks"
git push origin master
```

Note: `main.py` uses Windows (CRLF) line endings and the edit preserved them, so `git diff` shows only the two new lines.

## If ShopPilot changes later

| Change | What to do |
|---|---|
| Folders renamed | set `BACKEND_SUBDIR` / `FRONTEND_SUBDIR` (Jenkins global env vars) |
| Routes gain an `/api` prefix | set `API_UPSTREAM=http://backend:8000` (no trailing slash) in `/opt/secureship/.env` on the target |
| New required setting in `config.py` | add it to `/opt/secureship/.env` on the target (and to `ci/lab-target/bootstrap-env.sh` for fresh labs) |
| Schema changes | keep them backward-compatible (add first, remove in a later release), so a rollback to the previous image still works against the new schema. A `pg_dump` is taken before every release (`/opt/secureship/backups/`). |
| Python version bump | set `PYTHON_VERSION` (Jenkins global env var) |

Restore a backup if ever needed:

```bash
gunzip -c /opt/secureship/backups/pre-<tag>-<time>.sql.gz | docker compose -p shoppilot exec -T db psql -U shoppilot -d shoppilot
```

## Things to check on the first real run

1. **Gitleaks scans ShopPilot's entire Git history.** `backend/.env` is git-ignored today, but if a real secret was ever committed in the past, the gate will block. Then the right fix is to **rotate that secret**, and either clean the history or record a justified, expiring exception.
2. **PyTorch CPU wheels** come from `download.pytorch.org`, which must be reachable from Docker during the build.
3. **First start downloads the EasyOCR model** (~100 MB) into the `easyocr-models` volume (`PRELOAD_OCR=true`). The health check doesn't depend on it, but the first scan does.
