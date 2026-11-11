#!/usr/bin/env bash
# Minimal S3 client using curl --aws-sigv4 (no aws CLI / zstd required).
# Path-style addressing, compatible with SeaweedFS / MinIO / AWS.
#
# Required env: S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
# Optional env: S3_REGION (default us-east-1)

s3_configured() {
  [[ -n "${S3_ENDPOINT:-}" && -n "${S3_BUCKET:-}" && -n "${S3_ACCESS_KEY_ID:-}" && -n "${S3_SECRET_ACCESS_KEY:-}" ]]
}

_s3_url() {
  printf '%s/%s/%s' "${S3_ENDPOINT%/}" "$S3_BUCKET" "$1"
}

_s3_curl() {
  curl --silent --show-error \
    --connect-timeout 5 --max-time "${S3_TIMEOUT:-120}" \
    --aws-sigv4 "aws:amz:${S3_REGION:-us-east-1}:s3" \
    --user "${S3_ACCESS_KEY_ID}:${S3_SECRET_ACCESS_KEY}" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
    "$@"
}

# s3_get <key> <dest-file>
# returns 0: hit, 1: miss (404), 2: error
s3_get() {
  local key="$1" dest="$2" code
  code="$(_s3_curl -o "$dest" -w '%{http_code}' "$(_s3_url "$key")")" || return 2
  case "$code" in
    200) return 0 ;;
    404) rm -f "$dest"; return 1 ;;
    *) rm -f "$dest"; echo "s3_get: unexpected HTTP $code for $key" >&2; return 2 ;;
  esac
}

# s3_put <key> <src-file>
s3_put() {
  local key="$1" src="$2" code
  code="$(_s3_curl -X PUT -T "$src" -o /dev/null -w '%{http_code}' "$(_s3_url "$key")")" || return 1
  if [[ "$code" != 200 ]]; then
    echo "s3_put: unexpected HTTP $code for $key" >&2
    return 1
  fi
}
