# shellcheck shell=bash

config_template_value() {
  local name="$1" file_name="${1}_FILE" value_file
  if [[ -v "$file_name" && -n "${!file_name}" ]]; then
    value_file="${!file_name}"
    [[ -f "$value_file" && -r "$value_file" ]] || { log ERROR "$file_name must reference a readable regular file"; return 1; }
    CONFIG_TEMPLATE_VALUE="$(<"$value_file")"
  elif [[ -v "$name" ]]; then
    CONFIG_TEMPLATE_VALUE="${!name}"
  else
    log ERROR "Config template variable is not set: $name"; return 1
  fi
  [[ "$CONFIG_TEMPLATE_VALUE" != *$'\n'* && "$CONFIG_TEMPLATE_VALUE" != *$'\r'* && "$CONFIG_TEMPLATE_VALUE" != *$'\034'* ]] || { log ERROR "$name must not contain a newline, carriage return, or unit separator"; return 1; }
}

render_config_template() {
  local source="$1" output="$2" stage="$3" map token name
  local -a tokens=()
  [[ ! -s "$source" ]] || grep -Iq . -- "$source" || { log ERROR "Config template must be text: $source"; return 1; }
  mapfile -t tokens < <(LC_ALL=C grep -ahoE '\$\{CFG_[A-Za-z_][A-Za-z0-9_]*\}' -- "$source" | sort -u || true)
  map="$(mktemp "$stage/.config-template-values.XXXXXX")" || return 1
  chmod 600 -- "$map" || { safe_rm_f "$map"; return 1; }
  # The sentinel makes an empty map unambiguous without becoming a replacement token.
  printf "__CONFIG_TEMPLATE_SENTINEL__\034\n" > "$map"
  for token in "${tokens[@]}"; do
    name="${token#\$\{}"; name="${name%\}}"
    config_template_value "$name" || { safe_rm_f "$map"; return 1; }
    printf "%s\034%s\n" "$token" "$CONFIG_TEMPLATE_VALUE" >> "$map"
  done
  awk -F $'\034' '
    NR == FNR {
      if ($1 != "__CONFIG_TEMPLATE_SENTINEL__") v[$1] = substr($0, index($0, FS) + 1)
      next
    }
    {
      line = $0
      for (token in v) {
        result = ""; offset = 1
        while ((position = index(substr(line, offset), token)) != 0) {
          position += offset - 1
          result = result substr(line, offset, position - offset) v[token]
          offset = position + length(token)
        }
        line = result substr(line, offset)
      }
      print line
    }
  ' "$map" "$source" > "$output" || { safe_rm_f "$map"; return 1; }
  safe_rm_f "$map"
}

activate_config_templates() {
  [[ "${CONFIG_TEMPLATES_ENABLED:-false}" == true ]] || return 0
  local source="${CONFIG_TEMPLATES_DIR:-/config-templates}" root="${DATA_DIR}/config"
  local source_real root_real stage files links file rel rendered target parent parent_real tmp
  local -a paths=()
  [[ -d "$source" && -r "$source" && -x "$source" ]] || { log ERROR "CONFIG_TEMPLATES_DIR must be a readable directory: $source"; return 1; }
  command -v realpath >/dev/null 2>&1 || { log ERROR "realpath is required for config template activation"; return 1; }
  source_real="$(realpath -e -- "$source")" || return 1; root_real="$(realpath -m -- "$root")" || return 1
  [[ "$source_real" != "$root_real" && "$source_real" != "$root_real/"* && "$root_real" != "$source_real/"* ]] || { log ERROR "CONFIG_TEMPLATES_DIR must not overlap /data/config"; return 1; }
  stage="$(mktemp -d)" || return 1; chmod 700 -- "$stage" || { safe_rm_rf "$stage"; return 1; }
  links="$stage/.links"; files="$stage/.files"
  if ! find "$source_real" -type l -print0 > "$links"; then
    log ERROR "Failed to inspect config template directory for symbolic links"; safe_rm_rf "$stage"; return 1
  fi
  [[ ! -s "$links" ]] || { log ERROR "CONFIG_TEMPLATES_DIR must not contain symbolic links"; safe_rm_rf "$stage"; return 1; }
  if ! find "$source_real" -type f -print0 > "$files"; then
    log ERROR "Failed to enumerate config template files"; safe_rm_rf "$stage"; return 1
  fi
  while IFS= read -r -d "" file; do
    rel="${file#"$source_real"/}"; rendered="$stage/$rel"
    if ! mkdir -p -- "$(dirname -- "$rendered")" || ! render_config_template "$file" "$rendered" "$stage"; then
      safe_rm_rf "$stage"; return 1
    fi
    paths+=("$rel")
  done < "$files"
  (( ${#paths[@]} > 0 )) || { safe_rm_rf "$stage"; log INFO "Config template directory is empty ($source_real), skipping activation"; return 0; }
  for rel in "${paths[@]}"; do
    target="$root/$rel"; parent="$(dirname -- "$target")"; parent_real="$(realpath -m -- "$parent")" || { safe_rm_rf "$stage"; return 1; }
    [[ "$parent_real" == "$root_real" || "$parent_real" == "$root_real/"* ]] || { log ERROR "Refusing config template destination outside /data/config: $rel"; safe_rm_rf "$stage"; return 1; }
    [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || { log ERROR "Config template destination must be absent or a regular file: $target"; safe_rm_rf "$stage"; return 1; }
  done
  for rel in "${paths[@]}"; do
    target="$root/$rel"; [[ ! -e "$target" || "${CONFIG_TEMPLATES_REPLACE:-false}" == true ]] || { log INFO "Preserving existing config template destination: $target"; continue; }
    parent="$(dirname -- "$target")"; mkdir -p -- "$parent" || { safe_rm_rf "$stage"; return 1; }
    tmp="$(mktemp "$parent/.$(basename -- "$target").template.XXXXXX")" || { safe_rm_rf "$stage"; return 1; }
    if ! cp -- "$stage/$rel" "$tmp" || ! safe_mv_f "$tmp" "$target"; then
      safe_rm_f "$tmp" || true; safe_rm_rf "$stage"; return 1
    fi
    log INFO "Rendered config template: $rel"
  done
  safe_rm_rf "$stage"
}
