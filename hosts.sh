#!/usr/bin/env bash
# Записи hosts для имен сервисов (HOST_* из .env) на этой машине: проверка
# и настройка. Сначала имена проверяются через системный резолвер, поэтому
# там, где они уже есть во внутреннем DNS, hosts не трогается.
#   ./hosts.sh            проверить; если имена не ведут на нужный IP, предложить записать
#   ./hosts.sh --check    только проверка, код 1 при расхождении
#   ./hosts.sh --write    записать без вопросов (Linux: sudo, Windows: окно UAC)
#   ./hosts.sh --manual   показать строку для ручной правки и перепроверять по Enter
# IP для записей: HOSTS_IP из .env, иначе SERVER_IP. На машине, где nginx
# запущен локально (dev), HOSTS_IP=127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
LOG_PREFIX=hosts

MODE=ask
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --write) MODE=write ;;
  --manual) MODE=manual ;;
  *) die "Неизвестный аргумент: $1" ;;
esac

load_root_env
IP="${HOSTS_IP:-${SERVER_IP:-}}"
[ -n "$IP" ] || die "Задайте SERVER_IP или HOSTS_IP в $ROOT_ENV"
mapfile -t HOSTS < <(host_names)
[ "${#HOSTS[@]}" -gt 0 ] || die "В $ROOT_ENV нет переменных HOST_*"
LINE="$IP ${HOSTS[*]}"
MARK="# infra_mks"

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

if is_windows; then
  FILE="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/drivers/etc/hosts"
else
  FILE=/etc/hosts
fi

# Все адреса, куда имя ведет для системы: hosts и DNS вместе.
resolved_ips() {
  if is_windows; then
    powershell.exe -NoProfile -Command \
      "try { [System.Net.Dns]::GetHostAddresses('$1') | ForEach-Object { \$_.IPAddressToString } } catch {}" 2>/dev/null | tr -d '\r'
  else
    getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

MISSING=()
check_all() {
  local host got
  MISSING=()
  for host in "${HOSTS[@]}"; do
    if resolved_ips "$host" | grep -qx "$IP"; then
      log "$host -> $IP"
    else
      got="$(resolved_ips "$host" | tr '\n' ' ')"
      warn "$host -> ${got:-не резолвится}, нужно $IP"
      MISSING+=("$host")
    fi
  done
  [ "${#MISSING[@]}" -eq 0 ]
}

show_manual() {
  cat <<EOF
Добавьте в $FILE (от администратора или через sudo) строку:
    $LINE
Строки с этими именами на другой IP удалите: побеждает первая запись.
EOF
}

# Строки с нашими именами заменяются целиком, остальное не трогается.
write_linux() {
  local re tmp
  re="^($(printf '%s|' "${HOSTS[@]}" | sed -e 's/\./\\./g' -e 's/|$//'))$"
  tmp="$(mktemp)"
  awk -v re="$re" '
    NF == 0 || /^[[:space:]]*#/ { print; next }
    { for (i = 2; i <= NF; i++) if ($i ~ re) next; print }
  ' "$FILE" > "$tmp"
  printf '%s %s\n' "$LINE" "$MARK" >> "$tmp"
  if [ "$(id -u)" = 0 ]; then
    cp "$tmp" "$FILE"
  else
    log "Нужны права root, запрашиваем sudo"
    sudo cp "$tmp" "$FILE"
  fi
  rm -f "$tmp"
}

write_windows() {
  local ps1 ps1win names
  names="$(printf "'%s'," "${HOSTS[@]}")"
  names="${names%,}"
  ps1="$(mktemp --suffix=.ps1)"
  ps1win="$(cygpath -w "$ps1")"
  cat > "$ps1" <<EOF
\$ErrorActionPreference = 'Stop'
\$file = Join-Path \$env:SystemRoot 'System32\\drivers\\etc\\hosts'
\$names = @($names)
\$re = '(^|\\s)(' + ((\$names | ForEach-Object { [regex]::Escape(\$_) }) -join '|') + ')(\\s|$)'
\$kept = @(Get-Content -Path \$file | Where-Object { (\$_ -match '^\\s*#') -or (\$_.Trim() -eq '') -or (\$_ -notmatch \$re) })
\$kept += '$LINE $MARK'
Set-Content -Path \$file -Value \$kept -Encoding UTF8
ipconfig /flushdns | Out-Null
EOF
  log "Нужны права администратора: подтвердите окно UAC"
  powershell.exe -NoProfile -Command \
    "Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"$ps1win\"'" \
    || { rm -f "$ps1"; show_manual; die "Права администратора не получены, hosts не изменен"; }
  rm -f "$ps1"
}

if check_all; then
  log "Все имена ведут на $IP, hosts менять не нужно"
  exit 0
fi

if [ "$MODE" = check ]; then
  show_manual
  exit 1
fi

if [ "$MODE" = ask ]; then
  if [ -t 0 ]; then
    printf 'Записать в %s автоматически? [y/N] ' "$FILE"
    read -r answer
    case "$answer" in
      y|Y|д|Д) MODE=write ;;
      *) MODE=manual ;;
    esac
  else
    show_manual
    warn "Терминал неинтерактивный, hosts не изменен: ./hosts.sh --write или правка вручную"
    exit 1
  fi
fi

if [ "$MODE" = write ]; then
  if is_windows; then write_windows; else write_linux; fi
  log "Записано в $FILE: $LINE"
  check_all || die "После записи имена все еще не ведут на $IP: проверьте $FILE и кэш DNS"
  exit 0
fi

show_manual
[ -t 0 ] || exit 1
while :; do
  printf 'Нажмите Enter после правки для повторной проверки (q для выхода): '
  read -r answer
  [ "$answer" = q ] && exit 1
  check_all && { log "Все имена ведут на $IP"; exit 0; }
done
