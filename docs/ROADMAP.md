# Roadmap

Each phase ends in a working vertical slice. The API 1 plugin and watcher documents are pre-release drafts; freeze them and require explicit version bumps only after validator conformance and real-plugin testing.

## 0 — public foundation

- [x] no-Dock-icon macOS menu-bar shell and MIT license
- [x] authoritative product, architecture, development, testing, plugin, watcher, UI, permission, operations, and catalog docs
- [x] tiny `hello-check` source fixture
- [x] public build prerequisites and contributor guide
- [x] `SECURITY.md` with vulnerability-reporting guidance and the trusted-plugin threat model
- [x] CI build and local runtime tests

## 1 — local plugin platform

Implementation of 1A–1D is present in the working tree. Unsigned Xcode 27 build and unit-test execution have passed; checked implementation items do not claim the remaining signed-app and manual release gates passed.

### Completed foundation

- [x] Decode the core `kiwios_api = "1"` metadata, checks, and actions.
- [x] Bundle/load `hello-check`; run a real check and require confirmation in the host-owned UI before its sample action.
- [x] Add bounded local execution, process-group timeout/cancellation, and initial `kiwios.watch/1` decoding.
- [x] Add initial regression tests for SemVer, malformed output, unsafe executable paths, descendant teardown, and duplicate-run admission.

### 1A — contract-complete loading

- [x] Strictly decode and validate the current manifest surface: metadata, checks, actions, durations, non-form UI descriptors and sources, and referenced local executables.
- [x] Define and validate required dependencies, disclosed permissions, and the supported config-schema subset.
- [x] Discover every bundled plugin and one explicitly selected development directory; reject duplicate IDs and source conflicts without executing plugin code.

Optional-dependency contribution behavior and supervised-child declarations are deferred until real consumers establish their requirements.

### 1B — typed run results

- [x] Retain typed Watcher state, progress, logs, protocol warnings, and terminal outcomes for each check and action.
- [x] Validate exact event, state, step, and log boundaries and honor distinct check/action timeout defaults and overrides.
- [x] Represent succeeded, warning, failed, timed-out, canceled, and interrupted runs separately.

### 1C — durable jobs and policy

- [x] Add one GRDB migration chain for plugin records, approvals, jobs, audit entries, latest results, config, and layout.
- [x] Route checks and actions through one queue with resource locks, scheduling, cancellation, bounded file logs, and restart recovery.
- [x] Centralize confirmation and authorization; implement enable/disable, disclosure approval, temporary secret delivery, and log redaction.

### 1D — web-primary host UI and attended setup

- [x] Render all seven API 1 kinds in the PWA: `stat`, `checks`, `actions`, `table`, `log`, `form`, and `watchers`.
- [x] Add setup/remote mode and Doctor without prompting remotely.
- [x] Replace the native dashboard with a menu-bar status surface and compact attended setup for prompt-capable work.
- [ ] Complete and run dependency, symlink-race, scheduling, persistence, authorization, accessibility, and recovery validation under Xcode 27. Regression sources cover manifest/config/dependency and watcher behavior; runtime fixtures now use explicit approval. Signed-app, VoiceOver, sleep/wake, permissions, and crash/recovery journeys remain release gates.

Current setup limits are explicit: API 1 accepts Accessibility and Screen Recording because they have prompt-free probes; unprobeable TCC prerequisites are rejected by manifest validation. Repository installation and exact Git revisions are implemented in phase 4; local approvals bind the selected source directory and exact manifest/content digests.

Exit: a technical user can clone, build, validate, explicitly enable `hello-check`, invoke it through the durable runtime, and understand every permission and failure state without Tailscale.

## 2 — remote UI

- [x] Add one embedded loopback HTTP server and a responsive PWA for all seven UI kinds.
- [x] Implement explicit publication through KiwiOS-owned, tailnet-only Tailscale Serve, with ownership checks on startup and recovery.
- [x] Implement identity-bound sessions, origin/CSRF checks, one-use confirmations, audit attribution, and replay protection.
- [x] Add persistent phone navigation, plugin-owned action state, Events, Tools, Brew, Plugins, and Settings with Doctor findings.
- [x] Add web layout/configuration parity and guarded prompt-free native operations without exposing arbitrary PIDs, SSH destinations, or notification authorization.
- [x] Disable mutations when disconnected, label old results, preserve focused configuration edits during polling, and keep secrets in attended setup.
- [ ] Verify transport/security and exercise phone, desktop browser, sleep/wake, logout/login, and FileVault restart behavior after Xcode is ready.

Exit remains unverified: after login, a tailnet administrator can inspect status and run a confirmed action from a phone; before login, the product states that it is unavailable.

## 3 — useful host capabilities

- [x] Implement optional CPU, memory, Apple-silicon CPU/GPU-temperature, thermal, and SMART drive-temperature checks as the bundled Monitor plugin; Home includes CPU-temperature, GPU-temperature, and hottest-drive widgets, and uptime is intentionally omitted.
- [x] Implement bounded process controls, LaunchAgent status, saved SSH peer probes, power checks, and notifications in web Tools, plus an installed formula/cask inventory in web Brew.
- [x] Require attended setup for prompt-requiring operations and explicit native confirmation where applicable; privileged restart remains unsupported.
- [x] Add a web Home setup journey derived from Doctor, plugin enablement, launch-at-login, and actual remote availability.
- [ ] Exercise native services and permission/lifecycle recovery on macOS after Xcode is ready.

Prompt-free, identity-bound operations can run from the PWA. The PWA can also stage immutable plugin source and require a reviewed confirmation, confirm the local install of an approved plugin's exact missing declared formulae, and remove KiwiOS-owned plugin content without Homebrew cleanup when Keychain cleanup remains interaction-disabled. Other Homebrew mutations, notification authorization, secret creation or updates, and other prompt-capable operations remain in attended setup. Network inventory and macOS update management are later capabilities and are not advertised as implemented.

## 4 — discovery and explicit install

- [x] Implement repository-plus-exact-SHA staging, review, install/update, and complete KiwiOS-owned-content removal.
- [x] Expose the implemented cached/rate-limited GitHub discovery through the web-primary Plugins Discover section; exact-SHA installation remains the reviewed PWA flow and attended setup.
- [x] Show source, commit, license, dependencies, and disclosure changes before trust; bind activation to approved repository, commit, and digests.
- [x] Prepare a strict bundled catalog format and pull-request review policy, and seed reviewed exact commits from dedicated plugin repositories.
- [x] Add a copyable plugin template and a menu-bar/web author-to-install walkthrough.
- [ ] Publish and maintain the curated catalog as an external repository. The bundled `catalog/catalog.json` remains the signed in-app source of featured entries.
- [ ] Validate install/update interruption, incompatible config, source tampering, and removal/reinstall recovery after Xcode is ready.

No source repository was published or plugin installed during this implementation pass. The standalone validator CLI remains future work; local validation currently uses the app.

## 5 — first real plugins

- [x] Add a generic volume-health plugin with a configurable threshold and actionable status.
- [x] Use their contributions and the author template to exercise the standard data/action UI shapes in source.
- [ ] Run them on representative macOS hosts and use that evidence to decide whether the draft contracts are sufficient.

Do not add plugin-to-plugin IPC or an SDK until repeated code demonstrates the missing stable interface.

## 6 — MCP, deferred

MCP is explicitly excluded from the current work at the owner's request. Reconsider supervised MCP entries and a confirmed gateway only if a real need emerges after core process, permission, and HTTP paths are stable. See [mcp.md](mcp.md). MCP is not part of `kiwios_api = "1"`.

## Later, only with evidence

Additional roles, theme packs, richer charts, a sandboxed plugin runner, resumable jobs, root helper, package hosting, ratings, automatic updates, language SDKs, and a brokered plugin API.

## Explicit non-goals

Docker, arbitrary plugin HTML, public Funnel exposure, MDM, high availability, pre-login service, and a second native client shell.

## Audit remediation — 2026-09-12

The [codebase audit](audits/2026-09-12-codebase-audit.md) has an accompanying [implementation record](audits/2026-09-12-remediation.md) covering all 27 findings, recovery and policy decisions, and structural cleanup. Source changes do not complete the outstanding Xcode, signed-app, accessibility, browser, or crash/recovery gates. MCP remains deferred.
