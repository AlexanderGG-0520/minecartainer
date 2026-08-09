# shellcheck shell=bash

s3_endpoint_url() {
  printf '%s' "${S3_ENDPOINT_URL:-${S3_ENDPOINT:-}}"
}

s3_endpoint_args() {
  local endpoint
  endpoint="$(s3_endpoint_url)"
  [[ -z "${endpoint}" ]] || printf '%s\0%s\0' "--endpoint-url" "${endpoint}"
}

s3_uri() {
  local src="$1"

  case "${src}" in
    s3://*) printf '%s' "${src}" ;;
    s3/*) printf 's3://%s' "${src#s3/}" ;;
    *) printf '%s' "${src}" ;;
  esac
}

s3_parse_uri() {
  local src="$1"
  local uri bucket key

  uri="$(s3_uri "${src}")"
  case "${uri}" in
    s3://*) ;;
    *) return 1 ;;
  esac

  bucket="${uri#s3://}"
  key="${bucket#*/}"
  bucket="${bucket%%/*}"
  if [[ "${key}" == "${bucket}" ]]; then
    key=""
  fi

  [[ -n "${bucket}" ]] || return 1
  printf '%s\n%s\n' "${bucket}" "${key}"
}

s3_prepare_env() {
  local feature="$1"

  command -v aws >/dev/null 2>&1 || die "aws CLI is required for ${feature}"

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    if [[ -n "${S3_ACCESS_KEY_ID:-}" ]]; then
      export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
    elif [[ -n "${S3_ACCESS_KEY:-}" ]]; then
      export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
    fi
  fi

  if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    if [[ -n "${S3_SECRET_ACCESS_KEY:-}" ]]; then
      export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
    elif [[ -n "${S3_SECRET_KEY:-}" ]]; then
      export AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}"
    fi
  fi

  if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
    export AWS_DEFAULT_REGION="${AWS_REGION:-${S3_REGION:-us-east-1}}"
  fi
  if [[ -z "${AWS_REGION:-}" ]]; then
    export AWS_REGION="${AWS_DEFAULT_REGION}"
  fi

  if [[ -n "$(s3_endpoint_url)" ]]; then
    # Custom S3 endpoints are not guaranteed to implement every optional
    # checksum extension that the AWS CLI enables for Amazon S3. Keep these
    # values deterministic even when the surrounding environment or AWS config
    # requests the broader when_supported behavior.
    export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
    export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"
  fi

  export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"
}

configure_s3_client() {
  s3_prepare_env "$1"
}

s3_aws() {
  local -a endpoint_args=()
  local arg

  while IFS= read -r -d '' arg; do
    endpoint_args+=("${arg}")
  done < <(s3_endpoint_args)

  aws "${endpoint_args[@]}" "$@"
}

s3api_get_object() {
  local bucket="$1"
  local key="$2"
  local dst="$3"

  s3_aws s3api get-object --bucket "${bucket}" --key "${key}" "${dst}" >/dev/null
}

s3_cp() {
  local src="$1"
  local dst="$2"
  local -a parsed=()
  shift 2

  if [[ -n "$(s3_endpoint_url)" ]] \
    && [[ "$(s3_uri "${src}")" == s3://* ]] \
    && [[ "$(s3_uri "${dst}")" != s3://* ]] \
    && [[ "$#" -eq 0 ]]; then
    mapfile -t parsed < <(s3_parse_uri "${src}") || return 1
    [[ "${#parsed[@]}" -eq 2 ]] || return 1
    s3api_get_object "${parsed[0]}" "${parsed[1]}" "${dst}"
    return
  fi

  s3_aws s3 cp "$(s3_uri "${src}")" "$(s3_uri "${dst}")" "$@"
}

s3_compatible_download_sync() {
  local src="$1"
  local dst="$2"
  local remove_extra="$3"
  local -a parsed=()
  local bucket prefix list_prefix listing remote_rel
  local key rel dest tmp_dest local_file status=0

  mapfile -t parsed < <(s3_parse_uri "${src}") || return 1
  [[ "${#parsed[@]}" -eq 2 ]] || return 1
  bucket="${parsed[0]}"
  prefix="${parsed[1]%/}"
  list_prefix="${prefix}"
  [[ -z "${list_prefix}" ]] || list_prefix="${list_prefix}/"

  mkdir -p "${dst}" || return 1
  listing="$(mktemp "${TMPDIR:-/tmp}/s3-sync-list.XXXXXX")" || return 1
  remote_rel="$(mktemp "${TMPDIR:-/tmp}/s3-sync-rel.XXXXXX")" || {
    safe_rm_f "${listing}"
    return 1
  }

  if ! s3api_list_objects_v2 "${bucket}" "${list_prefix}" --output json > "${listing}"; then
    safe_rm_f "${listing}"
    safe_rm_f "${remote_rel}"
    return 1
  fi

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    [[ "${key}" != */ ]] || continue

    if [[ -n "${list_prefix}" ]]; then
      [[ "${key}" == "${list_prefix}"* ]] || continue
      rel="${key#"${list_prefix}"}"
    else
      rel="${key}"
    fi

    case "${rel}" in
      ""|/*|..|../*|*/..|*/../*|*\\*)
        status=1
        break
        ;;
    esac
    if printf '%s' "${rel}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      status=1
      break
    fi

    printf '%s\n' "${rel}" >> "${remote_rel}"
    dest="${dst%/}/${rel}"
    mkdir -p "$(dirname "${dest}")" || {
      status=1
      break
    }

    tmp_dest="$(mktemp "${dest}.tmp.XXXXXX")" || {
      status=1
      break
    }
    if ! s3api_get_object "${bucket}" "${key}" "${tmp_dest}"; then
      safe_rm_f "${tmp_dest}"
      status=1
      break
    fi
    if ! safe_mv_f "${tmp_dest}" "${dest}"; then
      safe_rm_f "${tmp_dest}"
      status=1
      break
    fi
  done < <(jq -r '.Contents[]?.Key' "${listing}")

  if [[ "${status}" -eq 0 && "${remove_extra}" == "true" ]]; then
    while IFS= read -r -d '' local_file; do
      rel="${local_file#"${dst%/}"/}"
      if ! grep -Fxq "${rel}" "${remote_rel}"; then
        safe_rm_f "${local_file}" || {
          status=1
          break
        }
      fi
    done < <(find "${dst}" -type f -print0)
  fi

  safe_rm_f "${listing}"
  safe_rm_f "${remote_rel}"
  [[ "${status}" -eq 0 ]]
}

s3_sync() {
  local src="$1"
  local dst="$2"
  local -a args=()
  local arg remove_extra=false compatible=true
  shift 2

  for arg in "$@"; do
    case "${arg}" in
      --remove)
        args+=(--delete)
        remove_extra=true
        ;;
      --overwrite) ;;
      *)
        args+=("${arg}")
        compatible=false
        ;;
    esac
  done

  if [[ "${compatible}" == true ]] \
    && [[ -n "$(s3_endpoint_url)" ]] \
    && [[ "$(s3_uri "${src}")" == s3://* ]] \
    && [[ "$(s3_uri "${dst}")" != s3://* ]]; then
    s3_compatible_download_sync "${src}" "${dst}" "${remove_extra}"
    return
  fi

  s3_aws s3 sync "$(s3_uri "${src}")" "$(s3_uri "${dst}")" "${args[@]}"
}

s3_ls() {
  local src="$1"
  shift

  s3_aws s3 ls "$(s3_uri "${src}")" "$@"
}

s3api_list_objects_v2() {
  local bucket="$1"
  local prefix="$2"
  shift 2

  s3_aws s3api list-objects-v2 --bucket "${bucket}" --prefix "${prefix}" "$@"
}

s3_object_exists() {
  local bucket="$1"
  local key="$2"

  s3_aws s3api head-object --bucket "${bucket}" --key "${key}" >/dev/null
}

s3_list_paths() {
  local src="$1"
  local uri bucket key

  uri="$(s3_uri "${src}")"
  case "${uri}" in
    s3://*) ;;
    *) die "S3 source must start with s3:// or s3/: ${src}" ;;
  esac

  bucket="${uri#s3://}"
  key="${bucket#*/}"
  bucket="${bucket%%/*}"
  if [[ "${key}" == "${bucket}" ]]; then
    key=""
  fi
  key="${key%/}"

  s3api_list_objects_v2 "${bucket}" "${key}" --output json |
    jq -r '.Contents[]?.Key' |
    while IFS= read -r key; do
      [[ -n "${key}" ]] || continue
      printf 's3/%s/%s\n' "${bucket}" "${key}"
    done
}

cleanup_s3_source_listing_tmp() {
  local tmp="${1:-}"

  [[ -z "$tmp" ]] || safe_rm_f "$tmp"
}

ensure_s3_source_nonempty_for_remove() {
  local src="$1"
  local feature="$2"
  local error_message=""
  local tmp=""

  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-source.XXXXXX")" \
    || die "Failed to create temporary file for ${feature} source listing"

  if ! s3_list_paths "$src" > "$tmp"; then
    error_message="Failed to list ${feature} source before remove sync: ${src}"
  elif [[ ! -s "$tmp" ]]; then
    error_message="${feature} remove_extra requested but S3 source is empty: ${src}"
  fi

  cleanup_s3_source_listing_tmp "$tmp"
  [[ -z "$error_message" ]] || die "$error_message"
}
