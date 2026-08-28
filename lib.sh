#!/usr/bin/env bash
# Общие функции скриптов установки. Подключение из скрипта стека:
#   . "$(dirname "$0")/../lib.sh"
# Каждая функция печатает, что делает, и ничего не пересоздает молча.

set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_ENV="$INFRA_ROOT/.env"
LOG_PREFIX="${LOG_PREFIX:-infra}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '\033[1;33m[%s] ВНИМАНИЕ:\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ОШИБКА:\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Нужна команда: $c"
  done
}

# Путь относительно корня репозитория для сообщений.
rel_path() {
  local p
  p="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  printf '%s\n' "${p#"$INFRA_ROOT"/}"
}

# Значение переменной из env-файла: последнее вхождение, без кавычек и CR.
env_value() {
  local file="$1" var="$2"
  { grep -E "^${var}=" "$file" 2>/dev/null || true; } | tail -1 | tr -d '\r' | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# Переменные env-файла, оставшиеся с плейсхолдерами из .env.example:
# change-me или <...>. Пустые значения плейсхолдером не считаются.
env_placeholders() {
  local file="$1" line name value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      [A-Za-z_]*=*) ;;
      *) continue ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    case "$value" in
      *change-me*|*"<"*">"*) printf '%s\n' "$name" ;;
    esac
  done < "$file"
}

# Пустое значение или плейсхолдер из .env.example.
is_placeholder() {
  case "$1" in
    ""|*change-me*|*"<"*">"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Создает <каталог>/.env из .env.example, если его нет, и требует
# заполнить перечисленные переменные.
ensure_env_file() {
  local dir="$1"; shift
  local example="$dir/.env.example" env="$dir/.env" missing=() var shown
  [ -f "$example" ] || die "Нет $(rel_path "$example")"
  shown="$(rel_path "$env")"
  if [ ! -f "$env" ]; then
    cp "$example" "$env"
    log "Создан $shown из .env.example"
  fi
  for var in "$@"; do
    if is_placeholder "$(env_value "$env" "$var")"; then
      missing+=("$var")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Заполните в $shown: ${missing[*]} и запустите снова"
  fi
}

# Экспортирует корневой .env: его читают скрипты и compose.
# CR из файлов, правленных в Windows, отбрасывается.
load_root_env() {
  if [ ! -f "$ROOT_ENV" ]; then
    cp "$INFRA_ROOT/.env.example" "$ROOT_ENV"
    log "Создан $(rel_path "$ROOT_ENV") из .env.example"
  fi
  set -a
  # shellcheck disable=SC1090
  . <(tr -d '\r' < "$ROOT_ENV")
  set +a
  export NETWORK_DRIVER="${NETWORK_DRIVER:-bridge}"
  export APP_NETWORK="${APP_NETWORK:-app-network}"
  export IMAGE_MIRROR="${IMAGE_MIRROR:-}"
  export OFFLINE="${OFFLINE:-0}"
}

# Имена сервисов за nginx: значения всех HOST_* из корневого .env.
host_names() {
  local v
  for v in $(compgen -A variable HOST_ || true); do
    [ -n "${!v}" ] && printf '%s\n' "${!v}"
  done | sort -u
}

# docker compose стека с корневым .env и .env стека (стек перекрывает корень).
# COMPOSE_FILE_NAME переопределяет compose-файл, например docker-compose.dev.yml.
compose() {
  local stack="$1"; shift
  local dir="$INFRA_ROOT/$stack" file="${COMPOSE_FILE_NAME:-docker-compose.yml}"
  local args=(--env-file "$ROOT_ENV")
  [ -f "$dir/.env" ] && args+=(--env-file "$dir/.env")
  ( cd "$dir" && docker compose "${args[@]}" -f "$dir/$file" "$@" )
}

# Флаг для up: в офлайн-режиме compose не должен ничего скачивать.
pull_flag() {
  if [ "${OFFLINE:-0}" = "1" ]; then echo "--pull never"; fi
}

# Образ должен быть локально; в офлайн-режиме скачивание запрещено.
ensure_image() {
  local image="$1"
  if docker image inspect "$image" >/dev/null 2>&1; then
    log "Образ на месте: $image"
    return 0
  fi
  if [ "${OFFLINE:-0}" = "1" ]; then
    die "Нет образа $image при OFFLINE=1. Загрузите бандл (offline/load.sh <каталог>) или заполните зеркало IMAGE_MIRROR (offline/mirror.sh)"
  fi
  log "Скачиваем $image"
  docker pull "$image"
}

# Все образы стека по compose config --images. Не для стеков с build.
ensure_stack_images() {
  local stack="$1"; shift
  local image
  while read -r image; do
    [ -n "$image" ] && ensure_image "$image"
  done < <(compose "$stack" "$@" config --images)
}

container_running() {
  [ -n "$(docker ps -q -f "name=^${1}$" 2>/dev/null)" ]
}

# Ждет healthcheck контейнера.
wait_healthy() {
  local name="$1" timeout="$2" deadline status
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
    if [ "$status" = healthy ]; then log "Контейнер $name healthy"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then warn "Контейнер $name не стал healthy за ${timeout}s ($status)"; return 1; fi
    sleep 5
  done
}

# wait_http <url> <таймаут_с> [аргументы curl]: ждет ответ 2xx, 3xx или 401.
wait_http() {
  local url="$1" timeout="$2"; shift 2
  local deadline code
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || true)"
    case "$code" in
      2*|3*|401) log "Отвечает: $url ($code)"; return 0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "Не дождались $url за ${timeout}s (последний код: ${code:-нет ответа})"
      return 1
    fi
    sleep 5
  done
}

# Аргументы curl для доверия нашему корню: свой CA, если он есть, иначе
# системное хранилище (свой корпоративный сертификат).
_ca_args() {
  local ca="$INFRA_ROOT/certs/ca/rootCA.pem"
  if [ -f "$ca" ]; then printf -- '--cacert\n%s\n' "$ca"; fi
}

# curl к нашему nginx по имени сервиса, минуя DNS: имя -> 127.0.0.1.
tls_curl() {
  local host="$1" path="$2"; shift 2
  local caargs=()
  mapfile -t caargs < <(_ca_args)
  curl -sS ${caargs[@]+"${caargs[@]}"} --resolve "$host:443:127.0.0.1" "$@" "https://$host$path"
}

wait_tls() {
  local host="$1" path="$2" timeout="$3"
  local caargs=()
  mapfile -t caargs < <(_ca_args)
  wait_http "https://$host$path" "$timeout" ${caargs[@]+"${caargs[@]}"} --resolve "$host:443:127.0.0.1"
}

# Сеть app-network по NETWORK_DRIVER. Существующую сеть не пересоздает.
ensure_network() {
  local name="${APP_NETWORK:-app-network}" driver="${NETWORK_DRIVER:-bridge}"
  local touch_image="${IMAGE_MIRROR:-}nginx:1.27-alpine"
  local have swarm manager

  if docker network inspect "$name" >/dev/null 2>&1; then
    have="$(docker network inspect -f '{{.Driver}}' "$name")"
    if [ "$have" != "$driver" ]; then
      warn "Сеть $name уже есть с драйвером $have, а в .env NETWORK_DRIVER=$driver. Сеть не пересоздается: если смена нужна, остановите все стеки и удалите ее (docker network rm $name)"
    else
      log "Сеть $name уже есть ($have)"
    fi
    return 0
  fi

  case "$driver" in
    bridge)
      log "Создаем сеть $name (bridge)"
      docker network create "$name" >/dev/null ;;
    overlay)
      swarm="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"
      manager="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)"
      [ "$swarm" = active ] || die "NETWORK_DRIVER=overlay, но docker swarm не активен. На сервере инфры: docker swarm init --advertise-addr <ip>; на остальных: docker swarm join --token <token> <ip-manager>:2377 (токен: docker swarm join-token worker на manager)"
      if [ "$manager" = true ]; then
        log "Создаем overlay-сеть $name (этот узел manager)"
        docker network create -d overlay --attachable "$name" >/dev/null
      else
        log "Узел worker: подтягиваем overlay-сеть $name с manager"
        ensure_image "$touch_image"
        docker run --rm --network "$name" "$touch_image" true \
          || die "Сеть $name недоступна на этом узле. Создайте ее на manager: docker network create -d overlay --attachable $name"
        docker network inspect "$name" >/dev/null 2>&1 || die "Сеть $name не появилась после подключения"
      fi ;;
    *) die "Неизвестный NETWORK_DRIVER=$driver (bridge или overlay)" ;;
  esac
}
