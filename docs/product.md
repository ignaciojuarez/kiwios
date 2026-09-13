# Product definition

KiwiOS is a menu-bar control service and tailnet web control panel for one always-on Mac mini. Its primary user is a technical owner who wants dependable administration without assembling a dashboard, scheduler, and collection of private web apps.

## Promise

From one host-owned web UI, the operator can understand the Mac's state, run bounded maintenance work, and use reviewable plugins. A compact attended Mac surface owns setup that can invoke operating-system trust or permission flows. Failures remain visible and recoverable; KiwiOS never claims pre-login or high-availability behavior it cannot provide.

## Core journeys

1. Install the signed menu-bar app, enable launch at login, and use its compact attended setup window to finish local prerequisites and publish the web UI.
2. Inspect a plugin's exact source revision, dependencies, and disclosures before enabling it.
3. See current host/plugin health and the age of each result.
4. Start a confirmed action, follow bounded progress/logs, cancel it, and review its audit entry.
5. Use the tailnet PWA as the primary Home, plugin, Events, Tools, Brew, and Settings interface after login.
6. Diagnose or disable a failing plugin without losing the local menu-bar recovery path.

## Extension promise

A plugin author should not need Swift or a KiwiOS SDK. A folder, strict TOML manifest, executable argv, JSON configuration, and JSONL output are the complete API 1 surface. KiwiOS owns scheduling, secrets, jobs, confirmation, storage boundaries, and every rendered pixel.

The open-source path is part of the product: a stranger must be able to clone, build, validate the example, understand the trust model, and propose a plugin or host change without private machine context.

## Success criteria for the first release

- A clean clone builds and tests from documented commands.
- The validator gives actionable errors without executing plugin code.
- A failed, noisy, hung, or malformed plugin cannot freeze the app or hide its failure.
- Local recovery works when Tailscale, a plugin, or the database fails.
- Remote mutation is attributable to a verified tailnet identity and protected from cross-origin requests.
- Installation and updates use immutable revisions, show disclosure diffs, and never run automatically.
- The example and first real plugins prove the public contracts without private scripts.

## Non-goals

KiwiOS is not macOS replacement software, fleet management, a pre-login daemon, a container platform, a general agent runtime, a plugin webview host, or an executable package store. Multi-user roles, root helpers, public exposure, automatic updates, and high availability require separate evidence and design work.

## Product guardrails

- Optimize for one owner and one Mac before generalizing.
- Prefer an honest unavailable state to a fragile availability trick.
- Add a native capability only with a real consumer.
- Add a UI kind only when existing kinds cannot express a real plugin.
- Treat popularity as discovery metadata, never as trust.
- Keep house-specific automation outside the public repository.
