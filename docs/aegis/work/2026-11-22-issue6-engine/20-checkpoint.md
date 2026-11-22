# Issue #6 engine repair

## Intent / TaskStartSnapshot
User authorizes repair of diagnosed engine compatibility, update and error propagation defects. Branch main, HEAD b0d1d6a. Tracked tree initially clean. Preexisting untracked packaging/__pycache__, references/, release_0.36.33.md and 3 historical test reports must not be staged or removed. BASELINE.md read: preserve strategies/network/DNS; take router snapshot before mutations.

## Plan and owner decisions
Decision: code-change. Medium/high cross-component repair; architecture review required for canonical engine capability/layout ownership, not redesign of scanner. Root evidence: issue #6 log NoFilterMark, both kmods loaded. Engine lifecycle currently duplicated across installer/helper/init. Introduce one shared POSIX shell engine module, remove obsolete installer/helper download branches; keep scanner safety check. Preserve foreign legacy entry as backup when rebinding scanner path. TDD mode off, proportional regression tests required.

1. Shared engine module + installer/init integration and dedicated tests (delegate).
2. Helper preflight/doctor/install/update delegates to module; update installs module before engine validation. Lead owns helper only.
3. Search fail-fast after phase1 preflight failure; retain exact scanner ERROR including uppercase.
4. Run tests, independent spec and code review, snapshot and live safe validation.
5. Only then version/release and accurate issue reply.

## Verification / unknowns

Current implementation: common engine lifecycle, post-update migration worker/status UI, exact runtime snapshots+rollback, engine-only init mode, fatal preflight error preservation and fail-fast. Independent code/spec review PASS (static/offline). Lifecycle25 cases and init5 cases pass sh+ash; helper20 cases (including old-updater migration, rollback, cleanup ownership and BusyBox concurrent duplicate launch) verified; 10 repeated helper suites PASS; UI4 actual-function Node VM cases pass. Router SSH stopped before authentication: current key SHA256:Z84dWdLr7erplhbnIrLdSl9VrXqr6N36/p0buEW8S8w differs prior eGt/...; human confirmation requested. No router mutation performed in this task.

Observed host uutils mkdir atomicity anomaly reproduced independently (both concurrent creators exit0 at iteration37); BusyBox mkdir control200 iterations PASS, fixture should use BusyBox matching OpenWrt. Not a production lock fallback.

Complexity control: removed duplicate installer/helper engine download owners; retained /opt adapter only because bundled scanner0.18.64 requires path, backed-up rather than deleting foreign legacy file. New shared validation + bounded transactional worker/status are necessary migration boundary. No Rust scanner security relaxation or package removal. No ADR requested; source baseline sync via changelog/release docs only.

Need capability validation by captured help (exit1 may be valid) AND --dry-run with shipped Lua modules, rollback on invalid download, stale legacy file/link handling, idempotency/concurrency; scanner error preservation and no phase2 after fatal error. Reporter NanoPi inaccessible: cannot claim fix on that device without reporter confirmation. No strategy or DNS changes permitted for repair.
