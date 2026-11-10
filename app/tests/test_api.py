import pytest

from app import create_app, db


@pytest.fixture()
def client():
    app = create_app({"SQLALCHEMY_DATABASE_URI": "sqlite:///:memory:", "TESTING": True})
    with app.test_client() as c:
        yield c
    with app.app_context():
        db.drop_all()


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_db_health(client):
    r = client.get("/api/health/db")
    assert r.status_code == 200
    assert r.get_json()["database"] == "reachable"


def test_create_and_list_tasks(client):
    r = client.post("/api/tasks", json={"title": "Deploy to AWS"})
    assert r.status_code == 201
    assert r.get_json()["title"] == "Deploy to AWS"

    r = client.get("/api/tasks")
    body = r.get_json()
    assert len(body["tasks"]) == 1
    assert "served_by" in body


def test_rejects_empty_title(client):
    r = client.post("/api/tasks", json={"title": "   "})
    assert r.status_code == 400


def test_update_and_delete(client):
    task_id = client.post("/api/tasks", json={"title": "Write report"}).get_json()["id"]

    r = client.patch(f"/api/tasks/{task_id}", json={"done": True})
    assert r.get_json()["done"] is True

    assert client.delete(f"/api/tasks/{task_id}").status_code == 204
    assert client.get("/api/tasks").get_json()["tasks"] == []


def test_missing_task_returns_404(client):
    assert client.patch("/api/tasks/999", json={"done": True}).status_code == 404


def test_db_health_reports_tls_field(client):
    # SQLite has no TLS; the field must still be present (false) so the
    # live MySQL/RDS response can be compared with it.
    body = client.get("/api/health/db").get_json()
    assert body["tls"] is False


def test_engine_options_add_tls_for_mysql(monkeypatch):
    from app import build_engine_options

    monkeypatch.setenv("DB_SSL_CA", "/etc/ssl/rds/global-bundle.pem")
    opts = build_engine_options("mysql+pymysql://u:p@db:3306/tasksdb")
    assert opts["connect_args"] == {"ssl": {"ca": "/etc/ssl/rds/global-bundle.pem"}}


def test_engine_options_no_tls_without_ca_or_for_sqlite(monkeypatch):
    from app import build_engine_options

    monkeypatch.delenv("DB_SSL_CA", raising=False)
    assert "connect_args" not in build_engine_options("mysql+pymysql://u:p@db:3306/x")

    monkeypatch.setenv("DB_SSL_CA", "/etc/ssl/rds/global-bundle.pem")
    assert "connect_args" not in build_engine_options("sqlite:///:memory:")
