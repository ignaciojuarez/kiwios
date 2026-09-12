# Security policy

KiwiOS is pre-alpha and has no supported release yet. Security fixes currently target the default branch.

## Report a vulnerability

Use GitHub's **Security → Report a vulnerability** flow for this repository. Do not include exploit details, secrets, private logs, or identifying machine information in a public issue. If private reporting is unavailable, open a public issue containing no vulnerability details and ask the maintainers to enable a private reporting route.

Please include the affected commit or version, expected and observed behavior, impact, reproduction steps, and any suggested mitigation. We will acknowledge the report, assess scope, coordinate a fix, and credit the reporter if requested. No response-time guarantee is offered while the project is pre-alpha.

## Trust model

- KiwiOS is an after-login Aqua app. It is unavailable before FileVault unlock and is not a replacement for a tested recovery path such as SSH or Screen Sharing.
- Remote HTTP is intended to listen only on loopback and be exposed privately through Tailscale Serve over HTTPS. Tailscale Funnel and direct LAN exposure are unsupported.
- Remote administrative requests require a human identity supplied by KiwiOS-owned Tailscale Serve in addition to tailnet reachability. Operators must restrict the identities allowed to reach KiwiOS; requests without a supported identity fail closed.
- Plugins and their child processes are trusted code running as the logged-in user. Manifest permissions disclose intent and gate KiwiOS-provided capabilities; they do not sandbox filesystem, process, or network access.
- macOS TCC, Keychain, Gatekeeper, administrator, license, and device-trust prompts require an attended setup session. Remote operation fails closed when a prerequisite is missing.
- A malicious process already running as the same macOS user is outside the v1 security boundary.

See [permissions](docs/permissions.md), [plugin distribution](docs/marketplace.md), and [operations](docs/operations.md) for the detailed model.

## Safe operation

- Install only plugins whose complete source and pinned revision you trust.
- Keep Funnel disabled and restrict Tailscale access to intended operators.
- Store secret values in Keychain, not manifests, configuration files, logs, job output, or bug reports.
- Review permission changes and executable changes before updating a plugin.
- Keep a recovery route independent of KiwiOS and test it before enabling reboot or update actions.

Public hardening discussions that do not expose an active vulnerability are welcome in the issue tracker.
