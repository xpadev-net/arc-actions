#!/usr/bin/env bash
# shellcheck disable=SC2034 # TOOL_DIR / TOOL_HIT are consumed by callers
# Install a prebuilt tool, restoring it from S3 when possible.
# Requires: lib/common.sh and lib/s3.sh sourced; env S3_PREFIX (default "tools"), S3_WRITE.
# Sets TOOL_DIR (directory that must be on PATH) and TOOL_HIT (true|false).

# Zig needs its distribution, not just the executable. The marker is written only
# after copying the complete verified upstream payload.
_tool_ready() {
  [[ -x "$1/$2" ]] || return 1
  [[ "$2" != zig ]] || [[ -f "$1/.arc-complete" && -f "$1/lib/std/std.zig" ]]
}

tool_install() {
  local name="$1" version="${2#v}" arch triple url bin asset expected="" compression=gz metadata candidate
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
    zig | cargo-zigbuild) ;; # Resolve upstream metadata only after cache lookup.
    *) arc_die "unsupported tool '$name' (supported: cargo-deny, sccache, zig, cargo-zigbuild)" ;;
  esac
  bin="$name"

  TOOL_DIR="${RUNNER_TOOL_CACHE:-$HOME/.cache}/arc-tools/${name}/${version}/${arch}"
  TOOL_HIT=false
  if _tool_ready "$TOOL_DIR" "$bin"; then TOOL_HIT=true; return 0; fi

  local prefix="${S3_PREFIX:-tools}" key tmp rc
  key="${prefix}/${name}/${version}/${arch}.tar.gz"
  tmp="$(mktemp -d)"
  # Never combine an incomplete local installation with an S3 payload.
  rm -rf "${TOOL_DIR:?}"
  mkdir -p "$TOOL_DIR"

  if s3_configured; then
    s3_get "$key" "$tmp/s3.tar.gz"; rc=$?
    if [[ $rc -eq 0 ]]; then
      if tar -xzf "$tmp/s3.tar.gz" -C "$TOOL_DIR" && _tool_ready "$TOOL_DIR" "$bin"; then
        echo "Restored $name $version from S3"; TOOL_HIT=true; rm -rf "$tmp"; return 0
      fi
      echo "::warning::Corrupt S3 archive for $name; downloading upstream"
      rm -rf "${TOOL_DIR:?}"
      mkdir -p "$TOOL_DIR"
    elif [[ $rc -eq 1 ]]; then echo "S3 cache miss for $name $version"
    else echo "::warning::S3 error for $name; downloading upstream"; fi
  fi

  case "$name" in
    zig)
      metadata="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://ziglang.org/download/index.json)" || arc_die "zig: failed to fetch download index"
      url="$(jq -er --arg v "$version" --arg a "${arch}-linux" '.[$v][$a].tarball' <<<"$metadata")" || arc_die "zig: no Linux $arch release for $version"
      expected="$(jq -er --arg v "$version" --arg a "${arch}-linux" '.[$v][$a].shasum' <<<"$metadata")" || arc_die "zig: missing SHA-256 for $version"
      asset="${url##*/}"; asset="${asset%.tar.xz}"
      compression=xz ;;
    cargo-zigbuild)
      metadata="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://api.github.com/repos/rust-cross/cargo-zigbuild/releases/tags/v${version}")" || arc_die "cargo-zigbuild: failed to fetch release metadata"
      # Older releases use a flat gzip archive. Newer cargo-dist releases use
      # an enclosing directory and xz; prefer musl where it is published.
      for candidate in "cargo-zigbuild-v${version}.${triple}.tar.gz" "cargo-zigbuild-${triple}.tar.xz" "cargo-zigbuild-${arch}-unknown-linux-gnu.tar.xz"; do
        url="$(jq -r --arg n "$candidate" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$metadata")" || arc_die "cargo-zigbuild: invalid release metadata"
        [[ -n "$url" ]] && break
      done
      [[ -n "$url" ]] || arc_die "cargo-zigbuild: no Linux $arch archive for $version"
      if [[ "$candidate" == *.tar.xz ]]; then
        compression=xz; asset="${candidate%.tar.xz}"
      else
        asset=.
      fi ;;
  esac

  echo "Downloading $name $version from upstream"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$url" -o "$tmp/archive" || arc_die "failed to download $url"
  local actual
  if [[ -z "$expected" ]]; then
    expected="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "${url}.sha256" | awk '{print $1}')"
  fi
  actual="$(sha256sum "$tmp/archive" | awk '{print $1}')"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$expected" == "$actual" ]] || arc_die "$name: checksum mismatch"
  mkdir -p "$tmp/x"
  if [[ "$compression" == xz ]]; then
    tar -xJf "$tmp/archive" -C "$tmp/x" || arc_die "$name: extract failed"
  else
    tar -xzf "$tmp/archive" -C "$tmp/x" || arc_die "$name: extract failed"
  fi
  if [[ "$name" == zig ]]; then
    [[ -x "$tmp/x/$asset/zig" && -f "$tmp/x/$asset/lib/std/std.zig" ]] || arc_die "zig: incomplete distribution"
    rm -f "$TOOL_DIR/.arc-complete"
    cp -R "$tmp/x/$asset/." "$TOOL_DIR/" || arc_die "zig: failed to install distribution"
    touch "$TOOL_DIR/.arc-complete" || arc_die "zig: failed to mark distribution complete"
  else
    install -m 0755 "$tmp/x/${asset}/${bin}" "$TOOL_DIR/$bin" || arc_die "$name: binary not found in archive"
  fi

  if s3_configured && arc_can_write; then
    local member="$bin"
    [[ "$name" != zig ]] || member=.
    if tar -czf "$tmp/up.tar.gz" -C "$TOOL_DIR" "$member" && s3_put "$key" "$tmp/up.tar.gz"; then
      echo "Uploaded $name $version to S3"
    else
      echo "::warning::S3 upload failed for $name"
    fi
  fi
  rm -rf "$tmp"
}
