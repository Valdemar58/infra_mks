#!/usr/bin/env bash
# Логи: Loki, Alloy, Grafana. Grafana снаружи через nginx (HOST_GRAFANA).
#   ./setup.sh           основной стек
#   ./setup.sh --agent   только Alloy на хосте без основного стека, пишет в Loki по app-network
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=observability

load_root_env
TOUCH_IMAGE="${IMAGE_MIRROR}nginx:1.27-alpine"

if [ "${1:-}" = "--agent" ]; then
  export COMPOSE_FILE_NAME=docker-compose.agent.yml
  ensure_stack_images observability
  compose observability up -d $(pull_flag)
  ensure_image "$TOUCH_IMAGE" >/dev/null
  if docker run --rm --network "$APP_NETWORK" "$TOUCH_IMAGE" wget -qO- --timeout=5 "${LOKI_URL:-http://loki:3100}/ready" >/dev/null 2>&1; then
    log "Loki доступен по ${LOKI_URL:-http://loki:3100}, агент отправляет логи контейнеров $APP_CONTAINER_REGEX"
  else
    warn "Loki по ${LOKI_URL:-http://loki:3100} из app-network не отвечает: основной стек на другом хосте не поднят или сеть не overlay"
  fi
  exit 0
fi

ensure_env_file . GF_SECURITY_ADMIN_PASSWORD
ensure_stack_images observability
compose observability up -d $(pull_flag)
wait_http http://127.0.0.1:3001/api/health 90 || die "Grafana не поднялась: docker logs infra_obs_grafana"
if container_running infra_nginx; then
  wait_tls "$HOST_GRAFANA" /api/health 60 || warn "Grafana не отвечает через nginx"
fi
log "Grafana: https://$HOST_GRAFANA (admin / GF_SECURITY_ADMIN_PASSWORD), локально http://127.0.0.1:3001"
log "Alloy собирает контейнеры по маске: $APP_CONTAINER_REGEX"
