#!/usr/bin/env bash
# Приватный docker registry с htpasswd за nginx (HOST_REGISTRY).
#   ./setup.sh              поднять; пользователей нет: создать из REGISTRY_USER/REGISTRY_PASSWORD
#   ./setup.sh --add-user   добавить или заменить пользователя из .env
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=registry

load_root_env
ADD_USER=0
[ "${1:-}" = "--add-user" ] && ADD_USER=1
HTPASSWD=auth/htpasswd
HTPASSWD_IMAGE="${IMAGE_MIRROR}httpd:2"
mkdir -p auth

users() {
  [ -f "$HTPASSWD" ] || return 0
  cut -d: -f1 "$HTPASSWD" | grep -v '^$' || true
}

# Оставляет только строки пользователей: посторонний текст в файле
# (например вывод docker pull, попавший в перенаправление) ломает registry.
sanitize() {
  [ -f "$HTPASSWD" ] || return 0
  local clean
  clean="$(grep -E '^[^:]+:\$2[aby]\$[0-9]{2}\$' "$HTPASSWD" || true)"
  if [ "$clean" != "$(cat "$HTPASSWD")" ]; then
    warn "В $HTPASSWD были посторонние строки, оставлены только записи пользователей"
    printf '%s\n' "$clean" > "$HTPASSWD"
  fi
}

add_user() {
  ensure_env_file . REGISTRY_USER REGISTRY_PASSWORD
  local user pass line
  user="$(env_value .env REGISTRY_USER)"
  pass="$(env_value .env REGISTRY_PASSWORD)"
  ensure_image "$HTPASSWD_IMAGE"
  line="$(docker run --rm --entrypoint htpasswd "$HTPASSWD_IMAGE" -Bbn "$user" "$pass" | grep -E '^[^:]+:\$2[aby]\$' || true)"
  [ -n "$line" ] || die "htpasswd не вернул хэш"
  { { [ -f "$HTPASSWD" ] && grep -v "^$user:" "$HTPASSWD"; } || true; printf '%s\n' "$line"; } > "$HTPASSWD.tmp"
  mv "$HTPASSWD.tmp" "$HTPASSWD"
  log "Пользователь $user записан в $HTPASSWD"
}

sanitize
if [ "$ADD_USER" = 1 ]; then
  add_user
elif [ -z "$(users)" ]; then
  log "В $HTPASSWD нет пользователей, создаем из .env"
  add_user
else
  log "Пользователи registry: $(users | tr '\n' ' ')"
fi

ensure_stack_images docker_registry
compose docker_registry up -d $(pull_flag)
wait_healthy registry 90 || die "registry не поднялся: docker logs registry"
if container_running infra_nginx; then
  wait_tls "$HOST_REGISTRY" /v2/ 60 || warn "registry не отвечает через nginx: docker logs registry_ui"
else
  warn "nginx на этом хосте не запущен, доступность registry снаружи не проверена"
fi
log "Вход: docker login $HOST_REGISTRY -u <пользователь>"
