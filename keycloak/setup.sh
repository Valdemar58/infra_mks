#!/usr/bin/env bash
# Keycloak за nginx (HOST_AUTH). Прод: внешний Postgres из .env.
# Dev: --dev, свой postgres и пользователь admin_dev без LDAP.
#   ./setup.sh [--dev]
set -euo pipefail
cd "$(dirname "$0")"
. ../lib.sh
LOG_PREFIX=keycloak

load_root_env
DEV=0
[ "${1:-}" = "--dev" ] && DEV=1

post_import_hint() {
  cat <<EOF
Секреты не хранятся в realm-export.json и ставятся после первого импорта
(повторный импорт существующий realm не меняет):
  docker exec -it keycloak kcadm.sh config credentials --server http://localhost:8080 --realm master \\
      --user \$KC_BOOTSTRAP_ADMIN_USERNAME --password \$KC_BOOTSTRAP_ADMIN_PASSWORD
  docker exec -it keycloak kcadm.sh get components -r master -q type=org.keycloak.storage.UserStorageProvider
  docker exec -it keycloak kcadm.sh update components/<id> -r master \\
      -s 'config.connectionUrl=["ldap://<контроллер домена>"]' \\
      -s 'config.usersDn=["<base DN, например dc=example,dc=local>"]' \\
      -s 'config.bindDn=["<домен>\\<учетная запись для чтения AD>"]' \\
      -s 'config.bindCredential=["<пароль этой учетной записи>"]'
  docker exec -it keycloak kcadm.sh get clients -r master -q clientId=streamlit --fields id
  docker exec -it keycloak kcadm.sh update clients/<id> -r master -s secret=<CLIENT_STREAMLIT_SECRET приложения>
  docker exec -it keycloak kcadm.sh update clients/<id> -r master \\
      -s 'redirectUris=["https://${HOST_UI:-appsrvs}/oauth2callback","http://localhost:8515/oauth2callback"]'
Тема входа с логотипом МКС для realm, импортированного до ее включения:
  docker exec -it keycloak kcadm.sh update realms/master -s loginTheme=mks
EOF
}

if [ "$DEV" = 1 ]; then
  export COMPOSE_FILE_NAME=docker-compose.dev.yml
  ensure_stack_images keycloak
  compose keycloak up -d $(pull_flag)
  wait_http http://127.0.0.1:8080/realms/master/.well-known/openid-configuration 180 \
    || die "Keycloak не поднялся: docker logs keycloak-dev"
  log "Dev Keycloak: http://localhost:8080, пользователь admin_dev/admin_dev, админка admin/admin"
  exit 0
fi

ensure_env_file . KC_DB_URL KC_DB_USERNAME KC_DB_PASSWORD KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD
ensure_stack_images keycloak
compose keycloak up -d $(pull_flag)
if container_running infra_nginx; then
  wait_tls "$HOST_AUTH" /realms/master/.well-known/openid-configuration 180 \
    || warn "Keycloak не отвечает через nginx: docker logs keycloak"
else
  warn "nginx на этом хосте не запущен, доступность Keycloak снаружи не проверена"
fi
post_import_hint
