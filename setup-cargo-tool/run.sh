#!/usr/bin/env bash
# Env: TOOLS (newline/comma separated name@version), S3_* , S3_PREFIX, S3_WRITE
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/s3.sh
source "$here/../lib/s3.sh"
# shellcheck source=../lib/tool.sh
source "$here/../lib/tool.sh"

all_hit=true
count=0
while IFS= read -r spec; do
  spec="${spec//[[:space:]]/}"
  [[ -z "$spec" ]] && continue
  [[ "$spec" == *@* ]] || arc_die "invalid tool spec '$spec' (expected name@version)"
  tool_install "${spec%%@*}" "${spec#*@}"
  [[ "$TOOL_HIT" == true ]] || all_hit=false
  [[ -n "${GITHUB_PATH:-}" ]] && echo "$TOOL_DIR" >> "$GITHUB_PATH"
  export PATH="$TOOL_DIR:$PATH"
  count=$((count + 1))
done < <(tr ',' '\n' <<<"${TOOLS:-}")

[[ $count -gt 0 ]] || arc_die "'tools' is empty"
echo "s3-cache-hit=$all_hit" >> "${GITHUB_OUTPUT:-/dev/null}"
