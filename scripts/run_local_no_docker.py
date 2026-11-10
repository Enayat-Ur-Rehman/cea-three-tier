"""Run the app on one machine WITHOUT Docker (preview only).

Serves the web tier's static files and the application tier's API from one
Flask process, with SQLite in place of MySQL. Use it when Docker Desktop is
unavailable. The real three-tier run is `docker compose up --build`.

    pip install -r app/requirements.txt
    python scripts/run_local_no_docker.py
    open http://localhost:8080
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))
os.environ.setdefault("DATABASE_URL", f"sqlite:///{ROOT / 'local-preview.db'}")
os.environ.setdefault("APP_VERSION", "preview")

from flask import jsonify, send_from_directory  # noqa: E402

from app import create_app  # noqa: E402

HTML = ROOT / "web" / "html"
app = create_app()


@app.get("/")
def index():
    return send_from_directory(HTML, "index.html")


@app.get("/<path:name>")
def static_files(name):
    return send_from_directory(HTML, name)


@app.get("/healthz")
def healthz():
    return "ok\n"


@app.get("/web-info")
def web_info():
    return jsonify(tier="web", instance_id="local-preview", availability_zone="local")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
