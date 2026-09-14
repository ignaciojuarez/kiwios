# Trust, permissions, and remote prompts

KiwiOS has three separate trust layers. Keeping them separate prevents the UI from promising isolation macOS does not provide.

## 1. Plugin trust and disclosure

Plugins are trusted executables running as the KiwiOS Aqua user. They are not sandboxed. A plugin can use any filesystem, process, network, Keychain, or TCC access already available to that user and executable identity.

The manifest permission list is disclosure, not containment. KiwiOS shows it before enable, records the approved source, commit, manifest, and content digest, and warns on undeclared behavior it can observe. KiwiOS can strictly gate only capabilities it brokers itself: named secrets, named SSH peers, notifications, managed Serve paths, and native actions.

Treat enabling a plugin like running a downloaded shell script. Read its source or trust its maintainer and exact commit. The curated catalog improves reviewability but does not certify safety.

Local approvals bind the selected directory, manifest digest, and content digest; installed approvals bind the canonical repository and exact commit as well. All source changes require a new review. The host-owned PWA review and attended approval sheet show source, version, license, dependencies, declared permissions, and digests. Configuration is validated before launch; a plugin remains `needs-setup` until its configuration, requested secrets, and probed prerequisites are ready.

## 2. KiwiOS policy

KiwiOS requires explicit approval before first enable and before activating an update that expands disclosed permissions. Revoking a brokered scope blocks that KiwiOS operation; disabling a plugin stops future launches and cancels its jobs.

Destructive actions declare `confirm = true` and use the host confirmation dialog. The local runtime binds a one-use confirmation to the plugin content, action, and job; it expires after 60 seconds and is checked again at execution. Checks and actions cannot enter the runner merely by calling a view handler. Remote actions and results are audit-logged with the human identity supplied by KiwiOS-owned [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve). API 1 has one role: every verified human identity allowed by the operator's Tailscale policy is an administrator. KiwiOS does not add a second roles database. Requests with missing identity headers fail closed; tagged nodes do not supply a human identity and cannot perform remote mutations in API 1.

KiwiOS's loopback listener is exclusively a Serve backend, not an authenticated local-browser entry point. The attended menu-bar surface calls the runtime directly. KiwiOS accepts identity headers only under this managed deployment model and also enforces origin and CSRF checks. Funnel, alternate reverse proxies, and direct LAN/public binding are unsupported. Same-user local process compromise is outside the v1 boundary, as stated in [SECURITY.md](../SECURITY.md).

## 3. macOS grants

TCC, Keychain prompts, Gatekeeper, Xcode license dialogs, sudo, and device trust belong to macOS. They appear in the physical Aqua session, not in the remote PWA.

**Remote mode never prompts.** KiwiOS probes declared prerequisites without invoking the protected operation. A missing or unknown prerequisite blocks the command as `needs-setup` and gives instructions for a later attended session.

The remote LaunchAgent restart is deliberately narrower than setup work: it confirms and runs `launchctl kickstart -k` only for an already-discovered, current-user-owned regular plist. It neither edits the plist nor requests a macOS grant, and ownership, symlink, duplicate-label, and current-state checks run again at confirmation, queue admission, and execution. Remote plugin installation likewise stages immutable source without executing it, then requires an identity-bound review confirmation. A confirmed remote removal may delete only that plugin's config accounts after interaction-disabled Keychain enumeration and deletion both succeed; any possible Keychain UI blocks the operation and directs the operator to Attended Setup. Homebrew, Keychain-secret creation or updates, TCC, license, device-trust, and privileged operations do not gain a remote path.

```toml
[permissions]
tcc = ["accessibility", "screen-recording"]
```

API 1 accepts `accessibility` and `screen-recording`, the grants KiwiOS can check without prompting. Unprobeable TCC grants are not supported manifest prerequisites in API 1. A plugin may also need a Keychain item, Xcode first-launch/license acceptance, Gatekeeper approval, or external device trust; its checks must report those prerequisites.

KiwiOS never writes `TCC.db`, clicks a security dialog, stores a sudo password, or invokes a protected API merely to see whether it prompts.

## Setup and remote modes

| | Setup mode | Remote mode |
|---|---|---|
| Presence | attended Mac or Screen Sharing session | ordinary tailnet operation |
| New TCC/Keychain/license dialog | allowed and guided | command blocked |
| Plugin enable | review disclosure, then run doctor | only if doctor is already green |
| Background operations | may wait for the operator | must fail closed instead of hanging |

The native doctor checks the Aqua session, FileVault state, KiwiOS permissions, configured volumes/tools, plugin prerequisites, and known blocking dialogs. If KiwiOS lacks the access required to inspect a grant, its state is `unknown`, not `denied` or `granted`.

The current native Doctor probes Aqua ownership, storage/database health, app signing, required host tools, FileVault, launch-at-login registration, Accessibility, and Screen Recording. KiwiOS does not substitute an unsafe operation for a missing preflight API. The app does not yet inspect arbitrary license, device-trust, or blocking application dialogs. Those prerequisites must be completed in an attended session. The remote HTTP surface reports blocked prerequisites and never opens these dialogs. See [remote.md](remote.md) for publication, sessions, and confirmation behavior.

SSH inspection uses the owning user's OpenSSH configuration. That configuration is part of the attended local trust boundary and may run configured local, proxy, or known-host commands and may enable forwarding. The PWA may request a bounded probe only by an attended-configured peer name; it cannot supply a destination, port, password, or host key. Operators should review their user SSH configuration before adding a peer. KiwiOS supplies batch mode, strict host-key checking, one connection attempt, and bounded timeouts.

## Secrets and logs

Secrets are named Keychain values. KiwiOS exposes only those requested by the enabled plugin, through the temporary file described in [plugin-contract.md](plugin-contract.md). Plugin code can still copy or transmit a secret it legitimately receives; install trust remains the security boundary.

KiwiOS redacts exact known secret values from captured logs as a last resort, but plugin authors must not emit secrets in logs, status, state, filenames, or command arguments. Redaction is not a substitute for correct plugin behavior.

## Security reports

Use the private reporting route in [SECURITY.md](../SECURITY.md). Reports involving sandbox escape should account for the documented fact that API 1 plugins are not sandboxed; privilege escalation beyond the Aqua user's existing access is still a security issue.
