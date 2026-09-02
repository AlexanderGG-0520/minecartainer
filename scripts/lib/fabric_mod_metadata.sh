# shellcheck shell=bash

fabric_mod_metadata_json() {
  local jar="$1"

  [[ -f "$jar" ]] || return 1
  command -v unzip >/dev/null 2>&1 || return 1

  unzip -p "$jar" fabric.mod.json 2>/dev/null
}

fabric_mod_id() {
  local jar="$1"

  fabric_mod_metadata_json "$jar" | jq -er '.id | strings | select(length > 0)' 2>/dev/null
}

fabric_mod_version() {
  local jar="$1"

  fabric_mod_metadata_json "$jar" | jq -er '.version | strings | select(length > 0)' 2>/dev/null
}

list_fabric_mods_by_id() {
  local wanted_id="$1"
  local jar mod_id
  local -a jars=()

  [[ -n "$wanted_id" ]] || return 1

  shopt -s nullglob
  jars=("${DATA_DIR}/mods/"*.jar)
  shopt -u nullglob

  for jar in "${jars[@]}"; do
    mod_id="$(fabric_mod_id "$jar" 2>/dev/null || true)"
    [[ "$mod_id" == "$wanted_id" ]] || continue
    printf '%s\n' "$jar"
  done
}

find_fabric_mod_by_id() {
  local wanted_id="$1"
  local jar

  while IFS= read -r jar; do
    [[ -n "$jar" ]] || continue
    printf '%s\n' "$jar"
    return 0
  done < <(list_fabric_mods_by_id "$wanted_id")

  return 1
}

has_fabric_mod_id() {
  find_fabric_mod_by_id "$1" >/dev/null
}
