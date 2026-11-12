# Plan: Add Zig build tools

- status: done
- generated: 2026-11-13
- last_updated: 2026-11-13
- work_type: code

## Goal
- Allow `setup-cargo-tool` to install pinned `zig` and `cargo-zigbuild` for replacement of the caller's fixed-URL installation script.

## Definition of Done
- Both tools install from upstream with SHA-256 verification and participate in local/S3 caching.
- Documentation, targeted tests, and independent review cover the new behavior.

## Planner-added requirements
- Preserve the full Zig distribution: its compiler needs adjacent libraries to build programs.
- Cover Linux x86_64 and aarch64, upstream layout differences, checksum rejection, and S3 round trips: these exercise the existing action's platform and cache contract with the new tools.
- Update documentation and independently review the change: users need the supported names and prerequisites, and archive handling executes downloaded code.

## Scope / Non-goals
- Scope: `arc-actions` tool installer, action metadata, documentation, tests, CI.
- Non-goals: modifying the caller's `setup-rust-build.sh`, cluster changes, publishing a release or moving tags.

## Design
- Chosen: extend the existing tool installer with per-tool upstream resolution/extraction; preserve its cache contract. Resolve Zig URLs and hashes from the official download index and cargo-zigbuild release assets/checksum files from its GitHub release metadata. Structure: shared cache owner, tool-specific archive extraction. Evolution: two additional tool branches. Verification: fixture-based upstream/S3 tests plus Linux CI smoke builds. Operation: metadata lookup only on cache miss; failed verification aborts installation. Human: existing `name@version` syntax. Safety: retain SHA-256 verification and trusted-context S3 writes.
- Alternative: separate setup-zig action and install cargo-zigbuild using cargo. Structure: another action and duplicated cache integration. Evolution: more concepts and build dependencies. Verification: separate integration suite. Operation: Rust compilation adds installation latency. Human: caller needs multiple installation mechanisms. Safety: another code path for executable installation.
- Why chosen: the request targets `setup-cargo-tool`; extending it keeps the shared S3 implementation described in README.md and avoids compilation.

## Compatibility stance
- surface: tools input and normalized S3 archives
- stance: preserve
- justification: README.md documents `name@x.y.z`; setup-sccache/run.sh calls tool_install for sccache; .github/workflows/ci.yml consumes existing cargo-deny cache paths. New names extend the input while existing tools retain their paths and payloads.

## Context (workspace)
- Target repository: xpadev-net/arc-actions, based on main at 4eaf618.
- lib/tool.sh currently installs only a single binary from gzip archives.
- setup-cargo-tool/run.sh manages PATH and aggregate cache-hit output.
- Official Zig metadata checked at https://ziglang.org/download/index.json: 0.13.0 uses zig-linux-ARCH while 0.14.1 and 0.15.2 use zig-ARCH-linux; each provides tarball and shasum.
- GitHub release metadata checked with gh: cargo-zigbuild v0.20.1 provides musl tar.gz archives for both architectures; v0.24.1 provides tar.xz with musl x86_64 and GNU aarch64 assets, each with SHA-256 sidecars.
- No target repository rule suite or AGENTS.md is present.
- Research waived: the bounded installer, callers, CI, and upstream metadata were inspected directly before drafting.

## Assumptions
- Existing Linux scope continues; README.md and lib/common.sh define x86_64/aarch64.
- Metadata parsing may add a documented jq prerequisite; upstream archive decompression needs xz.

## Open Questions
- None affecting the implementation design.

## Tasks

### Task_1: Extend the installer and verification coverage
- status: done
- type: impl
- owns: [lib/tool.sh, setup-cargo-tool/action.yml, README.md, tests/, .github/workflows/ci.yml]
- depends_on: []
- description: Add Zig and cargo-zigbuild upstream resolution, verified extraction, complete Zig caching, documented usage, and tests integrated into CI.
- acceptance:
  - Pinned versions of both tools install for Linux x86_64 and aarch64 using the matching upstream archive and verified checksum.
  - Zig keeps its adjacent library files through upstream install, local reuse, and S3 restore; cargo-zigbuild is available on PATH.
  - Existing cargo-deny/sccache inputs, cache keys, and write restrictions remain valid.
  - Tests cover legacy/current upstream layouts, checksum mismatch, local reuse, and S3 restore; CI executes a real Zig build and a cargo zigbuild smoke build.
  - README and action metadata list tools, usage, and added prerequisites.
- validation:
  - kind: command
    required: true
    owner: worker
    detail: Run fixture-based tests for both architectures, archive layouts, checksum failures, local cache, and S3 round trips; run bash syntax checks and shellcheck.
  - kind: command
    required: true
    owner: worker
    detail: Execute Linux smoke coverage through CI or an available Linux runtime; demonstrate zig build-exe and cargo zigbuild with a pinned compatible tool pair after cache restore.

### Task_2: Independently review the change
- status: done
- type: review
- owns: []
- depends_on: [Task_1]
- acceptance:
  - Reviewer approves the implementation against the request, compatibility obligations, and required validation evidence.
  - SHA-256 failure and full Zig cache restoration have passing evidence.
- validation:
  - kind: review
    required: true
    owner: reviewer
    detail: Independently inspect the diff and test evidence, concentrating on upstream layout selection, incomplete cache acceptance, checksum verification, and existing caller behavior.

## Task Waves

- Wave 1 (parallel): [Task_1]
- Wave 2 (parallel): [Task_2]

## Rollback / Safety
- Revert the additive change; retain existing tool cache paths and default-branch write restrictions.

## Progress Log
- 2026-11-13: Drafted after repository and upstream inspection; awaiting plan review and user plan approval.
- 2026-11-13: Independent plan review APPROVED; balanced plan validator passed. Implementation awaits user plan approval. Document GNU runtime requirements if selecting newer aarch64 cargo-zigbuild GNU assets.
- 2026-11-13: User approved the plan and authorized implementation through the point before PR creation. Branch: feat/zig-cargo-zigbuild. PR creation and publishing tags remain outside this run.
- 2026-11-13: Wave 1 completed, Task_1 done. Changed lib/tool.sh, action metadata, README, CI, and two regression/smoke test files within assigned scope. Worker report schema validation passed. Eight fixture tests passed on both architecture layouts; bash syntax, shellcheck, actionlint 1.7.12, and diff whitespace checks passed. Real upstream downloads, SeaweedFS uploads, clean S3 restores, Zig build/execute, and cargo zigbuild build/execute passed on Linux aarch64 with Zig 0.15.2 and cargo-zigbuild 0.24.1. No blockers. GitHub-hosted CI and actual x86_64 smoke remain pending publication; x86_64 fixture coverage passed and both real runner architectures are configured in CI. Proceed to independent review.
- 2026-11-13: Wave 2 completed, Task_2 APPROVED with no findings. Reviewer independently ran eight fixture tests, shellcheck, bash syntax, and whitespace checks and reviewed integration evidence and existing callers. All required validation passed; no waivers or blockers. Completed local implementation before PR creation; branch publication and GitHub-hosted CI remain pending by scope. No rule/skill updates or ADR proposals: choices are derivable from the implementation and this plan. The CLI probe lesson candidate was not promoted to a repository rule because the required real integration check caught it before completion.

## Decision Log
- 2026-11-13: Preserve Zig's distribution instead of treating it as a standalone binary; archive layouts and metadata differ from existing tools.
- 2026-11-13: Real integration rejected the initial cargo zigbuild --version CI probe; corrected it to cargo-zigbuild --version and verified that invocation against the released binary. No design change or decision record required: this is CLI usage derivable from the executable.
