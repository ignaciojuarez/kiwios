# Test strategy and edge cases

Tests protect public contracts and recovery paths, not private implementation details. Every phase adds unit tests for deterministic rules and a small number of vertical tests using temporary directories and real subprocesses.

## Manifest and installation

- Missing, duplicate, unknown, wrong-type, invalid UTF-8, oversized, or unsupported-version fields.
- Invalid IDs, SemVer, durations, dependencies, cycles, source references, config schemas, and duplicate contributions.
- Absolute/parent traversal, symlink escape, case-fold collision, non-executable command, and files changed after validation.
- Huge repositories, submodules, Git LFS placeholders, unsafe file modes, missing commits, network interruption, atomic-install failure, and rollback.
- Permission expansion, license/manifest/catalog mismatch, duplicate installed IDs, retained data, and incompatible updates.

Validation never executes plugin code. Installer fixtures use local repositories in CI; network discovery is tested through a stub client.

## Process and watcher

- Spawn failure, closed stdin, fixed environment, working directory, bare `PATH` lookup, and separate stdout/stderr.
- Empty output, plain text, malformed/unknown JSONL, invalid UTF-8, partial final line, mixed event types, and terminal-event/exit-code precedence.
- Exact and over-limit event, state, step, and log sizes; simultaneous stdout/stderr flooding must not deadlock.
- Timeout/cancel before spawn, during output, and at natural exit; `SIGTERM` grace followed by process-group `SIGKILL`, including grandchildren.
- App quit/crash during work, missing working directory, disk-full log writes, secret redaction, and plugin attempts to orphan a process.

## Queue, scheduler, and persistence

- Lock contention, duplicate requests, fairness, skipped overlapping checks, cancellation, and idempotent terminal writes.
- Sleep/wake, wall-clock and daylight-saving jumps, network changes, and skipped overlapping checks.
- First launch, every schema migration, interrupted migration, corrupt database, missing optional logs, disk full, backup, restore, and downgrade refusal.
- Restart recovery must distinguish queued, running, interrupted, canceled, failed, and safe-to-retry work.

## Remote boundary

- Bind only to loopback; reject direct LAN/Funnel configuration and spoofed identity headers.
- Missing/revoked tailnet identity, ACL denial, Tailscale outage/reconnect, and concurrent browser sessions.
- CSRF and Origin rejection, escaped plugin text, oversized bodies, slow clients, replayed mutations, and confirmation expiry.
- Remote mode blocks any operation that could open TCC, Keychain, Gatekeeper, license, device-trust, or administrator prompts.

Use an injectable verified-identity boundary in tests. Do not make authorization decisions from caller-supplied HTTP headers.

## macOS lifecycle and UI

- Logout, cold FileVault boot, launch-at-login failure, app relaunch, fast user switching, sleep, power loss, and TCC revocation.
- Empty/loading/error/stale states, unknown saved contribution IDs, incompatible state shapes, long/untrusted text, keyboard-only use, VoiceOver, and narrow phone layouts.
- Loss of a plugin, Tailscale, or optional logs must leave local settings, Doctor, disable, and recovery paths usable.

## Release gate

Before a tagged release: run unit/vertical tests on the minimum supported macOS and current release macOS, exercise signed/notarized installation on a clean account, test FileVault restart expectations on disposable hardware, verify the support bundle contains no secrets, and manually complete every core journey in [product.md](product.md).
