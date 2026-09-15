# Architecture

KiwiOS is an after-login control plane for one Mac. It is a signed macOS app, not an operating system, boot daemon, container runtime, or multi-host orchestrator.

The implemented surface runs in the owning user's login session and can publish one optional tailnet UI:

```text
macOS menu bar + attended setup
      |
 KiwiOS.app                    one background Aqua user application
      |- discovery + policy    validate, fingerprint, approve, enable
      |- checks + job queue    observe, schedule, lock, supervise, cancel
      |- plugins + tools       host checks and confirmed operations
      |- Doctor                prompt-free host and plugin checks
      |- SQLite WAL + files    state, audit, results, plugin data, logs
      `- Keychain              named and write-only configuration secrets
              |
              `- approved trusted plugin commands

tailnet browser                primary administration UI
      |
Tailscale Serve                verified identity, HTTPS origin
      |
127.0.0.1 KiwiOS backend       session, CSRF, and request replay checks
```

The loopback HTTP server, tailnet PWA, and exact-revision repository installation are implemented in the working tree. Their Xcode 27 and signed-app release gates remain deferred. MCP supervision is outside the current implementation.

## Availability boundary

KiwiOS runs in the owning user's Aqua session without a Dock icon. Its menu-bar item opens the tailnet web UI and a compact attended setup window. Attended setup can register or unregister the app as a login item through `SMAppService`, and Doctor reports whether registration is enabled, blocked on approval, missing, or unknown. KiwiOS is available only after that user logs in. After a cold FileVault restart, somebody must unlock the Mac before KiwiOS, checks, and jobs can run. Remote service preserves this boundary; privileged restart support is not implemented.

This boundary is deliberate: GUI applications, TCC grants, Keychain access, and developer tools belong to the Aqua user. KiwiOS does not pretend to be a pre-login or highly available service.

## Public contracts

There are two versioned public contracts:

1. `plugin.toml`, selected by `kiwios_api = "1"`, declares metadata, requirements, disclosed permissions, commands, and UI descriptors.
2. `kiwios.watch/1` is the shared JSON Lines event protocol emitted by checks and actions.

KiwiOS executes declared argv; it never imports plugin code. Plugin commands may be written in any language available on the Mac. Plugin-to-plugin dependencies are presence/version gates only in API 1, not an IPC mechanism.

## Trust boundary

Plugins are trusted code running as the KiwiOS user. The app is intentionally not App Sandbox-enabled, so a plugin process can exercise that user's ambient access. Manifest permissions disclose intent and gate capabilities brokered by KiwiOS; they are not a sandbox for arbitrary child-process behavior.

Bundled plugins and plugins from the selected development directory require explicit approval before execution. The web review is bound to the verified tailnet identity and the exact source fingerprint; the attended sheet remains available for local recovery. Approval records the canonical source path, manifest digest, full content digest, and disclosure digest. KiwiOS revalidates the source and digest immediately before launch and disables changed content. Installed plugins bind approval to the canonical repository and exact commit as well as manifest/content digests. The bundled curated catalog is present but empty. See [permissions.md](permissions.md) and [marketplace.md](marketplace.md).

## Native capabilities

Plugins may require versioned native capabilities. In API 1 a dependency means “do not enable unless this capability is present at a compatible version.” It does not create a callable Swift or HTTP API.

| Capability | Responsibility |
|---|---|
| `native.jobs` | queue, lock, log, cancel |
| `native.watcher` | scheduled checks and typed run results |
| `native.processes` | regular Aqua-app status and guarded termination |
| `native.launchd` | current-user LaunchAgent status and confirmation-bound restart |
| `native.network` | interfaces and listening ports |
| `native.power` | low-power and FileVault status; privileged restart remains unsupported |
| `native.brew` | formula and cask status plus attended update/upgrade |
| `native.tailscale` | status, identity and the single Serve configuration |
| `native.ssh` | named peers only |
| `native.auth` | Serve identity, origin and CSRF validation |
| `native.secrets` | named Keychain values |
| `native.notify` | notification outbox |
| `native.update` | macOS update discovery and confirmed application |
| `native.http` | loopback Serve backend and PWA surface |
| `native.mcp` | future MCP supervision and gateway |

Capabilities version independently. A breaking behavior change increments that capability's integer version.

The current runtime advertises `native.jobs`, `native.watcher`, `native.secrets`, `native.processes`, `native.launchd`, `native.power`, `native.brew`, `native.ssh`, and `native.notify`, alongside the implemented remote capabilities. `native.network`, `native.update`, and `native.mcp` remain future boundaries.

The web Brew view reads the installed formula and cask inventory from `brew info --installed --json=v2`, including versions, formula install reasons, dependency relationships, and outdated state. Web Tools shows regular applications, at most 50 owned plists from `~/Library/LaunchAgents`, FileVault and low-power state, named SSH peers, and notification authorization. Remote policy permits prompt-free process termination, confirmation-bound restart of a revalidated current-user LaunchAgent, configured SSH probes, delivery through an already-authorized notification outbox, and a confirmation-bound local install of an approved plugin's exact missing declared Homebrew formulae. Homebrew updates, upgrades, uninstalls, notification authorization, and SSH allowlist edits remain attended. The bundled optional `monitor` plugin reports CPU and memory use, Apple-silicon CPU and GPU temperatures, thermal pressure, and SMART drive temperatures; its Home widgets include CPU temperature, GPU temperature, and the hottest readable drive. `volume-health` is an additional generic consumer of the plugin UI kinds. Plugins declare required Homebrew core formulae. KiwiOS reports their installed state, can install missing formulae through a separately confirmed local job, and records only those installs for ownership-aware cleanup when a plugin is removed.

Native actions use the same durable job queue as plugin actions. A queued operation is revalidated immediately before execution. Process termination is limited to the current user's non-Apple regular applications installed under `/Applications` or `~/Applications`, and PID, start time, executable path, display name, and bundle identity must still match. Remote LaunchAgent restart requires a one-use confirmation and repeats the current-user regular-plist, ownership, and duplicate-label checks at confirmation, admission, and execution; it only runs `launchctl kickstart -k`. The sole remote Homebrew mutation is a confirmation-bound install of an approved plugin's current declared missing core formulae; other Homebrew mutations require attended setup. SSH jobs store and resolve only a configured peer name, then run with batch mode, strict host-key checking, one connection attempt, and a bounded timeout. Notification authorization is requested only during attended setup; delivery requires an already authorized local outbox. KiwiOS has no privileged restart helper and does not invoke `sudo`.

## Plugin discovery and storage

KiwiOS currently reads plugins from three explicit sources:

1. bundled plugins shipped in the app;
2. an optional development directory selected in attended setup;
3. installed snapshots selected by an approved exact-commit database record.

Invalid candidates are reported individually while healthy plugins remain available. Every duplicate-ID or source-conflict contender is excluded. Duplicate plugin IDs are errors. KiwiOS never scans arbitrary folders and never silently chooses one duplicate over another.

```text
~/Library/Application Support/KiwiOS/
  KiwiOS.sqlite
  KiwiOS.sqlite-wal             while the database is open
  KiwiOS.sqlite-shm             while the database is open
  PluginData/<id>/
    config.json                 derived public config passed to the plugin
  InstalledPlugins/<id>/<commit>/   approved immutable source snapshots
```

SQLite stores plugin records and state, digest-bound approvals, user-started action metadata and audit entries, latest typed results, public configuration, home layout, setup/remote policy mode, and the selected development directory. Routine checks retain only their latest typed result, and no execution creates a separate log file. `config.json` is atomically derived from public configuration immediately before execution; write-only values and named secrets live in Keychain.

Before launch KiwiOS verifies the approved source path, manifest, and content digest and disables changed source. This is tamper detection, not containment: trusted code running as the same user can modify user-owned files. Installed snapshots under `InstalledPlugins/` remain bound to their approved Git revision. Reload and disable preserve those recorded digests even if files change. Remove deletes all KiwiOS-owned content for that plugin; bundled and development source folders remain at their original owner and become available to Add again.

## UI and network

KiwiOS owns navigation, layout, confirmation, accessibility, and rendering. Plugins contribute typed descriptors and JSON data; they cannot ship HTML, CSS, JavaScript, or iframes. The tailnet PWA is the full day-to-day interface; the menu-bar app contains only status, launch, and attended setup/recovery. See [ui.md](ui.md).

The attended menu-bar UI calls the runtime directly. The web surface uses one fixed loopback HTTP listener behind one KiwiOS-owned, tailnet-only Tailscale Serve origin. It requires Serve-provided human identity plus exact host/origin, session, CSRF, replay, content-type, size, and rate checks for remote mutation; missing identity and tagged-node requests fail closed. The remote contract exposes prompt-free Doctor, layout, plugin operations including reviewed source approval, confirmed installation of declared missing formulae, staged exact-SHA install/update, plus reviewed removal without Homebrew cleanup, process, current-user LaunchAgent restart, configured SSH, and authorized notification operations; prompt-capable native work stays attended. Plugins do not bind public listeners or configure Serve. Tailscale Funnel remains unsupported.

## Deliberate non-goals

No Docker runtime, plugin webviews, event bus, root daemon, multi-user roles, public marketplace, automatic plugin updates, or language SDK in API 1. Add an SDK only after multiple plugins duplicate a stable helper; add a brokered plugin API only after a real integration needs one.

## State and implementation boundaries

`HubRuntime` remains the single policy and admission facade. Native and remote presentation values are grouped in `NativeToolsState` and `RemoteAccessState`; `NativeCapabilities`, `RemoteServer`, `TailscaleService`, `JobQueue`, and `PersistenceStore` retain their existing concrete service ownership. Listener termination is delivered directly to the hub rather than polled by a second liveness loop.

`ProcessTransport` shares stream draining, redaction, capture bounds, timeout arbitration, and termination handling. Callers still choose their fixed executable/environment, output-overflow policy, and process-group grace period. User-started action logs receive the complete redacted stream up to their independent file limit. Git rejects overflow; native and Tailscale adapters retain their own error behavior.

Presentation polling reads jobs and latest contribution results from one SQLite snapshot and publishes only changed values. Audit records remain internal. Per-plugin summaries come from durable contribution results, independently of the global recent-job limit. Native screen types and pure stat/table data parsing live in separate files. No extra package or dependency layer was introduced.
