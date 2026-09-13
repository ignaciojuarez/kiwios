# Operations

KiwiOS provides a native control plane and an optional tailnet UI for a Mac that has completed login. Its operational model favors honest failure states over apparent availability.

## Host setup

An operator performs initial setup at the Mac or through an attended Screen Sharing session:

1. install and launch the signed menu-bar app;
2. enable the `SMAppService` login item for the owning Aqua user and resolve any System Settings approval it reports;
3. keep the Mac awake when remote availability is required;
4. install/sign in to Tailscale and let KiwiOS own one tailnet-only Serve origin when remote access is wanted;
5. grant only the macOS permissions shown by Doctor;
6. review each local plugin's source path, content digest, manifest digest, and disclosures, then add it;
7. use remote policy mode only when Doctor is green, then explicitly enable the KiwiOS-owned Serve mapping.

The app does not configure automatic login. After a cold FileVault boot, KiwiOS and its remote service begin only when the owning user unlocks the Mac. Retain an out-of-band recovery method for an unattended host.

## Runtime ownership

KiwiOS is the sole scheduler and process owner for its checks and action jobs. The optional Watcher plugin summarizes external sessions declared by their owning plugins; it does not become another scheduler. Long actions use the job queue and independent long-running services remain launchd's responsibility in API 1.

The local host applies these rules:

- a lock prevents overlapping work on the same plugin-scoped resource;
- checks skip overlap rather than queue stale runs;
- at most four jobs execute concurrently and at most 128 more are admitted as pending;
- cancellation sends `SIGTERM`, then `SIGKILL` after five seconds;
- each process output stream is captured up to 64 KiB in its typed result; KiwiOS does not create separate per-run log files;
- app termination cancels and drains initialization, periodic refreshes, in-flight admission writes, and supervised processes before returning;
- exact-owned Tailscale Serve cleanup completes independently of cancellation from its UI or health-monitor caller;
- after an unclean exit, active checks update their latest result to `interrupted` and are compacted; active actions remain as interrupted jobs and are never replayed automatically.

Mode changes close both the runtime policy gate and queue admission before inspecting active work and Doctor. Recurring checks are paused during that transition and reconstructed afterward; missed ticks are not replayed. Removal closes the affected execution gates and requests cancellation, including any dependency installation associated with the plugin, before deleting KiwiOS-owned content.

## Native host operations

Monitor accepts both `/dev/diskN` and Apple Silicon `IOService:` device identifiers reported by smartmontools. It maps registry nodes to physical disks and prefers a mounted volume's name from Disk Arbitration metadata, falling back to the hardware model or drive type. It does not traverse mounted volumes merely to discover those names.

The optional Monitor plugin samples CPU, memory, thermal pressure, and SMART drive temperatures after it is added. It requires the `smartmontools` Homebrew formula and reports whether that formula is installed. In attended setup, KiwiOS can install missing declared formulae only after showing and confirming the exact list. Canceling or failing that setup returns the plugin to Add. KiwiOS records formulae it installed and, during plugin removal, offers owned unused formulae for explicit cleanup. It keeps packages installed outside KiwiOS, shared with another added plugin, required by an installed Homebrew package, or not safely verifiable. Some external enclosures do not expose SMART data on macOS. The web Brew view reads a bounded installed inventory through Homebrew's JSON interface; metadata changes and upgrades stay attended. Web Tools adds bounded status for regular applications, at most 50 owned current-user LaunchAgent plists (with a 500-entry directory scan limit), FileVault, low-power mode, configured SSH peers, and notification authorization. Plist reads are bounded before allocation, duplicate labels are unavailable for actions, and status probes run in small batches with a 15-second aggregate admission budget plus bounded in-flight teardown. Prompt-free web operations revalidate process identity, configured peer names, and notification authorization before execution. Monitor and `volume-health` are the current phase-3 plugin consumers.

macOS owns removable-volume consent and remembers it against the app's code-signing identity. Release builds use a stable signature. Developers should run one KiwiOS build at a time and set `KIWIOS_DEVELOPMENT_TEAM` when using `scripts/run.sh`; an ad-hoc signature changes identity on rebuild and can cause repeated privacy prompts. Doctor cannot grant TCC access on the user's behalf.

Every native action is admitted through the durable job queue and checked again by the executor. Confirmation grants expire after 60 seconds and are held only in memory; an interrupted native action is never replayed after restart. Canceling a subprocess-backed action propagates cancellation to its process group. Native command output is retained only as a bounded diagnostic, and a native command deadline produces the distinct `timed-out` job state.

The process control accepts `SIGTERM` only for a regular non-Apple Aqua app running as the current UID from `/Applications` or `~/Applications`. It rechecks the PID, launch time, executable path, display name, and bundle identifier immediately before signaling so an exited or changed process fails closed. LaunchAgent restart applies only to a regular, nonsymlink plist owned by the current user under `~/Library/LaunchAgents`; it and all Homebrew changes are unavailable in remote policy mode. Homebrew uses only `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`, a minimal environment, `NONINTERACTIVE=1`, and `HOMEBREW_NO_AUTO_UPDATE=1`. Formula cleanup uses Homebrew's ordinary dependency protection plus a prior reverse-dependency check; it does not bypass dependencies or run global autoremove.

SSH peers must be added by name during attended setup. Jobs persist the peer name rather than a destination or credential, resolve it against the current allowlist at execution, and use `BatchMode=yes`, `StrictHostKeyChecking=yes`, one connection attempt, and bounded connection and process timeouts. KiwiOS does not collect SSH passwords or accept a new host key during a job. Notification authorization is also an attended operation; remote policy can deliver an already authorized local notification without opening a macOS prompt. Restart remains visibly unavailable because the app has no privileged helper and never invokes `sudo`.

## Remote network and identity

The local menu-bar and attended setup surfaces talk to the runtime directly. The primary web UI uses a dedicated loopback backend published only through KiwiOS-owned Tailscale Serve; it is not a supported localhost-browser endpoint, and Funnel is rejected. Every verified human identity allowed by the operator's Tailscale policy is an administrator. State-changing requests require and record that Serve-supplied identity; missing identity and tagged-node requests fail closed. The remote contract covers plugin checks/actions/cancellation/disablement/configuration, Doctor refresh, layout, source reload, revalidated process termination, named SSH probes, and already-authorized notification delivery. Prompt-capable host operations remain attended.

The backend must not be exposed through another reverse proxy or bound to LAN interfaces. Tailscale Serve removes caller-supplied identity headers before adding its own, but a same-user process can still reach loopback and remains outside the v1 boundary. State changes also require the exact KiwiOS origin, a session-bound CSRF token, one-use request IDs, JSON content type, and bounded request size. Browser content and plugin text are untrusted input. KiwiOS continuously validates the exact Serve ownership record and disables the backend if it changes. Loss of Tailscale leaves the menu-bar status and attended setup window as recovery paths.

## Failure behavior

| Condition | Behavior |
|---|---|
| User not logged in | KiwiOS and supervised work are unavailable |
| FileVault awaiting unlock | same; no misleading “healthy” state |
| Tailscale/Serve down or ownership record changed | menu-bar recovery remains available; web UI is unavailable |
| Required volume/tool missing | affected checks/actions are blocked, not redirected silently |
| TCC/Keychain/license prerequisite missing or unknown | plugin becomes `needs-setup`; execution remains blocked instead of prompting |
| Plugin or native command fails | job/check fails; other plugins and the menu-bar runtime continue |
| Plugin or native command times out | job/check records `timed-out`; bounded teardown runs |
| KiwiOS exits during a job | job becomes interrupted; operator decides whether to rerun |

## Data, backup, and logs

For the current local build, back up `KiwiOS.sqlite` and `PluginData/` while KiwiOS is shut down. Include the SQLite WAL and shared-memory files if copying a live database. Keychain items require a separate credential recovery plan and are never exported by KiwiOS backup. Also retain `InstalledPlugins/` with the matching database records if restoring approved plugin snapshots. A top-level `config.toml` is not implemented.

SQLite records plugin state, source-bound approvals, action metadata, latest snapshots, public plugin configuration, layout, mode, selected development directory, and the action audit trail. The one GRDB migration chain runs in WAL mode. Routine checks retain only structured latest-result state; no separate execution log files are created. Database errors are reported as recovery needs instead of silently replacing the database.

Public config patches carry a revision and stale saves fail explicitly. Secret updates have a durable recovery marker across the Keychain/SQLite boundary; an interrupted update blocks execution until the operator resaves all secret fields in attended setup. Pending uninstall entries survive crashes and are retried after login. See [plugin-contract.md](plugin-contract.md) and [marketplace.md](marketplace.md).

## Updates

KiwiOS app updates and the implemented installed-plugin update flow are separate. App distribution may use a signed/notarized Homebrew cask once releases exist. Repository and exact-SHA plugin installation uses staged source review and explicit activation as described in [marketplace.md](marketplace.md). KiwiOS does not combine Homebrew and Sparkle for its own updater.

Before an app update, finish or cancel active jobs and preserve the database. After update, run Doctor, validate enabled manifests against the supported API list, and leave incompatible plugins disabled with a readable reason.

## Doctor and support bundle

Doctor currently reports Aqua/FileVault state, storage capacity, app signing, required native tools, launch-at-login state, and supported plugin TCC prerequisites without triggering a prompt. Persistent storage is blocked below 512 MB available and reported as unknown when macOS supplies no capacity value. API 1 rejects TCC prerequisites without a reliable prompt-free probe. Plugin findings affect that plugin rather than blocking remote access for every healthy plugin. Tailscale/Serve ownership is validated while the remote backend is active.

A future redacted support bundle may include diagnostics, manifests, versions, job metadata, and bounded logs. It must exclude secret values, plugin config values marked `writeOnly`, message bodies, user file contents, and Keychain data. Creation and export will require confirmation.
