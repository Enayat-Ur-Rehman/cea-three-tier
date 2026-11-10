#!/usr/bin/env bash
# Network segmentation check for the local compose stack (mirrors the AWS
# security groups): the web tier must NOT reach the database, the app tier must.
# Usage: bash scripts/check_segmentation.sh [compose project name]
set -uo pipefail
P=(); [ -n "${1:-}" ] && P=(-p "$1")

# nginx (busybox) and python images both have a TCP client available.
web_rc=0
docker compose "${P[@]}" exec -T web sh -c 'command -v nc >/dev/null || exit 99; nc -z -w 3 db 3306' || web_rc=$?
app_rc=0
docker compose "${P[@]}" exec -T app python -c "import socket; socket.create_connection(('db', 3306), 3)" || app_rc=$?

echo "web -> db:3306 exit code $web_rc (must be non-zero), app -> db:3306 exit code $app_rc (must be 0)"
if [ "$web_rc" = "99" ]; then echo "FAIL: nc missing in the web image, check is not valid"; exit 1; fi
if [ "$web_rc" = "0" ]; then echo "FAIL: web tier can reach the database"; exit 1; fi
if [ "$app_rc" != "0" ]; then echo "FAIL: app tier cannot reach the database"; exit 1; fi
echo "PASS: web tier is isolated from the database; app tier can reach it"
