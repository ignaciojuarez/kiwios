# KiwiOS

**Mac mini hub.** KiwiOS is a native macOS app being built to monitor and administer an always-on Mac through one UI on your tailnet.

It is not an operating system: macOS remains in charge. In the target design, KiwiOS owns execution, jobs, permissions, and UI; plugins are folders containing a manifest and executable commands. There is no Docker runtime and plugins do not ship HTML.

> [!IMPORTANT]
> KiwiOS is pre-alpha. The local plugin platform now includes strict manifest/config/dependency validation, bundled and development discovery, explicit source approval, durable action jobs and scheduled checks, typed results, Keychain secrets, seven native UI kinds, and setup diagnostics. The working tree also includes a tailnet PWA, a dedicated installed-package Brew view, native Tools, exact-commit repository installation, and optional Monitor, Volume Health, and Watcher plugins. The unsigned Debug app builds with Xcode 27; signed-app lifecycle, accessibility, and broader macOS integration validation remain pending. MCP is deferred; the bundled curated catalog is empty and has not been published externally.

## Design

- One signed Aqua app and one responsive UI.
- Tailscale Serve is the remote boundary; the HTTP backend stays on loopback and Funnel is unsupported.
- Plugins declare data and actions; KiwiOS renders the UI.
- Plugins are trusted executable code running as the logged-in user. Manifest permissions disclose intent and gate KiwiOS services; they are not a sandbox.
- Remote operation begins only after login and FileVault unlock. Missing macOS permissions fail closed rather than opening an unattended prompt.

## Build

The app's deployment target is macOS 15. Building requires a macOS release supported as an [Xcode 27 build host](https://developer.apple.com/xcode/system-requirements/), Xcode 27, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The deployment target is not the Xcode build-host requirement.

```sh
xcodegen generate
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

If several Xcode versions are installed, set `DEVELOPER_DIR` to the Xcode 27 developer directory for the command.

The example plugin can also be exercised directly:

```sh
./plugins/hello-check/check.sh
```

To build and open the Debug app in one step, run `./scripts/run.sh`. It defaults to Xcode at `/Applications/Xcode.app`; set `DEVELOPER_DIR` if Xcode 27 is elsewhere. For stable macOS privacy approvals across rebuilds, set `KIWIOS_DEVELOPMENT_TEAM` to your local Apple development team ID; the value is intentionally not stored in the repository.

## Local use

1. Follow the setup steps on **Home**, then open **Plugins**, inspect the bundled `hello-check` source and disclosures, and choose **Add**. Checks run when added; actions remain behind the host confirmation dialog.
2. Run actions from their plugin views and use **Events** for one current diagnostic line per plugin. Unfinished actions are marked interrupted after a restart and never automatically replayed.
3. In **Settings**, enable launch at login, inspect Doctor, and optionally choose one development plugin directory. Missing or unknown macOS prerequisites block the affected plugin.
4. Add or reorder Home widgets and sidebar pages. Configuration and layout survive relaunch; secret fields are stored in Keychain.

Add the optional **Monitor** plugin for CPU, memory, thermal pressure, and SMART drive temperatures. Its declared Homebrew requirements are shown as installed or missing; after showing the exact formulae and receiving confirmation, KiwiOS installs them through Homebrew. Use **Brew** to inspect installed formulae, casks, versions, dependencies, and updates. Add **Watcher** when plugins declaring persistent external sessions should be summarized in one widget/page. Use **Tools** for other confirmed native work. In **Discover**, stage an exact GitHub commit, inspect its source and disclosures, and approve installation explicitly.

To connect a phone, complete Doctor and launch-at-login setup, connect both devices to Tailscale, then use **Remote access** on Home or in Settings. KiwiOS checks for conflicting Serve/Funnel settings before publishing its loopback backend. Open the displayed HTTPS address on the phone; the PWA includes plugin pages, Events, and Status & setup. Remote access starts only after the Mac user logs in and unlocks FileVault.

Plugin authors can copy the [plugin template](examples/plugin-template/) and follow the [author-to-install walkthrough](docs/plugin-authoring.md). No Swift or SDK is required.

## Documentation

- [Product definition](docs/product.md)
- [Architecture](docs/architecture.md)
- [Roadmap](docs/ROADMAP.md)
- [Development and stack](docs/development.md)
- [Test strategy and edge cases](docs/testing.md)
- [Plugin contract](docs/plugin-contract.md)
- [Shared event protocol and Watcher sessions](docs/watcher.md)
- [UI contract](docs/ui.md)
- [Permissions and trust](docs/permissions.md)
- [Remote HTTP and PWA](docs/remote.md)
- [Plugin authoring](docs/plugin-authoring.md)
- [Plugin distribution](docs/marketplace.md)
- [Operations and recovery](docs/operations.md)
- [MCP hosting](docs/mcp.md)
- [Visual language](docs/inspiration.md)

See [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a change and [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting.

## License

[MIT](LICENSE)
