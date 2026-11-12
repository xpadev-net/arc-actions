#!/usr/bin/env bash
# Run after restoring Zig and cargo-zigbuild and adding their directories to PATH.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'pub fn main() void {}\n' > "$work/hello.zig"
zig build-exe "$work/hello.zig" -femit-bin="$work/zig-hello"
"$work/zig-hello"
mkdir -p "$work/rust/src"
printf '[package]\nname = "zigbuild-smoke"\nversion = "0.1.0"\nedition = "2021"\n' > "$work/rust/Cargo.toml"
printf 'fn main() { println!("cargo-zigbuild smoke passed"); }\n' > "$work/rust/src/main.rs"
case "$(uname -m)" in
  x86_64) target=x86_64-unknown-linux-gnu ;;
  aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
  *) echo 'Unsupported smoke-test architecture' >&2; exit 1 ;;
esac
cargo zigbuild --manifest-path "$work/rust/Cargo.toml" --target "$target" --offline
"$work/rust/target/$target/debug/zigbuild-smoke"
