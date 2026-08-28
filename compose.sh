#!/usr/bin/env bash
# docker compose для одного стека с корневым .env и .env стека, чтобы
# IMAGE_MIRROR и прочие корневые настройки действовали и при ручных
# операциях:
#   ./compose.sh valhalla logs -f valhalla-summer
#   ./compose.sh keycloak --dev up -d         --dev = docker-compose.dev.yml
#   ./compose.sh observability --agent ps     --agent = docker-compose.agent.yml
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

[ $# -ge 1 ] || die "Использование: ./compose.sh <стек> [--dev|--agent] <аргументы docker compose>"
stack="$1"; shift
[ -f "$stack/docker-compose.yml" ] || die "Нет стека $stack"
case "${1:-}" in
  --dev) export COMPOSE_FILE_NAME=docker-compose.dev.yml; shift ;;
  --agent) export COMPOSE_FILE_NAME=docker-compose.agent.yml; shift ;;
esac

load_root_env
compose "$stack" "$@"
