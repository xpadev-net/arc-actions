#!/usr/bin/env bash
# shellcheck disable=SC2034 # TOOL_DIR / TOOL_HIT are consumed by callers
# Install a prebuilt single-binary tool, restoring it from S3 when possible.
# Requires: lib/common.sh and lib/s3.sh sourced; env S3_PREFIX (default "tools"), S3_WRITE.
# Sets TOOL_DIR (directory that must be on PATH) and TOOL_HIT (true|false).

tool_install() {
  local name="$1" version="${2#v}" arch triple url bin asset
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || arc_die "$name: pin an exact version (x.y.z), got '$2'"
  arch="$(arc_arch)"
  triple="${arch}-unknown-linux-musl"
  case "$name" in
    cargo-deny)
      asset="cargo-deny-${version}-${triple}"
      url="https://github.com/EmbarkStudios/cargo-deny/releases/download/${version}/${asset}.tar.gz" ;;
    sccache)
      asset="sccache-v${version}-${triple}"
      url="https://github.com/mozilla/sccache/releases/download/v${version}/${asset}.tar.gz" ;;
    *) arc_die "unsupported tool '$name' (supported: cargo-deny, sccache)" ;;
  esac
  bin="$name"

  TOOL_DIR="${RUNNER_TOOL_CACHE:-$HOME/.cache}/arc-tools/${name}/${version}/${arch}"
  TOOL_HIT=false
  if [[ -x "$TOOL_DIR/$bin" ]]; then TOOL_HIT=true; return 0; fi

  local prefix="${S3_PREFIX:-tools}" key tmp rc
  key="${prefix}/${name}/${version}/${arch}.tar.gz"
  tmp="$(mktemp -d)"
  mkdir -p "$TOOL_DIR"

  if s3_configured; then
    s3_get "$key" "$tmp/s3.tar.gz"; rc=$?
    if [[ $rc -eq 0 ]]; then
      if tar -xzf "$tmp/s3.tar.gz" -C "$TOOL_DIR" && [[ -x "$TOOL_DIR/$bin" ]]; then
        echo "Restored $name $version from S3"; TOOL_HIT=true; rm -rf "$tmp"; return 0
      fi
      echo "::warning::Corrupt S3 archive for $name; downloading upstream"
      rm -rf "${TOOL_DIR:?}"/*
    elif [[ $rc -eq 1 ]]; then echo "S3 cache miss for $name $version"
    else echo "::warning::S3 error for $name; downloading upstream"; fi
  fi

  echo "Downloading $name $version from upstream"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$url" -o "$tmp/a.tar.gz" || arc_die "failed to download $url"
  local expected actual
  expected="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "${url}.sha256" | awk '{print $1}')"
  actual="$(sha256sum "$tmp/a.tar.gz" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || arc_die "$name: checksum mismatch"
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/a.tar.gz" -C "$tmp/x" || arc_die "$name: extract failed"
  install -m 0755 "$tmp/x/${asset}/${bin}" "$TOOL_DIR/$bin" || arc_die "$name: binary not found in archive"

  if s3_configured && arc_can_write; then
    if tar -czf "$tmp/up.tar.gz" -C "$TOOL_DIR" "$bin" && s3_put "$key" "$tmp/up.tar.gz"; then
      echo "Uploaded $name $version to S3"
    else
      echo "::warning::S3 upload failed for $name"
    fi
  fi
  rm -rf "$tmp"
}
