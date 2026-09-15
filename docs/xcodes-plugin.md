# Xcodes and iOS development plugin proposal

**Status:** inventory plugin published at [`github.com/ignaciojuarez/kiwios-xcodes`](https://github.com/ignaciojuarez/kiwios-xcodes). The KiwiOS tree keeps an author copy in [`examples/xcodes/`](../examples/xcodes/). Management actions remain a product/contract proposal.

## Decision

Create a separately maintained `xcodes` plugin that is a small, reviewable wrapper around the [XcodesOrg `xcodes` CLI](https://github.com/XcodesOrg/xcodes). Ignacio Juarez (`@ignaciojuarez`) owns and maintains it at `github.com/ignaciojuarez/kiwios-xcodes`. It is distributed as an ordinary exact-commit plugin, not shipped with KiwiOS. Its first useful release is an **inventory and diagnosis** plugin; a complete remote Xcode installer and Apple-account sign-in are not viable under API 1.

`xcodes` is a reasonable dependency: Homebrew currently distributes the `xcodes` formula for macOS 15 and later, and the tool is intended to list, install, select, and uninstall Xcode versions. Its documented `runtimes` command can list and install simulator runtimes. [Homebrew formula](https://formulae.brew.sh/formula/xcodes) · [`xcodes` usage](https://github.com/XcodesOrg/xcodes/blob/main/README.md)

## What the plugin should show

The wrapper should run fixed, allowlisted commands, transform their output to `kiwios.watch/1` JSON Lines, and show host-owned tables. It must keep only bounded, credential-safe diagnostics and never expose credentials or Keychain contents.

| Surface | Source of truth | Result |
|---|---|---|
| Xcodes tool health | `xcodes version`; Homebrew requirement state | Installed/missing/failed, version, supported/untested version, and actionable error |
| Active developer directory | `xcode-select --print-path`, then `xcodebuild -version` | Current selected Xcode and an explicit broken-selection finding when the path or tools fail |
| Installed Xcodes | `xcodes installed`, with each bundle verified by its `Info.plist`/developer path | Version, bundle path, build, and selected flag; a future management release may add wrapper-observed last-managed time |
| Available Xcodes | `xcodes list` | Stable/beta availability, build, architecture availability, and CLI fetch error |
| Installed simulator runtimes | `DEVELOPER_DIR=<each verified Xcode> xcrun simctl list runtimes --json` | Platform, runtime identifier/version, availability, support state, and the Xcode developer directory queried |
| Simulator device instances | `DEVELOPER_DIR=<each verified Xcode> xcrun simctl list devices --json` | Device name, UDID, runtime, state, unavailable-device state, and the Xcode developer directory queried |
| Available runtimes | `xcodes runtimes` | Platform, version, beta flag, architecture from an optional `[Apple Silicon]|[Universal]|[Intel]` suffix or the host-default filter, and availability |
| Readiness and errors | command exits plus stable, tested diagnostics | Missing `xcodes`, no selected/full Xcode, unsupported macOS/architecture, no network, failed download, Apple authentication required/expired, license/first-launch work required, disk error, or unrecognised CLI output |

“Simulator” needs two separate tables. A **runtime** is an iOS/watchOS/tvOS/visionOS system image; a **simulator device** is an instance created from that runtime. Installing a runtime does not create every device, so treating them as one list would mislead the user.

### “Last used” is not a reliable feature

The plugin can truthfully show the selected developer directory and the last time *this plugin* successfully ran a management action. It must not label either value “last used.” Neither `xcodes installed` nor a supported macOS public API provides a reliable, global “last Xcode launch/use” value, and Spotlight last-used metadata is optional and not equivalent to developer-tool use. If real usage telemetry becomes necessary, it needs a separate, opt-in native capability and privacy design; it is out of scope here.

### Xcodes configuration and Apple-account state

The plugin can give excellent operational status without reading credentials:

- `xcodes` installed and callable; formula/version supported by the wrapper;
- active Xcode selection and command-line-tool readiness;
- whether the most recent requested `xcodes` operation succeeded, required sign-in, required an Apple verification code, or returned another known error; and
- whether an earlier operation was canceled, interrupted, or timed out.

It cannot honestly expose a durable “signed in as …” or “signed out” state. The public CLI documents `signout` and says it remembers an Apple ID/password in Keychain after authentication, but does not document an authentication-status command. The plugin must not inspect `xcodes`' Keychain items merely to infer account state. Its UI should use **Authentication status unknown** until an operation produces a specific, current error, rather than reporting a false signed-in/signed-out result. [`xcodes` authentication and commands](https://github.com/XcodesOrg/xcodes/blob/main/README.md)

## Interaction design

The PWA should use existing `stat`, `table`, `checks`, `actions`, and `log` kinds:

- **Overview:** tool health, selected Xcode, runtime/device counts, and a concise blocking finding.
- **Xcodes:** installed and available version tables.
- **Simulator runtimes:** installed and available runtime tables; a separate device-instance table is linked from this page or shown on its own page.
- **Activity:** active action, coarse phase/progress, cancel control, and redacted bounded log.

The host, not the plugin, provides table layout, loading/error presentation, confirmation, accessibility labels, progress bars, cancellation, and audit attribution.

## Feasibility by feature

| Requested capability | API 1 assessment | Recommended scope |
|---|---|---|
| Display installed Xcodes | Viable | Ship in the inventory release. Parse the CLI conservatively and verify discovered bundles. |
| Display installed runtimes and simulator devices | Viable | Ship in the inventory release using `simctl` JSON, clearly separated as above. |
| Display available Xcodes/runtimes | Viable, parser-sensitive | Ship behind compatibility tests for the supported `xcodes` versions. Cache only plugin-owned, nonsecret metadata if a later refresh fails. |
| Display selected Xcode and configuration errors | Viable | Ship in the inventory release. Use a finding, not a guessed account status. |
| Install missing `xcodes` via Homebrew | Viable | Declare `brew = ["xcodes"]`. KiwiOS detects this requirement and can install the declared core formula after an identity-bound confirmation, including from remote. The formula install is never automatic. Xcode and simulator-runtime **install** remain deferred. |
| Tap **install latest Xcode** | Partly viable | A fixed action could invoke the wrapper, but only after an attended-action path exists. It cannot safely be a normal remote operation because `xcodes` may require Apple sign-in, license/first-launch work, or an administrator password when installing to `/Applications`. |
| Tap an arbitrary Xcode version | Not expressible today | API 1 actions have static argv and tables cannot carry row actions or dynamic action parameters. A text config field plus a static action is a poor fallback, not the requested picker. Add a host-owned dynamic choice/action-input contract first. |
| Tap an arbitrary simulator runtime | Not expressible today | Same dynamic-selection gap. Fixed “latest iOS runtime” actions are possible in principle but should not substitute for a runtime picker. |
| Show live download percentage | Partly viable | `kiwios.watch/1` supports determinate and indeterminate progress. The wrapper can report stable coarse phases (resolve, download, unpack, verify, finish) and forward logs. It must show a percentage only when a tested `xcodes` output format provides a trustworthy byte/percentage value; upstream's human terminal output is not a stable machine API. |
| Cancel a download/install | Viable as a job feature | The host can terminate the plugin process group. The UI must say that downloaded archives or partial app bundles may remain and require an attended inspection/cleanup. |
| Remotely submit Apple ID, password, and 2FA code | Not viable and must not be added to API 1 | Remote Keychain writes are prohibited; plugin stdin is closed; and remote mode may not trigger Keychain, Apple verification, license, Gatekeeper, or administrator prompts. Do not accept Apple credentials in a browser form. |
| Sign in locally through KiwiOS | Not available as a simple wrapper | API 1 has no interactive stdin/PTY/credential-exchange protocol for plugins. A future, explicitly local native authentication handoff could make this possible, but it needs its own threat model and contract. |
| Marketplace/store discovery and installation | Featured catalog plus community topic search | Discover on the Plugins tab can Featured-install the cataloged `kiwios-xcodes` commit or community-search `kiwios-plugin`. A ratings/store marketplace remains out of scope. |

This conservatism is required by KiwiOS policy: arbitrary Homebrew mutations and Keychain writes remain attended. An approved plugin's exact currently missing core formulae may be installed after identity-bound remote confirmation. Remote mode must fail closed rather than cause a macOS, Xcode, or Apple sign-in prompt. Inventory probes `xcodebuild -checkFirstLaunchStatus` before `xcodebuild -version` / `simctl`; a blocking Aqua dialog remains a residual risk if a tool prompts without that probe covering it. [Permissions boundary](permissions.md) · [Marketplace state](marketplace.md)

## Required KiwiOS work before management actions

The inventory plugin does not require a protocol change. The requested install workflow does. Do not hide these gaps inside an increasingly privileged shell wrapper.

1. Add an action execution scope such as `attended-only` to the public manifest and host admission policy. The PWA must render its reason and disable that action remotely; the compact attended surface needs a way to start and follow that action. Today, plugin content is PWA-only, while API 1 has no per-action local-only declaration.
2. Add host-owned dynamic action inputs/choices, populated from a bounded check result. This enables an accessible **Install** control on each available Xcode/runtime row without allowing plugin HTML or arbitrary request payloads. The host must bind the selected opaque item to the confirmation and revalidate it immediately before execution.
3. Define a stable way for an action to report whether it may open a license/first-launch/admin dialog, and keep it attended-only. The wrapper must use a user-writable target only when that is an explicitly supported, verified `xcodes` mode; it must never attempt `sudo` or synthesize a password.
4. If local Apple authentication remains a product goal, design a narrow native `interactive-auth` capability. It should be available only in an attended Aqua session, show provenance and the exact requesting plugin/action, keep credentials out of argv, stdout, stderr, SQLite, and plugin configuration, and support cancellation/timeouts. It must not be reachable through Tailscale Serve. This is not a generic terminal or remote-password capability.

The first two changes are also useful for other dependency/version-manager plugins. The fourth should be deferred until there is a real local workflow that cannot use Apple’s own Xcode/App Store sign-in UI.

## Proposed delivery sequence

### Release A — external inventory plugin (reference implementation complete)

- Move the repository-shaped reference implementation from `examples/xcodes/` to `github.com/ignaciojuarez/kiwios-xcodes`, enable private vulnerability reporting, and publish a tested exact commit.
- Require `native.jobs = "1"`; declare `brew = ["xcodes"]`; disclose execution of `xcodes`, `xcode-select`, `xcodebuild`, and `xcrun`, plus the narrow paths and network access the reviewed wrapper actually uses.
- The reference implementation provides tables and diagnostic checks only. Catalog tables are fixture-tested against `xcodes` 2.1.x unlabeled `version (build)` rows; Homebrew core currently bottles 2.1.0. Keep the plugin inactive until its Homebrew requirement is fulfilled. The host can install that declared core formula after identity-bound confirmation, including from remote.
- Let users install it today by reviewing its canonical GitHub HTTPS repository, full commit SHA, and path through the normal plugin flow. Do not call this a store listing.

### Release B — attended fixed actions

After an `attended-only` action contract exists, add confirmed actions for a deliberately small set such as refresh catalog, select an already-installed Xcode, and install the latest stable Xcode/runtime. Each action streams phase progress and has a conservative timeout, output bound, cancellation path, and post-action verification.

### Release C — dynamic version/runtime picker

After dynamic host-owned choices exist, connect each available-version/runtime row to an attended-only confirmation. The wrapper re-fetches/revalidates the named item after confirmation so a stale catalog row cannot change what is installed.

### Deferred — local Apple sign-in handoff

Only consider this after Release B/C has proven the installer path. It requires a separate native security design and manual test plan; it is not a plugin-only change. Remote credential entry, browser-based 2FA entry, and remote macOS prompt handling remain rejected.

### Separate Marketplace milestone

Discover Featured plus community topic search is the current distribution surface. Ratings, payments, and a hosted store remain out of scope. Catalog updates still require a new exact commit; do not add a draft or moving branch to `catalog.json`.

## Reliability and acceptance checks

- Fixture-test every supported `xcodes` table/error form and the `simctl` JSON decoder; an unrecognised CLI format becomes a readable unavailable/error state, never an incorrect install target.
- Test no `xcodes`/Homebrew, Homebrew unavailable, formula install canceled/failed, no full Xcode, broken selected path, no runtimes, unavailable devices, offline catalog fetch, insufficient disk space, and each known auth/license/first-launch diagnostic.
- Test live phase updates, cancellation during download/unpack, timeout, interrupted KiwiOS restart, and post-action reconciliation of Xcode/runtime/device lists.
- Verify logs and Events redact any Apple account material and never include values from an interactive-auth handoff if one is later introduced.
- Manually exercise a signed KiwiOS build on a clean account. Confirm that every dependency install, Apple sign-in, license acceptance, and administrator prompt is possible only in an attended Aqua session, while remote clients see an explicit blocked reason.

## Non-goals

- No automatic Xcode/runtime updates, background downloads, `sudo`, password storage in plugin config, browser credential forms, or remote 2FA.
- No access to an Apple ID's Keychain items merely to show an account name or guessed login state.
- No claim that a simulator runtime installed through one Xcode configuration is universally usable by every installed Xcode.
- No app/device build, signing, provisioning, simulator creation, app installation, or test-running features in this plugin. Those are candidates for separate, narrowly scoped iOS-development plugins after this inventory/installer contract is stable.
