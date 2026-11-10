"""End-to-end tests: real HTTP requests through the web tier (Nginx) to the
app tier (Flask/Gunicorn) and the database (MySQL). Standard library only.

    E2E_BASE_URL=http://localhost:8080 pytest -v tests/e2e
    E2E_BASE_URL=https://<id>.cloudfront.net pytest -v tests/e2e   (live AWS)
"""
import json
import os
import uuid
import urllib.error
import urllib.request

import pytest

BASE = os.getenv("E2E_BASE_URL", "http://localhost:8080").rstrip("/")
SECURITY_HEADERS = {"X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY"}


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def as_json(raw):
    return json.loads(raw) if raw else None


def assert_security_headers(headers):
    for name, value in SECURITY_HEADERS.items():
        assert headers.get(name) == value, f"missing/wrong {name}: {headers.get(name)}"


# ---------------------------------------------------------------- web tier
def test_home_page_served_with_security_headers():
    status, headers, body = call("GET", "/")
    assert status == 200
    assert b"<!doctype html>" in body.lower()
    assert_security_headers(headers)
    # The HTML must always be revalidated, so a new release shows at once
    assert "no-cache" in headers.get("Cache-Control", "")


def test_static_asset_cached_and_still_has_security_headers():
    status, headers, _ = call("GET", "/style.css")
    assert status == 200
    assert "max-age=3600" in headers.get("Cache-Control", "")
    assert_security_headers(headers)


def test_web_health_and_identity():
    status, _, body = call("GET", "/healthz")
    assert status == 200 and body.strip() == b"ok"

    status, headers, body = call("GET", "/web-info")
    assert status == 200
    assert as_json(body)["tier"] == "web"
    assert "no-store" in headers.get("Cache-Control", "")  # never cached by CloudFront


# ---------------------------------------------------------------- app tier via the proxy
def test_api_health_through_proxy():
    status, headers, body = call("GET", "/api/health")
    assert status == 200
    assert as_json(body)["tier"] == "app"
    assert_security_headers(headers)
    assert "no-store" in headers.get("Cache-Control", "")


def test_database_reachable():
    status, _, body = call("GET", "/api/health/db")
    assert status == 200
    data = as_json(body)
    assert data["database"] == "reachable"
    assert "tls" in data
    if os.getenv("E2E_EXPECT_DB_TLS") == "1":  # set when testing the live AWS stack
        assert data["tls"] is True


# ---------------------------------------------------------------- full CRUD round trip
def test_task_lifecycle():
    title = f"e2e-{uuid.uuid4().hex[:8]}"

    status, _, body = call("POST", "/api/tasks", {"title": title})
    assert status == 201
    task = as_json(body)
    assert task["title"] == title and task["done"] is False
    tid = task["id"]

    try:
        status, _, body = call("GET", "/api/tasks")
        assert status == 200
        assert any(t["id"] == tid for t in as_json(body)["tasks"])

        status, _, body = call("PATCH", f"/api/tasks/{tid}", {"done": True})
        assert status == 200 and as_json(body)["done"] is True
    finally:
        status, _, _ = call("DELETE", f"/api/tasks/{tid}")
        assert status == 204

    status, _, _ = call("PATCH", f"/api/tasks/{tid}", {"done": False})
    assert status == 404


@pytest.mark.parametrize("payload", [{"title": ""}, {"title": "   "}, {"title": "x" * 201}, {}])
def test_invalid_titles_rejected(payload):
    status, _, body = call("POST", "/api/tasks", payload)
    assert status == 400
    assert "error" in as_json(body)
