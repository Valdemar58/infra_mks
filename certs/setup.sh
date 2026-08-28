#!/usr/bin/env bash
# Сертификаты для nginx: серверный сертификат (выпуск и продление) от
# корневого CA, проверка. Корень никогда не создается сам: без ca/rootCA.pem
# и ca/rootCA.key скрипт останавливается и объясняет, что положить.
# Существующие файлы не перезаписываются без явного флага. При продлении
# корень не меняется, раздавать его клиентам заново не нужно.
#
#   ./setup.sh                   выпустить или продлить сертификат от имеющегося корня, DER-копия корня
#   ./setup.sh --check           только отчет; код 1, если есть замечания
#   ./setup.sh --renew           перевыпустить серверный сертификат (SAN из корневого .env)
#   ./setup.sh --renew --new-key то же с новым приватным ключом сервера
#   ./setup.sh --init-ca         создать корневой CA, если его нет (есть: ничего не делает)
#   ./setup.sh --init-ca --force ЗАМЕНИТЬ корневой CA: всем клиентам придется доверять ему заново
#
# Перенос существующего корня: скопировать ca/rootCA.pem и ca/rootCA.key
# сюда и запустить скрипт. Свой сертификат вместо самоподписанного:
# fullchain.pem (только серверный, без корня) и server.key без каталога ca/,
# скрипт тогда только проверяет их.
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=certs

CHECK=0 RENEW=0 NEW_KEY=0 INIT_CA=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --renew) RENEW=1 ;;
    --new-key) NEW_KEY=1 ;;
    --init-ca) INIT_CA=1 ;;
    --force) FORCE=1 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
  shift
done

require_cmd openssl
load_root_env
CA_DAYS="${CERT_CA_DAYS:-3650}"
LEAF_DAYS="${CERT_LEAF_DAYS:-825}"
RENEW_BEFORE_DAYS=30

CA_KEY=ca/rootCA.key
CA_PEM=ca/rootCA.pem
CA_DER=ca/rootCA.crt
CA_CNF=ca/ca.cnf
LEAF_CNF=ca/leaf_ext.cnf
CSR=ca/server.csr
SRL=ca/rootCA.srl
LEAF=fullchain.pem
KEY=server.key

# Имена для SAN: все HOST_* из корневого .env и IP сервера.
mapfile -t HOSTS < <(host_names)
[ "${#HOSTS[@]}" -gt 0 ] || die "В $ROOT_ENV нет ни одной переменной HOST_*"
SAN="$(printf 'DNS:%s,' "${HOSTS[@]}")"
[ -n "${SERVER_IP:-}" ] && SAN="${SAN}IP:${SERVER_IP},"
SAN="${SAN%,}"
CN="${HOST_UI:-${HOSTS[0]}}"

have_ca()   { [ -f "$CA_KEY" ] && [ -f "$CA_PEM" ]; }
have_leaf() { [ -f "$LEAF" ] && [ -f "$KEY" ]; }

cert_end() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }
cert_san() { openssl x509 -in "$1" -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' '; }

# Истекает ли сертификат в ближайшие N дней.
expires_within() { ! openssl x509 -in "$1" -noout -checkend "$(( $2 * 86400 ))" >/dev/null; }

key_matches() {
  [ "$(openssl x509 -in "$LEAF" -noout -modulus | openssl md5)" = \
    "$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | openssl md5)" ]
}

signed_by_ca() { openssl verify -CAfile "$CA_PEM" "$LEAF" >/dev/null 2>&1; }

san_covers_all() {
  local san=",$1," host
  for host in "${HOSTS[@]}"; do
    case "$san" in *",DNS:$host,"*) ;; *) return 1 ;; esac
  done
  if [ -n "${SERVER_IP:-}" ]; then
    case "$san" in *",IPAddress:$SERVER_IP,"*) ;; *) return 1 ;; esac
  fi
  return 0
}

export_der() { openssl x509 -in "$CA_PEM" -outform DER -out "$CA_DER"; }

# DER-копия должна соответствовать текущему корню, а не прошлому.
ensure_der() {
  local want have=""
  want="$(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha256)"
  if [ -f "$CA_DER" ]; then
    have="$(openssl x509 -in "$CA_DER" -inform DER -noout -fingerprint -sha256 2>/dev/null || true)"
  fi
  if [ "$want" != "$have" ]; then
    export_der
    log "DER-копия корня обновлена: $CA_DER"
  fi
}

no_certs_hint() {
  cat <<EOF
В $PWD нет ни корневого CA, ни серверного сертификата. Корень автоматически
не создается, чтобы не подменить уже розданный клиентам. Варианты:
  1. Корень уже есть (старый сервер, бэкап): скопируйте ca/rootCA.pem и ca/rootCA.key
     в $PWD/ca/ и запустите снова, серверный сертификат выпустится от него.
  2. Есть готовый серверный сертификат: положите fullchain.pem (только серверный,
     без корня) и server.key в $PWD без каталога ca/.
  3. Корня нет нигде: ./certs/setup.sh --init-ca (или ./setup.sh --init-ca) создаст
     новый, его придется добавить в доверенные на всех клиентах.
EOF
}

distribution_hint() {
  cat <<EOF
Корень ($CA_DER, он же $CA_PEM) должны знать все, кто ходит на https://<имена из .env>:
  Windows:   certutil -addstore -f Root rootCA.crt   (от администратора)
  KES:       Настройки -> Общие настройки -> Сетевые настройки -> Проверка защищенных
             соединений -> Показать сертификаты -> Доверенные корневые сертификаты -> Добавить
             (или централизованно политикой Kaspersky Security Center)
  Docker на серверах, которые делают pull из registry:
             /etc/docker/certs.d/${HOST_REGISTRY:-appsrvs.registry}/ca.crt  (содержимое rootCA.pem)
  CI runner и приложение: rootCA.pem в их CA-бандл (HOST_CUSTOM_CA_PATH приложения)
EOF
}

init_ca() {
  local expected answer
  if have_ca; then
    if [ "$FORCE" != 1 ]; then
      log "Корневой CA уже есть, оставляем (замена только через --init-ca --force)"
      return 0
    fi
    expected="$(openssl x509 -in "$CA_PEM" -noout -subject | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | sed 's/ *$//')"
    warn "Замена корневого CA: все клиенты (Windows, KES, CI, docker на серверах, бандл CA приложения) должны будут доверять новому корню заново"
    printf 'Для подтверждения введите CN текущего корня (%s): ' "$expected"
    read -r answer
    [ "$answer" = "$expected" ] || die "Отменено"
    rm -f "$CA_KEY" "$CA_PEM" "$CA_DER" "$SRL"
  fi
  log "Создаем корневой CA на $CA_DAYS дней (RSA 4096, SHA-256, расширения из $CA_CNF)"
  mkdir -p ca
  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  chmod 600 "$CA_KEY" 2>/dev/null || true
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -out "$CA_PEM" -config "$CA_CNF" -extensions v3_ca
  export_der
  log "Корневой CA создан: $CA_PEM, DER-копия для Windows и KES: $CA_DER"
  log "Отпечаток SHA-256: $(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha256 | cut -d= -f2)"
  distribution_hint
}

# Расширения серверного сертификата: генерируются из .env, чтобы имена
# сервисов жили в одном месте.
render_leaf_cnf() {
  cat > "$LEAF_CNF" <<EOF
# Генерируется certs/setup.sh из корневого .env, вручную не править.
[ req ]
distinguished_name = dn
prompt             = no

[ dn ]
CN = $CN
O  = $(sed -n 's/^O *= *//p' "$CA_CNF" | head -1)

[ leaf_ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = $SAN
EOF
}

issue_leaf() {
  have_ca || die "Нет корневого CA для подписи"
  render_leaf_cnf
  if [ ! -f "$KEY" ] || [ "$NEW_KEY" = 1 ]; then
    log "Создаем ключ сервера (RSA 2048)"
    openssl genrsa -out "$KEY" 2048 2>/dev/null
    chmod 600 "$KEY" 2>/dev/null || true
  fi
  log "Выпускаем серверный сертификат на $LEAF_DAYS дней: CN=$CN, SAN=$SAN"
  openssl req -new -key "$KEY" -out "$CSR" -config "$LEAF_CNF"
  openssl x509 -req -in "$CSR" -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$LEAF" -days "$LEAF_DAYS" -sha256 -extfile "$LEAF_CNF" -extensions leaf_ext 2>/dev/null
  rm -f "$CSR" "$SRL"
  signed_by_ca || die "Выпущенный сертификат не проходит проверку корнем"
  key_matches || die "Ключ и сертификат не совпадают"
  log "Готово: $LEAF содержит только серверный сертификат, корень клиенты получают отдельно"
  if container_running infra_nginx; then
    docker exec infra_nginx nginx -s reload && log "nginx перечитал сертификат"
  fi
}

report() {
  local status=0 san
  if have_ca; then
    log "Корневой CA: $(openssl x509 -in "$CA_PEM" -noout -subject | sed 's/^subject=//'), действует до $(cert_end "$CA_PEM")"
    log "Отпечаток SHA-256: $(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha256 | cut -d= -f2)"
  else
    log "Корневого CA нет: свой сертификат или еще не создан"
  fi
  if have_leaf; then
    san="$(cert_san "$LEAF")"
    log "Серверный сертификат действует до $(cert_end "$LEAF")"
    log "SAN: $san"
    key_matches || { warn "server.key не соответствует fullchain.pem"; status=1; }
    san_covers_all "$san" || { warn "В SAN нет части имен из .env, нужен перевыпуск: ./setup.sh --renew"; status=1; }
    if expires_within "$LEAF" "$RENEW_BEFORE_DAYS"; then
      warn "Сертификат истекает раньше чем через $RENEW_BEFORE_DAYS дней"; status=1
    fi
    if have_ca && ! signed_by_ca; then warn "fullchain.pem подписан не текущим корнем"; status=1; fi
  else
    log "Серверного сертификата нет"; status=1
  fi
  return $status
}

if [ "$CHECK" = 1 ]; then
  report
  exit $?
fi

if have_leaf && ! have_ca; then
  log "Свой сертификат без ca/: только проверка"
  report || die "Сертификат не проходит проверку, см. выше"
  exit 0
fi

if [ "$INIT_CA" = 1 ]; then
  init_ca
elif ! have_ca; then
  if [ -f "$CA_PEM" ] || [ -f "$CA_KEY" ]; then
    die "В ca/ есть только часть корня: нужны и rootCA.pem, и rootCA.key"
  fi
  no_certs_hint
  die "Нет сертификатов, ничего не создано"
fi
ensure_der

need_issue=0
if ! have_leaf; then
  need_issue=1; log "Серверного сертификата нет, выпускаем"
elif [ "$RENEW" = 1 ]; then
  need_issue=1; log "Перевыпуск по запросу"
elif ! signed_by_ca; then
  need_issue=1; log "Сертификат подписан не текущим корнем, перевыпускаем"
elif ! san_covers_all "$(cert_san "$LEAF")"; then
  need_issue=1; log "В SAN нет части имен из .env, перевыпускаем"
elif expires_within "$LEAF" "$RENEW_BEFORE_DAYS"; then
  need_issue=1; log "Сертификат скоро истекает, продлеваем"
elif ! key_matches; then
  need_issue=1; log "Ключ не соответствует сертификату, перевыпускаем"
fi
[ "$need_issue" = 1 ] && issue_leaf

report || warn "Есть замечания, см. выше"
