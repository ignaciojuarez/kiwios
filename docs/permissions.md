# Trust, permissions, and remote prompts

KiwiOS has three separate trust layers. Keeping them separate prevents the UI from promising isolation macOS does not provide.

## 1. Plugin trust and disclosure

Plugins are trusted executables running as the KiwiOS Aqua user. They are not sandboxed. A plugin can use any filesystem, process, network, Keychain, or TCC access already available to that user and executable identity.

The manifest permission list is disclosure, not containment. KiwiOS shows it before enable, records the approved source, commit, manifest, and content digest, and warns on undeclared behavior it can observe. KiwiOS can strictly gate only capabilities it brokers itself: named secrets, named SSH peers, notifications, managed Serve paths, and native actions.

Treat enabling a plugin like running a downloaded shell script. Read its source or trust its maintainer and exact commit. The curated catalog improves reviewability but does not certify safety.

## 2. KiwiOS policy

KiwiOS requires explicit approval before first enable and before activating an update that expands disclosed permissions. Revoking a brokered scope blocks that KiwiOS operation; disabling a plugin stops future launches and cancels its jobs.

Destructive actions declare `confirm = true` and use the host confirmation dialog. Remote actions and results are audit-logged with the human identity supplied by KiwiOS-owned [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve). API 1 has one role: every verified human identity allowed by the operator's Tailscale policy is an administrator. KiwiOS does not add a second roles database. Requests with missing identity headers fail closed; tagged nodes do not supply a human identity and cannot perform remote mutations in API 1.

KiwiOS's loopback listener is exclusively a Serve backend, not an authenticated local-browser entry point. The native app uses an internal path. KiwiOS accepts identity headers only under this managed deployment model and also enforces origin and CSRF checks. Funnel, alternate reverse proxies, and direct LAN/public binding are unsupported. Same-user local process compromise is outside the v1 boundary, as stated in [SECURITY.md](../SECURITY.md).

## 3. macOS grants

TCC, Keychain prompts, Gatekeeper, Xcode license dialogs, sudo, and device trust belong to macOS. They appear in the physical Aqua session, not in the remote PWA.

**Remote mode never prompts.** KiwiOS probes declared prerequisites without invoking the protected operation. A missing or unknown prerequisite blocks the command as `needs-setup` and gives instructions for a later attended session.

```toml
[permissions]
tcc = ["fda", "accessibility", "apple-events"]
```

API 1 recognizes `fda`, `accessibility`, `apple-events`, `developer-tools`, `screen-recording`, and `local-network`. A plugin may also need a Keychain item, Xcode first-launch/license acceptance, Gatekeeper approval, or external device trust; its checks must report those prerequisites.

KiwiOS never writes `TCC.db`, clicks a security dialog, stores a sudo password, or invokes a protected API merely to see whether it prompts.

## Setup and remote modes

| | Setup mode | Remote mode |
|---|---|---|
| Presence | attended Mac or Screen Sharing session | ordinary tailnet operation |
| New TCC/Keychain/license dialog | allowed and guided | command blocked |
| Plugin enable | review disclosure, then run doctor | only if doctor is already green |
| Jobs | may wait for the operator | must fail closed instead of hanging |

The native doctor checks the Aqua session, FileVault state, KiwiOS permissions, configured volumes/tools, plugin prerequisites, and known blocking dialogs. If KiwiOS lacks the access required to inspect a grant, its state is `unknown`, not `denied` or `granted`.

## Secrets and logs

Secrets are named Keychain values. KiwiOS exposes only those requested by the enabled plugin, through the temporary file described in [plugin-contract.md](plugin-contract.md). Plugin code can still copy or transmit a secret it legitimately receives; install trust remains the security boundary.

KiwiOS redacts exact known secret values from captured logs as a last resort, but plugin authors must not emit secrets in logs, status, state, filenames, or command arguments. Redaction is not a substitute for correct plugin behavior.

## Security reports

Use the private reporting route in [SECURITY.md](../SECURITY.md). Reports involving sandbox escape should account for the documented fact that API 1 plugins are not sandboxed; privilege escalation beyond the Aqua user's existing access is still a security issue.
