#!/usr/bin/env bash
# Install sccache and export env vars so cargo uses an S3 (SeaweedFS) backend.
# Env: SCCACHE_VERSION SCOPE S3_* S3_WRITE S3_PREFIX(default sccache) TOOLS_PREFIX(default tools)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/s3.sh
source "$here/../lib/s3.sh"
# shellcheck source=../lib/tool.sh
source "$here/../lib/tool.sh"

genv() { echo "$1=$2" >> "${GITHUB_ENV:-/dev/null}"; }

s3_configured || { echo "::warning::S3 is not configured; sccache is not enabled"; echo "enabled=false" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0; }

# 1. binary (cached like setup-cargo-tool)
S3_PREFIX="${TOOLS_PREFIX:-tools}" tool_install sccache "${SCCACHE_VERSION:?sccache-version is required}"
[[ -n "${GITHUB_PATH:-}" ]] && echo "$TOOL_DIR" >> "$GITHUB_PATH"
export PATH="$TOOL_DIR:$PATH"

# 2. backend config. Untrusted contexts get READ_ONLY: they use the default-branch cache but never write.
if arc_can_write; then rw=READ_WRITE; else rw=READ_ONLY; fi
scope="${SCOPE:-unscoped}"
[[ "$scope" =~ ^[A-Za-z0-9._/-]+$ ]] || arc_die "invalid scope '$scope'"
keyprefix="${S3_PREFIX:-sccache}/${scope}"
ssl=false; [[ "$S3_ENDPOINT" == https://* ]] && ssl=true

declare -A cfg=(
  [SCCACHE_BUCKET]="$S3_BUCKET"
  [SCCACHE_ENDPOINT]="$S3_ENDPOINT"
  [SCCACHE_REGION]="${S3_REGION:-us-east-1}"
  [SCCACHE_S3_USE_SSL]="$ssl"
  [SCCACHE_S3_KEY_PREFIX]="$keyprefix"
  [SCCACHE_S3_RW_MODE]="$rw"
  [AWS_ACCESS_KEY_ID]="$S3_ACCESS_KEY_ID"
  [AWS_SECRET_ACCESS_KEY]="$S3_SECRET_ACCESS_KEY"
)
for k in "${!cfg[@]}"; do export "$k=${cfg[$k]}"; done

# 3. make sure the backend works; otherwise degrade to a plain build.
sccache --stop-server >/dev/null 2>&1
if ! sccache --start-server >/dev/null 2>&1 || ! sccache --show-stats >/dev/null 2>&1; then
  echo "::warning::sccache could not start with the S3 backend; building without it"
  echo "enabled=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

for k in "${!cfg[@]}"; do genv "$k" "${cfg[$k]}"; done
echo "::add-mask::$S3_SECRET_ACCESS_KEY"
genv RUSTC_WRAPPER sccache
genv CARGO_INCREMENTAL 0
echo "enabled=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "rw-mode=$rw" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "sccache enabled ($rw, prefix=$keyprefix)"
