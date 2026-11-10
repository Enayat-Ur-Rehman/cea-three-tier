#!/usr/bin/env bash
# Smoke test of the live deployment over HTTPS through CloudFront.
# Passes only when the whole chain works: CloudFront -> public ALB -> Nginx ->
# internal ALB -> Flask -> RDS, and the app-to-RDS connection is TLS-encrypted.
# Skips on the first bootstrap run, before Terraform has created CloudFront.
set -euo pipefail

URL=$(aws ssm get-parameter --name "/$PROJECT/public_url" \
      --query Parameter.Value --output text 2>/dev/null || true)
if [ -z "$URL" ] || [ "$URL" = "None" ]; then
  echo "::warning::/$PROJECT/public_url not found yet (bootstrap run). Skipping smoke test."
  exit 0
fi

echo "App URL: $URL"
for _ in $(seq 1 30); do
  if body=$(curl -fsS --max-time 10 "$URL/api/health/db"); then
    echo "$body"
    if echo "$body" | grep -q '"tls": *true'; then
      curl -fsS --max-time 10 "$URL/api/info"; echo
      curl -fsS --max-time 10 -o /dev/null "$URL/"
      echo "### Deployed \`${IMAGE_TAG:-unknown}\` to $URL" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
      exit 0
    fi
    echo "::error::Database reachable but the connection is not TLS-encrypted"
    exit 1
  fi
  sleep 10
done
echo "::error::Smoke test failed: $URL/api/health/db never answered 200"
exit 1
