# arc-actions

Shared actions and reusable workflows for self-hosted ARC runners.

| Path | Kind | Description |
| --- | --- | --- |
| [`setup-node`](setup-node) | composite action | Drop-in wrapper for `actions/setup-node` backed by an S3 toolcache |

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

## Adding a new action
Create `<name>/action.yml`; put shared shell helpers in `lib/`.
