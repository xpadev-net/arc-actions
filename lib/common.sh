#!/usr/bin/env bash
# Shared helpers for arc-actions.

arc_die() { echo "::error::$*" >&2; exit 1; }

# arc_musl_triple -> x86_64-unknown-linux-musl | aarch64-unknown-linux-musl
arc_arch() {
  case "$(uname -m)" in
    x86_64) echo x86_64 ;;
    aarch64 | arm64) echo aarch64 ;;
    *) arc_die "unsupported architecture: $(uname -m)" ;;
  esac
}

# Trusted = a run of the default branch that is not driven by a pull request.
# Anything else (PRs, feature branches, tags) must never write to shared caches.
# Env: GITHUB_EVENT_NAME, GITHUB_REF, DEFAULT_BRANCH (may be empty)
arc_is_trusted_context() {
  case "${GITHUB_EVENT_NAME:-}" in
    push | workflow_dispatch | merge_group) ;;
    schedule) return 0 ;; # scheduled runs always execute on the default branch
    *) return 1 ;;
  esac
  [[ -n "${DEFAULT_BRANCH:-}" && "${GITHUB_REF:-}" == "refs/heads/${DEFAULT_BRANCH}" ]]
}

# arc_can_write: S3_WRITE=true requested AND trusted context.
arc_can_write() {
  [[ "${S3_WRITE:-false}" == true ]] || return 1
  if arc_is_trusted_context; then return 0; fi
  echo "::warning::s3-write is ignored outside the default branch (event=${GITHUB_EVENT_NAME:-?} ref=${GITHUB_REF:-?})" >&2
  return 1
}
