# Operations

KiwiOS is remote administration for a Mac that has completed login. Its operational model favors honest failure states over apparent availability.

## Host setup

An operator performs initial setup at the Mac or through an attended Screen Sharing session:

1. install and launch the signed app;
2. enable launch at login for the owning Aqua user;
3. keep the Mac awake when remote availability is required;
4. install/sign in to Tailscale and let KiwiOS own one tailnet-only Serve origin;
5. grant only the macOS permissions shown by Doctor;
6. install plugins, review their exact source commits and disclosures, then enable them;
7. switch from setup mode to remote mode only when Doctor is green.

The app does not configure automatic login. After a cold FileVault boot, remote service begins only when the owning user unlocks the Mac. Use planned authenticated restart where appropriate; retain an out-of-band recovery method for an unattended host.

## Runtime ownership

KiwiOS is the sole scheduler and process owner for its checks and jobs. Long actions use the job queue; plugins do not background-orphan work. Independent long-running services remain launchd's responsibility in API 1.

The host applies these rules:

- a lock prevents overlapping work on the same resource;
- checks skip overlap rather than queue stale runs;
- cancellation sends `SIGTERM`, then `SIGKILL` after five seconds;
- logs and structured state use the limits in [watcher.md](watcher.md);
- app termination marks interrupted work honestly; API 1 does not resume arbitrary processes.

## Network and identity

The native UI is always available locally and talks to the app directly. Remote HTTP uses a dedicated loopback backend published only through KiwiOS-owned Tailscale Serve; it is not a supported localhost-browser endpoint, and Funnel is rejected. Every verified human identity allowed by the operator's Tailscale policy is an administrator. State-changing requests require and record that Serve-supplied identity; missing identity and tagged-node requests fail closed.

Do not expose KiwiOS through another reverse proxy or bind its backend to LAN interfaces. Tailscale Serve removes caller-supplied identity headers before adding its own, but a same-user process can still reach loopback and is outside the v1 boundary. State changes also require the KiwiOS origin and CSRF protection; browser content and plugin text are untrusted input. Loss of Tailscale leaves local UI and local logs as recovery paths.

## Failure behavior

| Condition | Behavior |
|---|---|
| User not logged in | KiwiOS and supervised work are unavailable |
| FileVault awaiting unlock | same; no misleading “healthy” state |
| Tailscale/Serve down | local UI remains available; remote UI is unavailable |
| Required volume/tool missing | affected checks/actions are blocked, not redirected silently |
| TCC/Keychain/license prerequisite missing | plugin becomes `needs-setup`; remote command does not prompt |
| Plugin command fails or times out | job/check fails; other plugins and native UI continue |
| KiwiOS exits during a job | job becomes interrupted; operator decides whether to rerun |

## Data, backup, and logs

Back up `config.toml`, `KiwiOS.sqlite`, and `PluginData/`. Installed plugin code is reproducible from its approved repository SHA; logs are disposable. Keychain items require a separate credential recovery plan and are never exported by KiwiOS backup.

SQLite records job metadata, latest snapshots, plugin approvals, and the audit trail. Large logs and build artifacts remain files. KiwiOS must tolerate missing/corrupt optional logs and report database recovery needs instead of silently replacing the database.

## Updates

KiwiOS app updates and plugin updates are separate. App distribution may use a signed/notarized Homebrew cask once releases exist. Plugin updates are explicit approved-SHA changes as described in [marketplace.md](marketplace.md). KiwiOS does not combine Homebrew and Sparkle for its own updater.

Before an app update, finish or cancel active jobs and preserve the database. After update, run Doctor, validate enabled manifests against the supported API list, and leave incompatible plugins disabled with a readable reason.

## Doctor and support bundle

Doctor reports app version, supported plugin APIs, Aqua/FileVault state, storage/database health, Tailscale/Serve state, required native tools, macOS grants, enabled-plugin prerequisites, and blocking dialogs without triggering a prompt.

A redacted support bundle may include diagnostics, manifests, versions, job metadata, and bounded logs. It excludes secret values, plugin config values marked `writeOnly`, message bodies, user file contents, and Keychain data. Creation and export require confirmation.
