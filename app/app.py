"""Application tier: a small task-tracker REST API (Flask + SQLAlchemy).

Database credentials are never hardcoded. They are resolved in this order:
  1. DATABASE_URL                    (used by the unit tests: sqlite)
  2. DB_SECRET_ARN                   (AWS: JSON secret in Secrets Manager)
  3. DB_USER / DB_PASSWORD env vars  (local docker-compose, read from .env)
"""
import json
import logging
import os
import socket
import time
from datetime import datetime, timezone
from urllib.parse import quote_plus

from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()
log = logging.getLogger("app")


class Task(db.Model):
    __tablename__ = "tasks"

    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    done = db.Column(db.Boolean, nullable=False, default=False)
    created_at = db.Column(
        db.DateTime, nullable=False, default=lambda: datetime.now(timezone.utc)
    )

    def to_dict(self):
        return {
            "id": self.id,
            "title": self.title,
            "done": self.done,
            "created_at": self.created_at.isoformat(),
        }


def _secret_from_aws(secret_arn):
    import boto3  # imported lazily so local runs and tests do not need AWS

    client = boto3.client("secretsmanager")
    value = client.get_secret_value(SecretId=secret_arn)["SecretString"]
    return json.loads(value)


def build_database_url():
    if os.getenv("DATABASE_URL"):
        return os.environ["DATABASE_URL"]

    host = os.getenv("DB_HOST", "db")
    port = os.getenv("DB_PORT", "3306")
    name = os.getenv("DB_NAME", "tasksdb")

    if os.getenv("DB_SECRET_ARN"):
        secret = _secret_from_aws(os.environ["DB_SECRET_ARN"])
        user, password = secret["username"], secret["password"]
        host = secret.get("host", host)
        port = str(secret.get("port", port))
        name = secret.get("dbname", name)
    else:
        user = os.environ["DB_USER"]
        password = os.environ["DB_PASSWORD"]

    return f"mysql+pymysql://{quote_plus(user)}:{quote_plus(password)}@{host}:{port}/{name}"


def build_engine_options(database_url):
    """SQLAlchemy engine options. On AWS, DB_SSL_CA points at the RDS CA bundle
    baked into the image, so every MySQL connection is TLS-encrypted and the
    server certificate (and host name) is verified. RDS also refuses plain-text
    connections (require_secure_transport=1 in the DB parameter group)."""
    # pool_pre_ping drops dead connections after an RDS failover or restart
    options = {"pool_pre_ping": True, "pool_recycle": 280}
    ca_path = os.getenv("DB_SSL_CA")
    if ca_path and database_url.startswith("mysql"):
        options["connect_args"] = {"ssl": {"ca": ca_path}}
    return options


def db_tls_cipher():
    """The TLS cipher of the current DB session ('' = not encrypted, None = not MySQL)."""
    if db.engine.dialect.name != "mysql":
        return None
    row = db.session.execute(text("SHOW SESSION STATUS LIKE 'Ssl_cipher'")).fetchone()
    return row[1] if row else ""


def instance_info():
    return {
        "tier": "app",
        "hostname": socket.gethostname(),
        "instance_id": os.getenv("INSTANCE_ID", "local"),
        "availability_zone": os.getenv("AZ", "local"),
        "version": os.getenv("APP_VERSION", "dev"),
    }


def create_app(config=None):
    app = Flask(__name__)
    app.config["SQLALCHEMY_DATABASE_URI"] = (config or {}).get(
        "SQLALCHEMY_DATABASE_URI"
    ) or build_database_url()
    app.config["SQLALCHEMY_ENGINE_OPTIONS"] = build_engine_options(
        app.config["SQLALCHEMY_DATABASE_URI"]
    )
    app.config.update(config or {})
    db.init_app(app)

    with app.app_context():
        # Several hosts start at once, and RDS may still be warming up, so retry.
        for attempt in range(1, 7):
            try:
                db.create_all()
                break
            except Exception as exc:  # pragma: no cover - only on real start-up races
                log.warning("create_all attempt %d failed: %s", attempt, exc)
                time.sleep(5)
        # Gunicorn --preload forks workers after this point; never share a
        # pooled connection across processes. (Skipped for SQLite: disposing
        # would discard an in-memory test database.)
        if db.engine.dialect.name != "sqlite":
            db.engine.dispose()

    @app.get("/api/health")
    def health():
        # Liveness only: the load balancer must not mark every app node
        # unhealthy just because the database is briefly unreachable.
        return jsonify(status="ok", **instance_info())

    @app.get("/api/health/db")
    def health_db():
        try:
            db.session.execute(text("SELECT 1"))
            cipher = db_tls_cipher()
            return jsonify(
                status="ok",
                database="reachable",
                tls=bool(cipher),       # true when the app-to-DB link is encrypted
                tls_cipher=cipher or None,
            )
        except Exception as exc:  # pragma: no cover - exercised only on real failures
            log.exception("database check failed")
            return jsonify(status="error", database=str(exc.__class__.__name__)), 503

    @app.get("/api/info")
    def info():
        return jsonify(instance_info())

    @app.get("/api/tasks")
    def list_tasks():
        tasks = Task.query.order_by(Task.id.desc()).all()
        return jsonify(tasks=[t.to_dict() for t in tasks], served_by=instance_info())

    @app.post("/api/tasks")
    def create_task():
        data = request.get_json(silent=True) or {}
        title = str(data.get("title", "")).strip()
        if not title or len(title) > 200:
            return jsonify(error="title is required (1-200 characters)"), 400
        task = Task(title=title)
        db.session.add(task)
        db.session.commit()
        return jsonify(task.to_dict()), 201

    @app.patch("/api/tasks/<int:task_id>")
    def update_task(task_id):
        task = db.get_or_404(Task, task_id)
        data = request.get_json(silent=True) or {}
        if "done" in data:
            task.done = bool(data["done"])
        if "title" in data:
            title = str(data["title"]).strip()
            if not title or len(title) > 200:
                return jsonify(error="title must be 1-200 characters"), 400
            task.title = title
        db.session.commit()
        return jsonify(task.to_dict())

    @app.delete("/api/tasks/<int:task_id>")
    def delete_task(task_id):
        task = db.get_or_404(Task, task_id)
        db.session.delete(task)
        db.session.commit()
        return "", 204

    return app
