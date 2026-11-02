"""Copy into ShopPilot's backend tests/ folder alongside health.py.

Adjust the import of `app` and `health` to match ShopPilot's package layout.
"""

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routers import health  # adjust if you placed health.py elsewhere


def _client(monkeypatch, db_result):
    monkeypatch.setattr(health, "_check_database", lambda: db_result)
    api = FastAPI()
    api.include_router(health.router)
    return TestClient(api)


def test_health_ok_reports_version(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "42-abcdef12")
    res = _client(monkeypatch, {"ok": True, "latency_ms": 1.0}).get("/health")
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "ok"
    assert body["version"] == "42-abcdef12"
    assert body["checks"]["database"]["ok"] is True


def test_health_degraded_when_database_down(monkeypatch):
    res = _client(monkeypatch, {"ok": False, "error": "OperationalError"}).get("/health")
    assert res.status_code == 503
    assert res.json()["status"] == "degraded"
