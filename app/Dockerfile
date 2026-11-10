# ---------- Stage 1: build wheels (compilers stay out of the final image) ----------
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---------- Stage 2: small runtime image ----------
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /srv

# Run as an unprivileged user, never as root
RUN groupadd --system app && useradd --system --gid app --no-create-home app

COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/* && rm -rf /wheels

# Amazon RDS CA bundle, used to verify the database's TLS certificate.
# ADD creates the file as root with mode 600, so make it readable by the app user.
ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds/global-bundle.pem
RUN chmod 644 /etc/ssl/rds/global-bundle.pem

COPY app.py .
USER app

EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/api/health', timeout=2).status == 200 else 1)"

# Gunicorn: 2 worker processes x 4 threads suits a t3.micro (2 vCPU, 1 GiB)
# --preload builds the app (and creates the table) once, before the workers fork
CMD ["gunicorn", "--preload", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", \
     "--access-logfile", "-", "--error-logfile", "-", "app:create_app()"]
