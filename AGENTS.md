# KiwiOS

KiwiOS is a native Mac mini hub: one signed macOS app, one tailnet UI, and trusted executable plugins. It is not an operating system.

## Read first

- [README.md](README.md) — current status and build
- [docs/product.md](docs/product.md) — users, promise, journeys, and success criteria
- [docs/architecture.md](docs/architecture.md) — components and boundaries
- [docs/ROADMAP.md](docs/ROADMAP.md) — implementation order
- [docs/development.md](docs/development.md) — stack, packages, and repository layout
- [docs/testing.md](docs/testing.md) — edge cases and release gates
- [docs/plugin-contract.md](docs/plugin-contract.md) — plugin manifest and contributions
- [docs/watcher.md](docs/watcher.md) — `kiwios.watch/1`
- [docs/ui.md](docs/ui.md) — KiwiOS-drawn UI kinds
- [docs/permissions.md](docs/permissions.md) — trust, authorization, and macOS prompts
- [docs/marketplace.md](docs/marketplace.md) — installation and distribution
- [docs/operations.md](docs/operations.md) — lifecycle and recovery
- [docs/mcp.md](docs/mcp.md) — hosted MCP
- [docs/inspiration.md](docs/inspiration.md) — visual language

## Invariants

- Native core plus plugins. No units, Docker, plugin HTML, or plugin CSS.
- Plugins declare data and actions; KiwiOS owns navigation, rendering, confirmation, and jobs.
- Treat an enabled plugin as trusted code running with the Aqua user's authority. Do not describe manifest permissions as process isolation.
- Remote HTTP stays on loopback behind Tailscale Serve. Funnel is unsupported.
- Remote mode never triggers TCC, Keychain, Gatekeeper, `sudo`, license, or device-trust prompts.
- Never commit host-specific paths, tokens, secrets, device identifiers, or private operational inventory.
- House automation stays outside this repository; public examples must be generic.
- Prefer the smallest native or standard-library solution. Add a dependency only when it removes more risk or code than it adds.

## Changes

- Keep `project.yml` and the generated `KiwiOS.xcodeproj` in sync.
- Add the smallest relevant test for parsing, scheduling, authorization, persistence, or other non-trivial behavior.
- Preserve unknown-field and version behavior defined by the public protocols.
- Update the relevant contract document and `CHANGELOG.md` when externally visible behavior changes.

## Build

Use Xcode 27. Select its developer directory when it is not the active Xcode.

```sh
xcodegen generate
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -configuration Debug build
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -destination 'platform=macOS' test
```
