# Web tier image: Nginx (unprivileged variant, runs as a non-root user on port 8080)
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Defaults suit docker-compose; on AWS the EC2 user data overrides them.
ENV APP_HOST=app \
    APP_PORT=5000 \
    NGINX_RESOLVER=127.0.0.11 \
    WEB_INSTANCE_ID=local \
    WEB_AZ=local

# Remove the stock site, add ours as a template (rendered at start-up)
USER root
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY html/ /usr/share/nginx/html/
RUN chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/conf.d
USER nginx

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
