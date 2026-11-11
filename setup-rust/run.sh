#!/usr/bin/env bash
# Install a Rust toolchain via rustup, restoring/saving it from an S3 cache.
# Env: TOOLCHAIN PROFILE COMPONENTS TARGETS S3_* S3_PREFIX S3_WRITE (+ GITHUB_* from the runner)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/s3.sh
source "$here/../lib/s3.sh"

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
die() { echo "::error::$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64) triple=x86_64-unknown-linux-gnu ;;
  aarch64 | arm64) triple=aarch64-unknown-linux-gnu ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

norm() { tr -s ', ' '\n' <<<"$1" | sed '/^$/d' | sort -u | paste -sd, -; }
components="$(norm "${COMPONENTS:-}")"
targets="$(norm "${TARGETS:-}")"
profile="${PROFILE:-minimal}"
toolchain="${TOOLCHAIN:?toolchain is required}"

# Only fully pinned toolchains are cacheable; aliases (stable/beta/nightly/1.85) need a network lookup.
cacheable=false
if [[ "$toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$toolchain" =~ ^(nightly|beta)-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  cacheable=true
fi
use_s3=false
if [[ "$cacheable" == true ]] && s3_configured; then use_s3=true; fi

# Never write to the shared cache from pull-request contexts (cache poisoning).
can_write=false
if [[ "${S3_WRITE:-false}" == true ]]; then
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_target) echo "::warning::s3-write is ignored on ${GITHUB_EVENT_NAME} events" ;;
    *) can_write=true ;;
  esac
fi

prefix="${S3_PREFIX:-rust}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export PATH="$CARGO_HOME/bin:$PATH"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ---- 1. rustup itself -------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
  init="$tmp/rustup-init"
  got=false
  if [[ "$use_s3" == true ]]; then
    if s3_get "$prefix/rustup-init/$triple/rustup-init" "$init"; then got=true; fi
  fi
  if [[ "$got" != true ]]; then
    base="https://static.rust-lang.org/rustup/dist/$triple"
    curl --proto '=https' --tlsv1.2 -fsSL "$base/rustup-init" -o "$init" || die "failed to download rustup-init"
    expected="$(curl --proto '=https' --tlsv1.2 -fsSL "$base/rustup-init.sha256" | awk '{print $1}')"
    actual="$(sha256sum "$init" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "rustup-init checksum mismatch"
    if [[ "$use_s3" == true && "$can_write" == true ]]; then
      s3_put "$prefix/rustup-init/$triple/rustup-init" "$init" || echo "::warning::failed to upload rustup-init"
    fi
  fi
  chmod +x "$init"
  "$init" -y --default-toolchain none --profile minimal --no-modify-path >/dev/null 2>&1 \
    || die "rustup-init failed"
  [[ -n "${GITHUB_PATH:-}" ]] && echo "$CARGO_HOME/bin" >> "$GITHUB_PATH"
fi

# ---- 2. restore toolchain from S3 ------------------------------------------
tcdir="$RUSTUP_HOME/toolchains/${toolchain}-${triple}"
hash="$(printf '%s|%s|%s' "$profile" "$components" "$targets" | sha256sum | cut -c1-16)"
key="$prefix/$toolchain/$triple/$hash.tar.gz"
hit=false
if [[ "$use_s3" == true ]]; then
  if [[ -d "$tcdir" ]]; then
    hit=true
  else
    s3_get "$key" "$tmp/tc.tar.gz"; rc=$?
    if [[ $rc -eq 0 ]]; then
      mkdir -p "$tcdir"
      if tar -xzf "$tmp/tc.tar.gz" -C "$tcdir" && [[ -x "$tcdir/bin/rustc" ]]; then
        hit=true; echo "Restored Rust $toolchain ($triple) from S3"
      else
        echo "::warning::Corrupt S3 archive; installing with rustup"; rm -rf "$tcdir"
      fi
    elif [[ $rc -eq 1 ]]; then echo "S3 cache miss for Rust $toolchain ($triple)"
    else echo "::warning::S3 error; installing with rustup"; fi
  fi
fi
if [[ "$hit" == true ]]; then
  if ! { rustup default "$toolchain" >/dev/null 2>&1 && rustc --version >/dev/null 2>&1; }; then
    echo "::warning::Restored toolchain is unusable; installing with rustup"
    rm -rf "$tcdir"; hit=false
  fi
fi

# ---- 3. regular rustup install on miss -------------------------------------
if [[ "$hit" != true ]]; then
  args=(toolchain install "$toolchain" --profile "$profile" --no-self-update)
  [[ -n "$components" ]] && args+=(-c "$components")
  [[ -n "$targets" ]] && args+=(-t "$targets")
  rustup "${args[@]}" || die "rustup toolchain install failed"
  rustup default "$toolchain" >/dev/null || die "rustup default failed"

  if [[ "$use_s3" == true && "$can_write" == true && -x "$tcdir/bin/rustc" ]]; then
    if tar -czf "$tmp/tc.tar.gz" -C "$tcdir" . && s3_put "$key" "$tmp/tc.tar.gz"; then
      echo "Uploaded Rust $toolchain ($triple) to S3"
    else
      echo "::warning::S3 upload failed"
    fi
  fi
fi

out hit "$hit"
out name "$toolchain"
out rustc-version "$(rustc --version)"
