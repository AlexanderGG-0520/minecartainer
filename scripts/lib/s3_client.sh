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
    export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
    export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
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

s3_cp() {
  local src="$1"
  local dst="$2"
  shift 2

  s3_aws s3 cp "$(s3_uri "${src}")" "$(s3_uri "${dst}")" "$@"
}

s3_sync() {
  local src="$1"
  local dst="$2"
  local -a args=()
  local arg
  shift 2

  for arg in "$@"; do
    case "${arg}" in
      --remove) args+=(--delete) ;;
      --overwrite) ;;
      *) args+=("${arg}") ;;
    esac
  done

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
