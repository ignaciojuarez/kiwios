# Test strategy and edge cases

Tests protect public contracts and recovery paths, not private implementation details. Every phase adds unit tests for deterministic rules and a small number of vertical tests using temporary directories and real subprocesses.

## Current implementation handoff

On September 13, 2026, the unsigned Debug menu-bar target built successfully with Xcode 27.0 (27A266a) for arm64 macOS, and all 71 tests passed with zero failures. The built bundle reports `LSUIElement = true`, and the primary PWA was rendered through macOS WebKit at desktop and phone sizes across Home, Tools, Brew, Plugins, Events, Settings, and a plugin progress page. Runtime tests cover approved plugin execution, cancellation, output handling, timeout overrides, Homebrew inventory, source identity, native-operation confirmation, exact remote mutation shapes and approved plugin restoration, settings/layout validation, and the existing monitor and watcher paths; fixtures use isolated persistence. These results do not complete the release gates: signed-app lifecycle, menu-bar interaction, keyboard/VoiceOver, sleep/wake, real Tailscale browser sessions, and platform permission behavior still need manual validation.

## Manifest and installation

- Missing, duplicate, unknown, wrong-type, invalid UTF-8, oversized, or unsupported-version fields.
- Invalid IDs, SemVer, durations, dependencies, Homebrew requirements, cycles, source references, config schemas, and duplicate contributions.
- Absolute/parent traversal, symlink escape, case-fold collision, non-executable command, and files changed after validation.
- Huge repositories, submodules, Git LFS placeholders, unsafe file modes, missing commits, network interruption, atomic-install failure, and rollback.
- Permission expansion, license/manifest/catalog mismatch, duplicate installed IDs, complete removal, and incompatible updates.

Validation never executes plugin code. Installer validation should use local repository fixtures and a stub network client; that expanded coverage remains pending.

## Process and watcher

- Spawn failure, closed stdin, fixed environment, working directory, bare `PATH` lookup, and separate stdout/stderr.
- Empty output, plain text, malformed/unknown JSONL, invalid UTF-8, partial final line, mixed event types, and terminal-event/exit-code precedence.
- Exact and over-limit event, state, step, and log sizes; simultaneous stdout/stderr flooding must not deadlock.
- Timeout/cancel before spawn, during output, and at natural exit; `SIGTERM` grace followed by process-group `SIGKILL`, including grandchildren.
- App quit/crash during work, missing working directory, typed-result truncation, secret redaction, and plugin attempts to orphan a process.

## Queue, scheduler, and persistence

- Lock contention, duplicate requests, fairness, skipped overlapping checks, cancellation, and idempotent terminal writes.
- Active work remains published until completion; missing-dependency states persist while preserving previous enablement intent.
- Sleep/wake, wall-clock and daylight-saving jumps, network changes, and skipped overlapping checks.
- First launch, every schema migration, interrupted migration, corrupt database, legacy log cleanup, disk full, backup, restore, and downgrade refusal.
- Restart recovery must distinguish queued, running, interrupted, canceled, failed, and safe-to-retry work.

## Remote boundary

- Bind only to loopback; reject direct LAN/Funnel configuration and spoofed identity headers.
- Missing/revoked tailnet identity, ACL denial, Tailscale outage/reconnect, and concurrent browser sessions.
- CSRF and Origin rejection, escaped plugin text, oversized bodies, slow clients, replayed mutations, and confirmation expiry.
- Exact `requestPluginInstall` shapes (`{repository}` and `{repository, commit, pluginPath, catalogID}`), rejection of community pins, catalog ID/field mismatch, optional catalog `description`, `searchPlugins` query mapping into `pluginSearch.error` with `searchedAt`, and snapshot `installingPluginIDs`.
- Failed remote startup must preserve enabled intent for bounded retry; stale listener/monitor completion must not close a newer instance, and cancellation must not interrupt exact-owned Serve cleanup.
- Installed digests must survive tampered-source reload/disable without accepting those bytes under an approved SHA.
- PWA phone navigation, typed enum/config values, read-only secret guidance, preservation of unsaved drafts across disconnects, confirmation dismissal after earlier acceptance, and disconnected mutation gating.
- Remote native-tool snapshots and mutation shapes, one-use identity-bound process confirmation, PID identity revalidation, named-peer-only SSH probes, and already-authorized notification delivery.
- Remote mode blocks any operation that could open TCC, Keychain, Gatekeeper, license, device-trust, or administrator prompts.

Use an injectable verified-identity boundary in tests. Do not make authorization decisions from caller-supplied HTTP headers.

## macOS lifecycle and UI

- Logout, cold FileVault boot, launch-at-login failure, app relaunch, fast user switching, sleep, power loss, and TCC revocation.
- Empty/loading/error/stale states, unknown saved contribution IDs, incompatible state shapes, long/untrusted text, keyboard-only use, VoiceOver, and narrow phone layouts.
- Loss of a plugin or Tailscale must leave local settings, Doctor, disable, and recovery paths usable.

## Release gate

Before a tagged release: run unit/vertical tests on the minimum supported macOS and current release macOS, exercise signed/notarized installation on a clean account, test FileVault restart expectations on disposable hardware, verify the support bundle contains no secrets, and manually complete every core journey in [product.md](product.md).
