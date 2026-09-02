# shellcheck shell=bash

MODRINTH_API_BASE="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"

modrinth_validate_identifier() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

modrinth_list_project_versions() {
  local project="$1"
  local game_version="$2"
  local loader="$3"

  modrinth_validate_identifier "$project" \
    || die "Invalid Modrinth project identifier: ${project}"
  [[ -n "$game_version" ]] || die "Minecraft version is required for Modrinth resolution"
  [[ -n "$loader" ]] || die "Loader is required for Modrinth resolution"
  command -v curl >/dev/null 2>&1 || die "curl is required for Modrinth API access"

  curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 60 \
    --get \
    --data-urlencode "loaders=[\"${loader}\"]" \
    --data-urlencode "game_versions=[\"${game_version}\"]" \
    --data-urlencode "include_changelog=false" \
    -- "${MODRINTH_API_BASE}/project/${project}/version"
}

modrinth_select_project_version() {
  local versions_json="$1"
  local requested="${2:-latest-compatible}"

  jq -ce --arg requested "$requested" '
    if type != "array" then
      error("Modrinth versions response is not an array")
    elif $requested == "latest-compatible" or $requested == "latest" then
      map(select(.status == "listed" or .status == null))
      | sort_by(.date_published // "")
      | reverse
      | .[0] // error("no compatible listed Modrinth version")
    else
      map(select(.id == $requested or .version_number == $requested))
      | sort_by(.date_published // "")
      | reverse
      | .[0] // error("requested Modrinth version not found")
    end
  ' <<< "$versions_json"
}

modrinth_select_primary_jar_file() {
  local version_json="$1"

  jq -ce '
    (.files // []) as $files
    | ([ $files[] | select(.primary == true and (.filename | endswith(".jar"))) ][0]
       // [ $files[] | select(.filename | endswith(".jar")) ][0]
       // error("Modrinth version has no JAR file"))
    | select(.url | type == "string")
    | select(.filename | type == "string")
    | select(.hashes.sha512 | type == "string" and length > 0)
  ' <<< "$version_json"
}

modrinth_download_verified_file() {
  local file_json="$1"
  local out="$2"
  local url filename sha512 tmp

  url="$(jq -er '.url' <<< "$file_json")"
  filename="$(jq -er '.filename' <<< "$file_json")"
  sha512="$(jq -er '.hashes.sha512' <<< "$file_json")"

  case "$url" in
    https://cdn.modrinth.com/*) ;;
    *) die "Refusing non-Modrinth CDN download URL for ${filename}" ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl is required for Modrinth downloads"
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "$(dirname "$out")/.modrinth-download.XXXXXX")"

  if ! curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 300 \
    --output "$tmp" \
    -- "$url"; then
    rm -f -- "$tmp"
    die "Failed to download Modrinth file: ${filename}"
  fi

  if ! echo "${sha512}  ${tmp}" | sha512sum -c - >/dev/null 2>&1; then
    rm -f -- "$tmp"
    die "SHA512 mismatch for Modrinth file: ${filename}"
  fi

  mv -f -- "$tmp" "$out"
}
