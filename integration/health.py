"""ShopPilot health endpoint – copy into the ShopPilot backend (e.g. app/routers/health.py).

    from app.routers.health import router as health_router
    app.include_router(health_router)

GET /health ->
    200 {"status": "ok", "version": "42-a1b2c3d4", "uptime_s": 812,
         "checks": {"database": {"ok": true, "latency_ms": 2.1}}}
    503 {"status": "degraded", ...}   when a required dependency (the database) is unreachable

`version` comes from the APP_VERSION env var (set to the image tag by the deployment), which lets
SecureShip prove that the NEW release is the one answering, not an old container.

The endpoint deliberately reveals nothing sensitive (no hostnames, no error strings beyond the
exception class), because it is reachable without authentication.
"""

from __future__ import annotations

import importlib
import os
import time

from fastapi import APIRouter, Response
from sqlalchemy import create_engine, text

router = APIRouter(tags=["health"])
_STARTED = time.time()
_engine = None


def _get_engine():
    """Reuse ShopPilot's own engine if we can find it, otherwise build one from DATABASE_URL.

    HEALTH_ENGINE_IMPORT lets you point at the engine explicitly, e.g. "app.database:engine".
    """
    global _engine
    if _engine is not None:
        return _engine
    candidates = [os.getenv("HEALTH_ENGINE_IMPORT", "")] + [
        "app.database:engine", "app.db:engine", "app.core.database:engine", "database:engine", "db:engine"]
    for spec in filter(None, candidates):
        module_name, _, attr = spec.partition(":")
        try:
            engine = getattr(importlib.import_module(module_name), attr or "engine")
        except (ImportError, AttributeError):
            continue
        _engine = getattr(engine, "sync_engine", engine)   # AsyncEngine -> its sync engine
        return _engine
    url = os.getenv("DATABASE_URL")
    if url:
        _engine = create_engine(url.replace("+asyncpg", ""), pool_pre_ping=True, pool_size=1, max_overflow=0)
    return _engine


def _check_database() -> dict:
    start = time.perf_counter()
    try:
        engine = _get_engine()
        if engine is None:
            return {"ok": False, "error": "no database configured"}
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return {"ok": True, "latency_ms": round((time.perf_counter() - start) * 1000, 1)}
    except Exception as exc:  # noqa: BLE001 – report any failure as "down"
        return {"ok": False, "error": type(exc).__name__}


@router.get("/health", include_in_schema=False)
def health(response: Response) -> dict:
    checks = {"database": _check_database()}
    healthy = all(c["ok"] for c in checks.values())
    response.status_code = 200 if healthy else 503
    response.headers["Cache-Control"] = "no-store"
    return {
        "status": "ok" if healthy else "degraded",
        "service": "shoppilot-backend",
        "version": os.getenv("APP_VERSION", "dev"),
        "uptime_s": int(time.time() - _STARTED),
        "checks": checks,
    }
