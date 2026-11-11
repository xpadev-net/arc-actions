# arc-actions

Shared actions and reusable workflows for self-hosted ARC runners.

| Path | Kind | Description |
| --- | --- | --- |
| [`setup-node`](setup-node) | composite action | Drop-in wrapper for `actions/setup-node` backed by an S3 toolcache |
| [`setup-cargo-tool`](setup-cargo-tool) | composite action | Pinned prebuilt cargo tools (`cargo-deny`, `sccache`) restored from S3 |
| [`setup-sccache`](setup-sccache) | composite action | sccache with an S3 backend; read-only outside the default branch |
| [`setup-rust`](setup-rust) | composite action | rustup-based Rust toolchain install backed by an S3 cache (installs rustup if missing) |

## setup-node

```yaml
- uses: xpadev-net/arc-actions/setup-node@v1
  with:
    node-version: 22.11.0          # exact versions use the S3 cache
    s3-endpoint: ${{ secrets.S3_ENDPOINT }}
    s3-bucket: ${{ secrets.S3_BUCKET }}
    s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
    s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
    s3-write: ${{ github.ref == 'refs/heads/main' }}   # upload only from trusted refs
```

- **hit**: Node.js is extracted into `$RUNNER_TOOL_CACHE`, then `actions/setup-node` runs and finds it
  there, so no download happens. `registry-url`, `cache`, etc. behave exactly as upstream.
- **miss / S3 error / S3 unset**: plain `actions/setup-node`. With `s3-write: true` the result is uploaded.
- Aliases (`22`, `lts/*`) and `package.json` version files need a network lookup, so they skip the cache
  and are delegated to `actions/setup-node`. Pin exact versions to benefit.
- Linux x64 / arm64 only. Requires `curl` and `tar` (no `aws` CLI / `zstd` needed).
- Objects: `<s3-prefix>/v<version>/linux-<arch>.tar.gz` (default prefix `node`).

Security: do not give write credentials to workflows that run untrusted code (fork PRs); use a
read-only key there and `s3-write: false`.

## setup-rust

```yaml
- uses: xpadev-net/arc-actions/setup-rust@v1
  with:
    toolchain: 1.99.1              # fully pinned values use the S3 cache
    components: clippy,rustfmt
    targets: wasm32-unknown-unknown
    s3-endpoint: ${{ secrets.S3_ENDPOINT }}
    s3-bucket: ${{ secrets.S3_BUCKET }}
    s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
    s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
```

- Unlike `dtolnay/rust-toolchain` it does not require rustup on the runner; it installs `rustup-init`
  (also cached in S3, SHA-256 verified when fetched from static.rust-lang.org).
- Cache key: `<prefix>/<toolchain>/<host-triple>/<hash(profile,components,targets)>.tar.gz`.
- Pinned toolchains: `1.99.1`, `nightly-2026-01-01`. Aliases (`stable`, `beta`, `nightly`, `1.99`) use plain rustup.
- Miss / S3 error: regular `rustup toolchain install`, then optional upload.

## setup-cargo-tool

```yaml
- uses: xpadev-net/arc-actions/setup-cargo-tool@v1
  with:
    tools: |
      cargo-deny@0.20.2
    s3-endpoint: ${{ secrets.S3_ENDPOINT }}
    s3-bucket: ${{ secrets.S3_BUCKET }}
    s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
    s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
```

- Downloads release binaries (no `cargo install`/compilation). On a miss the upstream archive is fetched from
  GitHub, its SHA-256 is verified, and it is stored in S3 (only when writing is allowed).
- Exact versions only (`x.y.z`). Currently supported: `cargo-deny`, `sccache`. Add a tool in `lib/tool.sh`.
- Objects: `<s3-prefix>/<tool>/<version>/<arch>.tar.gz` (default prefix `tools`).

## setup-sccache

```yaml
- uses: xpadev-net/arc-actions/setup-sccache@v1
  with:
    sccache-version: 0.19.0
    s3-endpoint: ${{ secrets.S3_ENDPOINT }}
    s3-bucket: ${{ secrets.S3_BUCKET }}
    s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
    s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
    s3-write: true            # honoured only on the default branch
- run: cargo build --release
- run: sccache --show-stats   # composite actions have no post step; print stats yourself
```

- Exports `RUSTC_WRAPPER=sccache`, `CARGO_INCREMENTAL=0` and the `SCCACHE_*` / `AWS_*` variables for later steps.
  If sccache cannot reach the backend, it is not enabled and the build runs normally.
- Objects live under `<s3-prefix>/<scope>/` (default `sccache/<owner>/<repo>`); scope per repository because
  absolute paths are part of Rust cache keys.
- **Trust model**: only runs of the default branch (push / workflow_dispatch / schedule / merge_group) with
  `s3-write: true` use `READ_WRITE`. Everything else, including pull requests, is forced to
  `SCCACHE_S3_RW_MODE=READ_ONLY`: it reads the default branch's cache but cannot poison it.
  Still hand a **read-only** S3 key to untrusted workflows, since a PR can edit its own workflow.
- Do not use sccache for release builds unless they run on the default branch with a read-only key.

## Cache poisoning

The S3 objects are executables that later jobs run. Therefore:

- `setup-node` / `setup-rust`: `s3-write` is **ignored on `pull_request` / `pull_request_target`** events.
- `setup-cargo-tool` / `setup-sccache`: writes are honoured **only on the default branch** (stricter).
- A same-repo PR can edit its own workflow, so this guard is not enough on its own. Give write credentials
  only to a trusted context (e.g. a GitHub Environment restricted to `main`/tags) and use a read-only key
  everywhere else (SeaweedFS identity with only `Read`/`List`).

## Adding a new action
Create `<name>/action.yml`; put shared shell helpers in `lib/`.
