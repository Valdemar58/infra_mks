#!/usr/bin/env bash
# Reverse-proxy: поднимает nginx с шаблонами из templates/ и проверяет конфиг.
#   ./setup.sh          поднять или пересоздать с текущими шаблонами и .env
#   ./setup.sh --show   показать отрендеренные конфиги
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=nginx

load_root_env

if [ "${1:-}" = "--show" ]; then
  container_running infra_nginx || die "nginx не запущен"
  docker exec infra_nginx sh -c 'for f in /etc/nginx/conf.d/*.conf; do echo "===== $f"; cat "$f"; done'
  exit 0
fi

[ -f ../certs/fullchain.pem ] && [ -f ../certs/server.key ] || die "Нет сертификата: сначала certs/setup.sh"
ensure_stack_images nginx
# Шаблоны рендерятся при старте контейнера, поэтому после их правки
# контейнер пересоздается, а не перечитывает конфиг.
compose nginx up -d --force-recreate $(pull_flag)
docker exec infra_nginx nginx -t
log "nginx обслуживает: $(host_names | tr '\n' ' ')"
