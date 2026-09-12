# Architecture

KiwiOS is an after-login control plane for one Mac. It is a signed macOS app, not an operating system, boot daemon, container runtime, or multi-host orchestrator.

The README states what exists today. Unimplemented components below are target boundaries, not claims about the current build.

```text
phone / laptop              local Mac
      |                          |
Tailscale Serve HTTPS        native UI
      |                          |
      `----------> KiwiOS.app <-'       one Aqua user agent
      |- HTTP + PWA              one UI on every device
      |- plugin runtime          validate, enable, execute
      |- watcher + jobs          schedule, supervise, log, cancel
      |- native capabilities     host operations plugins may require
      |- SQLite + files          state, audit, plugin data
      `- Keychain                named secrets
              |
              `- trusted plugin commands
```

## Availability boundary

KiwiOS starts as the owning user's LaunchAgent and runs in that user's Aqua session. It is available only after that user logs in. After a cold FileVault restart, somebody must unlock the Mac before KiwiOS, its PWA, checks, and jobs can run. Planned restarts may use `fdesetup authrestart` when the host is eligible.

This boundary is deliberate: GUI applications, TCC grants, Keychain access, and developer tools belong to the Aqua user. KiwiOS does not pretend to be a pre-login or highly available service.

## Public contracts

There are two versioned public contracts:

1. `plugin.toml`, selected by `kiwios_api = "1"`, declares metadata, requirements, disclosed permissions, commands, and UI descriptors.
2. `kiwios.watch/1` is JSON Lines emitted by checks, actions, and jobs.

KiwiOS executes declared argv; it never imports plugin code. Plugin commands may be written in any language available on the Mac. Plugin-to-plugin dependencies are presence/version gates only in API 1, not an IPC mechanism.

## Trust boundary

Plugins are trusted code running as the KiwiOS user. The app is intentionally not App Sandbox-enabled, so a plugin process can exercise that user's ambient access. Manifest permissions disclose intent and gate capabilities brokered by KiwiOS; they are not a sandbox for arbitrary child-process behavior.

Unreviewed GitHub-topic plugins and locally added folders require explicit trust. The curated catalog records reviewed repository commits, but is not a security guarantee. See [permissions.md](permissions.md) and [marketplace.md](marketplace.md).

## Native capabilities

Plugins may require versioned native capabilities. In API 1 a dependency means “do not enable unless this capability is present at a compatible version.” It does not create a callable Swift or HTTP API.

| Capability | Responsibility |
|---|---|
| `native.jobs` | queue, lock, log, cancel |
| `native.watcher` | scheduled checks and typed run results |
| `native.monitor` | CPU, memory, uptime, thermal and disk status |
| `native.processes` | process and Aqua-app status/actions |
| `native.launchd` | user/system service status/actions |
| `native.volumes` | mounted volumes and free space |
| `native.network` | interfaces and listening ports |
| `native.power` | session, sleep, FileVault and planned restart checks |
| `native.brew` | formula and cask status/actions |
| `native.tailscale` | status, identity and the single Serve configuration |
| `native.ssh` | named peers only |
| `native.auth` | Serve identity, origin and CSRF validation |
| `native.secrets` | named Keychain values |
| `native.notify` | notification outbox |
| `native.update` | macOS update discovery and confirmed application |
| `native.http` | loopback Serve backend and PWA surface |
| `native.mcp` | future MCP supervision and gateway |

Capabilities version independently. A breaking behavior change increments that capability's integer version.

## Plugin discovery and storage

KiwiOS reads plugins from three explicit sources:

1. bundled plugins shipped in the app;
2. installed, exact-revision plugin snapshots under Application Support;
3. an optional development directory selected in Settings.

Duplicate plugin IDs are errors. KiwiOS never scans arbitrary folders and never silently chooses one duplicate over another.

```text
~/Library/Application Support/KiwiOS/
  config.toml
  KiwiOS.sqlite
  InstalledPlugins/<id>/<commit>/
  PluginData/<id>/
  MCP/<id>/
  Logs/
```

KiwiOS never intentionally edits an installed plugin snapshot. Before launch it verifies the approved source, commit, manifest, and content digest and disables a changed snapshot. This is tamper detection, not containment: trusted code running as the same user can modify user-owned files. Config and data survive a code update. Secrets live in Keychain, not these files. Uninstall asks whether to retain or remove `PluginData/<id>`.

## UI and network

KiwiOS owns navigation, layout, confirmation, accessibility, and rendering. Plugins contribute typed descriptors and JSON data; they cannot ship HTML, CSS, JavaScript, or iframes. The macOS window and remote PWA use the same information architecture. See [ui.md](ui.md).

KiwiOS owns one loopback HTTP listener used only as the backend for one optional tailnet-only Tailscale Serve origin. The native UI calls the app directly rather than treating loopback HTTP as an authenticated browser endpoint. Remote mutation requires Serve-provided human identity, same-origin and CSRF checks; missing identity and tagged-node requests fail closed. Plugins do not bind public listeners or configure Serve. Tailscale Funnel is unsupported. A malicious same-user process spoofing the loopback backend remains outside the documented v1 boundary.

## Deliberate non-goals

No Docker runtime, plugin webviews, event bus, root daemon, multi-user roles, public marketplace, automatic plugin updates, or language SDK in API 1. Add an SDK only after multiple plugins duplicate a stable helper; add a brokered plugin API only after a real integration needs one.
