#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

source "${repo}/scripts/lib/logging.sh"
source "${repo}/scripts/lib/filesystem.sh"
source "${repo}/scripts/lib/config_templates.sh"

DATA_DIR="${tmp}/data"
CONFIG_TEMPLATES_ENABLED=true
CONFIG_TEMPLATES_DIR="${tmp}/templates"
CONFIG_TEMPLATES_REPLACE=false
CFG_DB_HOST="db.internal"
CFG_DB_PASSWORD_FILE="${tmp}/password"
CFG_TOKEN='${CFG_TOKEN}'
export DATA_DIR CONFIG_TEMPLATES_ENABLED CONFIG_TEMPLATES_DIR CONFIG_TEMPLATES_REPLACE CFG_DB_HOST CFG_DB_PASSWORD_FILE CFG_TOKEN

mkdir -p "${CONFIG_TEMPLATES_DIR}/nested" "${DATA_DIR}/config"
 # shellcheck disable=SC2016  # Literal template placeholders are the test input.
printf 'host=${CFG_DB_HOST}\npassword=${CFG_DB_PASSWORD}\ntoken=${CFG_TOKEN}\nsentinel=__CONFIG_TEMPLATE_SENTINEL__\nplain=${OTHER}\n' > "${CONFIG_TEMPLATES_DIR}/nested/app.conf"
printf 'secret-value\n' > "${CFG_DB_PASSWORD_FILE}"

activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = 
test "$(cat "${CONFIG_TEMPLATES_DIR}/nested/app.conf")" = 

printf 'operator-owned\n' > "${DATA_DIR}/config/nested/app.conf"
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = operator-owned

CONFIG_TEMPLATES_REPLACE=true
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = $'host=db.internal\npassword=secret-value\nplain=${OTHER}'

 # shellcheck disable=SC2016  # Literal template placeholders are the test input.
printf 'missing=${CFG_REQUIRED}\n' > "${CONFIG_TEMPLATES_DIR}/missing.conf"
before="$(cat "${DATA_DIR}/config/nested/app.conf")"
set +e
output="$(activate_config_templates 2>&1)"
status=$?
set -e
test "${status}" -ne 0
printf '%s\n' "${output}" | grep -F "Config template variable is not set: CFG_REQUIRED"
test ! -e "${DATA_DIR}/config/missing.conf"
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = "${before}"

printf 'config templates smoke passed\n'
host=db.internal\npassword=secret-value\ntoken=${CFG_TOKEN}\nsentinel=__CONFIG_TEMPLATE_SENTINEL__\nplain=${OTHER}'
test "$(cat "${CONFIG_TEMPLATES_DIR}/nested/app.conf")" = $'host=${CFG_DB_HOST}\npassword=${CFG_DB_PASSWORD}\nplain=${OTHER}'

printf 'operator-owned\n' > "${DATA_DIR}/config/nested/app.conf"
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = operator-owned

CONFIG_TEMPLATES_REPLACE=true
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = $'host=db.internal\npassword=secret-value\nplain=${OTHER}'

 # shellcheck disable=SC2016  # Literal template placeholders are the test input.
printf 'missing=${CFG_REQUIRED}\n' > "${CONFIG_TEMPLATES_DIR}/missing.conf"
before="$(cat "${DATA_DIR}/config/nested/app.conf")"
set +e
output="$(activate_config_templates 2>&1)"
status=$?
set -e
test "${status}" -ne 0
printf '%s\n' "${output}" | grep -F "Config template variable is not set: CFG_REQUIRED"
test ! -e "${DATA_DIR}/config/missing.conf"
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = "${before}"

printf 'config templates smoke passed\n'
host=${CFG_DB_HOST}\npassword=${CFG_DB_PASSWORD}\ntoken=${CFG_TOKEN}\nsentinel=__CONFIG_TEMPLATE_SENTINEL__\nplain=${OTHER}'

printf 'operator-owned\n' > "${DATA_DIR}/config/nested/app.conf"
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = operator-owned

CONFIG_TEMPLATES_REPLACE=true
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = $'host=db.internal\npassword=secret-value\nplain=${OTHER}'

 # shellcheck disable=SC2016  # Literal template placeholders are the test input.
printf 'missing=${CFG_REQUIRED}\n' > "${CONFIG_TEMPLATES_DIR}/missing.conf"
before="$(cat "${DATA_DIR}/config/nested/app.conf")"
set +e
output="$(activate_config_templates 2>&1)"
status=$?
set -e
test "${status}" -ne 0
printf '%s\n' "${output}" | grep -F "Config template variable is not set: CFG_REQUIRED"
test ! -e "${DATA_DIR}/config/missing.conf"
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = "${before}"

printf 'config templates smoke passed\n'
host=db.internal\npassword=secret-value\ntoken=${CFG_TOKEN}\nsentinel=__CONFIG_TEMPLATE_SENTINEL__\nplain=${OTHER}'
test "$(cat "${CONFIG_TEMPLATES_DIR}/nested/app.conf")" = $'host=${CFG_DB_HOST}\npassword=${CFG_DB_PASSWORD}\nplain=${OTHER}'

printf 'operator-owned\n' > "${DATA_DIR}/config/nested/app.conf"
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = operator-owned

CONFIG_TEMPLATES_REPLACE=true
activate_config_templates
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = $'host=db.internal\npassword=secret-value\nplain=${OTHER}'

 # shellcheck disable=SC2016  # Literal template placeholders are the test input.
printf 'missing=${CFG_REQUIRED}\n' > "${CONFIG_TEMPLATES_DIR}/missing.conf"
before="$(cat "${DATA_DIR}/config/nested/app.conf")"
set +e
output="$(activate_config_templates 2>&1)"
status=$?
set -e
test "${status}" -ne 0
printf '%s\n' "${output}" | grep -F "Config template variable is not set: CFG_REQUIRED"
test ! -e "${DATA_DIR}/config/missing.conf"
test "$(cat "${DATA_DIR}/config/nested/app.conf")" = "${before}"

printf 'config templates smoke passed\n'
