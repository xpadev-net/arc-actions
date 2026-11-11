# arc-actions

Shared actions and reusable workflows for self-hosted ARC runners.

| Path | Kind | Description |
| --- | --- | --- |
| [`setup-node`](setup-node) | composite action | Drop-in wrapper for `actions/setup-node` backed by an S3 toolcache |
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

## Cache poisoning

The S3 objects are executables that later jobs run. Therefore:

- `s3-write` is **ignored on `pull_request` / `pull_request_target`** events.
- A same-repo PR can edit its own workflow, so this guard is not enough on its own. Give write credentials
  only to a trusted context (e.g. a GitHub Environment restricted to `main`/tags) and use a read-only key
  everywhere else (SeaweedFS identity with only `Read`/`List`).

## Adding a new action
Create `<name>/action.yml`; put shared shell helpers in `lib/`.
