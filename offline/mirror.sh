#!/usr/bin/env bash
# Зеркалирование образов в свой registry для прода без доступа к GitHub.
# Запускается на машине с интернетом после docker login в registry.
#   ./mirror.sh                 все образы инфраструктуры
#   ./mirror.sh --only-blocked  только недоступные в проде: ghcr.io и собранный publisher
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh
LOG_PREFIX=mirror

ONLY_BLOCKED=0
[ "${1:-}" = "--only-blocked" ] && ONLY_BLOCKED=1

load_root_env
[ -n "$IMAGE_MIRROR" ] || die "Задайте IMAGE_MIRROR в .env, например appsrvs.registry/mirror/"
mapfile -t IMAGES < <(offline/list-images.sh)

for image in "${IMAGES[@]}"; do
  if [ "$ONLY_BLOCKED" = 1 ]; then
    case "$image" in ghcr.io/*|valhalla-publisher:*) ;; *) continue ;; esac
  fi
  case "$image" in
    valhalla-publisher:*)
      log "Собираем $image"
      IMAGE_MIRROR="" compose valhalla build publisher ;;
    *)
      log "Скачиваем $image"
      docker pull "$image" ;;
  esac
  docker tag "$image" "${IMAGE_MIRROR}${image}"
  log "Отправляем ${IMAGE_MIRROR}${image}"
  docker push "${IMAGE_MIRROR}${image}"
done

log "Готово. На серверах: IMAGE_MIRROR=${IMAGE_MIRROR} в .env и docker login ${IMAGE_MIRROR%%/*} на каждом хосте"
