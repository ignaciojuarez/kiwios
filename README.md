# KiwiOS

**Mac mini hub.** KiwiOS is a native macOS app being built to monitor and administer an always-on Mac through one UI on your tailnet.

It is not an operating system: macOS remains in charge. In the target design, KiwiOS owns execution, jobs, permissions, and UI; plugins are folders containing a manifest and executable commands. There is no Docker runtime and plugins do not ship HTML.

> [!IMPORTANT]
> KiwiOS is pre-alpha. The app currently bundles, strictly validates, and runs the example plugin locally. Dependencies, permissions, config, persistence, scheduling, remote HTTP, and plugin installation are not implemented yet.

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
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -configuration Debug build
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -destination 'platform=macOS' test
```

If several Xcode versions are installed, set `DEVELOPER_DIR` to the Xcode 27 developer directory for the command.

The example plugin can also be exercised directly:

```sh
./plugins/hello-check/check.sh
```

## Documentation

- [Product definition](docs/product.md)
- [Architecture](docs/architecture.md)
- [Roadmap](docs/ROADMAP.md)
- [Development and stack](docs/development.md)
- [Test strategy and edge cases](docs/testing.md)
- [Plugin contract](docs/plugin-contract.md)
- [Watcher protocol](docs/watcher.md)
- [UI contract](docs/ui.md)
- [Permissions and trust](docs/permissions.md)
- [Plugin distribution](docs/marketplace.md)
- [Operations and recovery](docs/operations.md)
- [MCP hosting](docs/mcp.md)
- [Visual language](docs/inspiration.md)

See [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a change and [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting.

## License

[MIT](LICENSE)
