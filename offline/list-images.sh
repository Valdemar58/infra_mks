#!/usr/bin/env bash
# Список всех образов инфраструктуры в исходных именах (без IMAGE_MIRROR).
# Берется из compose-файлов, руками не ведется. Используют mirror.sh и bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

load_root_env
export IMAGE_MIRROR=""
{
  compose nginx config --images
  compose keycloak config --images
  COMPOSE_FILE_NAME=docker-compose.dev.yml compose keycloak config --images
  compose docker_registry config --images
  compose observability config --images
  compose valhalla --profile winter config --images
  # без profile build: planetiler нужен только на машине с интернетом
  compose tiles config --images
  # htpasswd для registry берется из образа httpd
  echo httpd:2
} 2>/dev/null | sed '/^$/d' | sort -u
