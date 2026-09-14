# Changelog

All notable user-visible changes will be recorded here.

## Unreleased

- Surface cancellation for running checks, actions, Watcher starts, and native jobs in the PWA. Permit a confirmation-bound, prompt-free remote restart of one revalidated current-user LaunchAgent; Homebrew and privileged restart remain attended-only.
- Compact the Home dashboard into a responsive two- or four-column grid with declared one- and two-column widget widths, including on phones; it never uses three columns. Make orange (`#FF6100`) the second accent color, including Home layout controls and the add-widget tile. Replace the long Home configuration card with an edit mode that supports direct mouse, touch, and keyboard drag-and-drop plus removal and a blueprint add tile; refresh installed PWA shells immediately so the old oversized layout does not linger.
- Make the web Plugins view a complete lifecycle control surface: reload, disable, approved-source retry, and staged immutable GitHub install/update run through reviewed, identity-bound one-use confirmations. Remote removal has its own review, retains all Homebrew packages, and deletes only interaction-disabled Keychain config accounts; prompt-capable recovery remains attended. Suppress duplicate plugin failure copy in check/action cards.
- Add a remote Retry/Enable control for unchanged, locally approved disabled plugins; clearly route missing Homebrew dependencies, new sources, and changed code to Attended Setup without allowing remote Homebrew mutation.
- Replace the full macOS window with a no-Dock-icon menu-bar service and a compact attended-setup window. Move Home, plugin pages, Events, Tools, Brew, layout, Doctor, and public plugin settings into the tailnet PWA; add guarded browser operations for process termination, named SSH probes, and already-authorized notifications.
- Redesign the PWA around the supplied terminal-workbench references: near-black gridded surfaces, monospaced typography, hairline panels, geometric icons, restrained kiwi/amber status color, segmented progress bars, shorter copy, and persistent responsive navigation.
- Remove the unreachable native dashboard, Events, Brew, Tools, Home, and duplicate plugin-rendering code after the web-primary migration.

- Keep exact-owned Tailscale Serve cleanup running when its UI or health-monitor task is canceled, avoiding a false `Swift.CancellationError` recovery warning.

- Add a dedicated Brew sidebar tab with a searchable four-column installed inventory, local app icons for casks, formula install reasons, versions, dependency relationships, and existing confirmed update/upgrade actions.

- Use the bundled Icon Composer design as the macOS app icon.
- Use the supplied kiwi artwork for the native app icon, PWA icons, and favicon; show it in attended setup and bring that window to the front when opened from the menu bar.
- Move Home/sidebar customization onto Home, repair layout actions dropped behind polling, prune stale contribution IDs after reload, and prevent polls from rendering partial reload state or rebuilding unchanged pages.
- Give Tools refresh an inline collecting state instead of a misleading Saving warning; color Events terminal lines by their written severity; use the transparent pixel kiwi in the sidebar and remove the decorative top rule.

- Keep Home stat widgets stable while checks refresh, hide their result timestamp and descriptive source metadata, and omit timestamps from routine check rows.

- Harden Homebrew ownership with exact receipt identities and disabled automatic cleanup/upgrade behavior; keep admitted confirmations valid through queueing and return a plugin to Not Added when dependency installation fails. Centralize Doctor host readiness, reject unsupported TCC declarations, refresh diagnostics on lifecycle changes, and recover desired Tailscale publication with atomic journaling, bounded retry, and exact shutdown cleanup.

- Remove the native and tailnet Jobs sections; actions continue to run through the durable queue and expose current state through their owning plugin views.

- Ignore local `.build` products, add an explanatory removable-volume usage string, support stable local signing in the run helper, and stop Monitor from addressing mounted paths merely to derive friendly drive names.

- Add an optional Watcher plugin backed by validated per-plugin `[watch]` status/start references, plus a separate terminal-style Events tab using the shared log/warning/error protocol. Keep routine checks as latest-result state rather than visible or durable job history.

- Make Remove delete all KiwiOS-owned plugin content for bundled, development, and repository plugins; associate Homebrew installs with their originating plugin, return canceled/failed dependency setup to Add, and consider only added plugins when deciding whether an owned formula is unused.

- Filter synthetic macOS filesystems from Volume Health, remove stale native Monitor scaffolding and personal signing metadata, and replace the private run helper with a self-contained `scripts/run.sh`.

- Simplify plugins to one Add/Remove control, hide inactive plugin contributions from Home and navigation, keep routine monitoring checks out of Jobs and separate log files, simplify application quit controls, fix Volume Health on macOS awk, and remove the bundled Backup Status plugin.

- Fix Monitor drive temperatures for smartmontools versions that report Apple Silicon NVMe devices with `IOService:` paths, and show mounted macOS volume titles when available.

- Fix app-bundled plugins being reported as source conflicts after the KiwiOS app moves to a new build or installation directory.

- Replaced the permanent native Monitor with an optional bundled plugin for CPU, memory, thermal pressure, and SMART drive temperatures; removed uptime. Plugins can now declare Homebrew core formula requirements, and KiwiOS can install missing formulae after showing the exact list and receiving local confirmation. KiwiOS records only formulae it installed and offers safe, explicit cleanup during plugin removal while retaining pre-existing, shared, depended-on, or unverifiable packages.

- Fixed remote readiness on macOS: use the CoreGraphics session-key constants and provide a shell marker when invoking the Tailscale app executable in CLI mode.

- Verified an Xcode 27 unsigned Debug build, all 43 tests, application launch, and graceful quit. Fixed Swift 6/compiler compatibility, restored required persistence helpers, and corrected plugin fingerprinting across canonical filesystem path aliases. Updated approval and timeout fixtures to use isolated storage.

- Remediated the 27 codebase-audit findings: safe integer configuration, policy/admission races, unconditional disable cancellation, drained startup/shutdown, dependency recovery, and durable per-plugin summaries.
- Added revisioned configuration patches with stale-save conflicts, serialized Keychain changes and interrupted-write recovery; uninstall now drains work, records pending cleanup, and removes owned credentials when retention is disabled. Activation remains retryable and inactive snapshots are pruned.
- Isolated invalid discovery candidates; fixed Serve publication recovery, executable rediscovery, absolute session expiry and session-capacity handling. Remote request budgets now govern cooperative work/admission without detaching accepted mutations.
- Fixed native/PWA form parity and duplicate editors, PWA progress steps, stale Tools snapshots, bounded LaunchAgent inspection, and SSH peer save recovery. Documented ambient SSH configuration trust and explicit SIGTERM semantics.
- Consolidated subprocess mechanics, batched presentation reads, grouped native/remote view state, split native screens and UI-data parsing, and removed unused scheduling/decoding/persistence adapters. Synced generated project sources. Build and test validation was completed in the subsequent Xcode 27 run.

- Added a loopback Hummingbird 2.26.0 backend and six-kind tailnet PWA with verified Serve identity, origin/CSRF checks, one-use confirmations, bounded requests, and durable job attribution.
- Added explicit Tailscale publication and exact-ownership recovery. Failed startup closes the listener and owned mapping while retaining the user's enabled intent for bounded recovery; stale server callbacks cannot stop a replacement listener, and publication/teardown transitions are serialized.
- Added native Monitor and Tools for host snapshots, guarded process controls, attended LaunchAgent/Homebrew work, saved SSH peer probes, power status, and notifications.
- Added GitHub discovery, exact-commit staging/review/install/update/removal, config retention, and an empty bundled curated catalog with a review policy. Installed content remains bound to the approved source and SHA across reloads and disable operations.
- Added Home setup guidance, actionable Doctor and Tailscale readiness, and interrupted-action recovery. Active work remains visible through its owning plugin, and missing-dependency lifecycle changes persist without changing enablement intent. The PWA includes Events and Status & setup, disables disconnected actions, preserves unsaved form drafts across disconnects, and keeps secret fields in attended setup.
- Added a generic volume-health plugin plus a copyable six-kind plugin template and author-to-install documentation.
- Updated implementation status for roadmap phases 2–5. MCP and external catalog publication remain deferred. No builds or tests were run for this pass while Xcode installs.

- Completed the local-platform implementation: strict dependencies, permission disclosures, config schema and form validation, and discovery of all bundled plugins plus one selected development directory.
- Added source-bound manifest/content approval, explicit enable/disable, expiring one-use action confirmation, dependency gates, and revalidation before each command.
- Added typed Watcher state, live progress and steps, sourced logs, protocol warnings, and distinct success/warning/failure/timeout/cancellation/interruption outcomes, including partial canceled output.
- Added GRDB 7.10.0, one WAL migration chain, bounded resource-locked actions and interval checks, an action audit trail, bounded in-memory output capture, and interruption recovery without automatic action replay.
- Added native rendering for all six UI kinds, saved Home/sidebar layout, configuration forms, setup/remote policy, prompt-free Doctor, launch-at-login registration, and graceful job cancellation on quit.
- Added Keychain-backed named and write-only config secrets, temporary `0600` delivery, exact-value stream redaction, and atomic private config files. The draft contract now rejects write-only defaults and specifies approved-source and table-shape bounds.
- Added regression sources and updated existing runtime fixtures for explicit approval. Build and test execution for this implementation is deferred until Xcode is installed.

- Added public contribution and security guidance.
- Added Xcode 27 continuous integration for tests and the example plugin.
- Clarified that plugins are trusted executable code and that KiwiOS operates after login behind Tailscale Serve.
- Added the first local plugin slice: bundled loading, TOML decoding, initial validation, bounded command execution, Watcher events, live status, confirmation, and tests.
- Fixed descendant process leaks and caller-cancellation handling by adopting process-group-aware Swift Subprocess teardown.
- Fixed duplicate plugin runs, strict SemVer prerelease validation, malformed Watcher warnings, executable-path validation, and generated-project drift checks.
- Added strict validation for manifest metadata, checks, actions, durations, non-form UI descriptors and sources, and referenced local executables.
- Marked API 1 as a pre-release draft and reconciled Watcher limits and build-host documentation.
- Defined fail-closed Serve identity handling and a link-safe, source-bound exact-commit install design.

## 2026-09-11

- Created the initial macOS app shell, architecture documents, and `hello-check` example plugin.
