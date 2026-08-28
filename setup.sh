#!/usr/bin/env bash
# Настройка всей инфраструктуры одной командой. Повторно запускаемый:
# каждый шаг сам определяет, что уже сделано.
#
#   ./setup.sh                    все стеки по порядку
#   ./setup.sh --only valhalla    только перечисленные стеки (флаг повторяемый)
#   ./setup.sh --skip valhalla    все, кроме перечисленных (флаг повторяемый)
#   ./setup.sh --skip hosts       не проверять записи hosts на этой машине
#   --dev            keycloak в dev-режиме: свой postgres, без LDAP
#   --wait           valhalla: дождаться первой сборки тайлов, до 2 часов
#   --agent          observability: только Alloy-агент на хосте без основного стека
#   --renew-certs    перевыпустить серверный сертификат
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
LOG_PREFIX=setup

SERVICES=(certs nginx keycloak docker_registry observability valhalla)
ONLY=()
SKIP=()
FLAGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ $# -ge 2 ] || die "--only требует имя стека"; ONLY+=("$2"); shift 2 ;;
    --skip) [ $# -ge 2 ] || die "--skip требует имя стека"; SKIP+=("$2"); shift 2 ;;
    --dev|--wait|--agent|--renew-certs) FLAGS+=("$1"); shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

in_list() {
  local needle="$1" x; shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

has_flag() { in_list "$1" ${FLAGS[@]+"${FLAGS[@]}"}; }

selected() {
  if [ "${#ONLY[@]}" -gt 0 ] && ! in_list "$1" "${ONLY[@]}"; then return 1; fi
  if [ "${#SKIP[@]}" -gt 0 ] && in_list "$1" "${SKIP[@]}"; then return 1; fi
  return 0
}

# Флаги, которые понимает конкретный стек.
flags_for() {
  case "$1" in
    certs)         has_flag --renew-certs && echo "--renew" ;;
    keycloak)      has_flag --dev && echo "--dev" ;;
    observability) has_flag --agent && echo "--agent" ;;
    valhalla)      has_flag --wait && echo "--wait" ;;
  esac
  true
}

# Путь проверки живости по имени переменной HOST_*.
health_path() {
  case "$1" in
    HOST_AUTH) echo /realms/master/.well-known/openid-configuration ;;
    HOST_REGISTRY) echo /v2/ ;;
    HOST_GRAFANA) echo /api/health ;;
    HOST_API) echo /health ;;
    HOST_ROUTE) echo /summer/status ;;
    *) echo / ;;
  esac
}

summary() {
  local var host code
  log "===== Итог ====="
  if container_running infra_nginx; then
    for var in $(compgen -A variable HOST_ | sort); do
      host="${!var}"
      [ -n "$host" ] || continue
      code="$(tls_curl "$host" "$(health_path "$var")" -o /dev/null -w '%{http_code}' --max-time 10 2>/dev/null || true)"
      case "$code" in
        2*|3*|401) log "https://$host  OK ($code)" ;;
        *) warn "https://$host  нет ответа (${code:-ошибка}): сервис на другом хосте или еще не поднят" ;;
      esac
    done
  else
    log "nginx на этом хосте не запущен, проверка HTTPS пропущена"
  fi
  log "Записи DNS или hosts для клиентов (проверка на этой машине: ./hosts.sh):"
  printf '    %s %s\n' "${SERVER_IP:-<ip-сервера>}" "$(host_names | tr '\n' ' ')"
}

require_cmd docker curl openssl
load_root_env
[ -n "${SERVER_IP:-}" ] || die "Заполните SERVER_IP в $ROOT_ENV: IP сервера с nginx"
log "Настройки: $ROOT_ENV (NETWORK_DRIVER=$NETWORK_DRIVER, SERVER_IP=$SERVER_IP, IMAGE_MIRROR='${IMAGE_MIRROR}', OFFLINE=$OFFLINE)"
ensure_network

for svc in "${SERVICES[@]}"; do
  if ! selected "$svc"; then
    log "Пропуск: $svc"
    continue
  fi
  log "===== $svc ====="
  # shellcheck disable=SC2046
  "./$svc/setup.sh" $(flags_for "$svc")
done

summary
if selected hosts; then
  log "===== hosts ====="
  ./hosts.sh || warn "Записи hosts на этой машине не настроены, позже: ./hosts.sh"
fi
