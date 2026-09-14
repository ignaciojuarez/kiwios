# KiwiOS

**Mac mini hub.** KiwiOS is a native macOS menu-bar service with a tailnet web UI for monitoring and administering an always-on Mac.

It is not an operating system: macOS remains in charge. In the target design, KiwiOS owns execution, jobs, permissions, and UI; plugins are folders containing a manifest and executable commands. There is no Docker runtime and plugins do not ship HTML.

> [!IMPORTANT]
> KiwiOS is pre-alpha. The signed-app target now runs without a Dock icon as a compact menu-bar service; its authenticated tailnet PWA is the primary control plane. The web UI includes every plugin UI kind, Home/sidebar layout, plugin configuration and status, Doctor, Events, prompt-free host tools, installed Homebrew inventory, and exact-SHA plugin install/update/removal reviews. Attended setup on the Mac remains deliberately small and owns prompt-capable Keychain work, Homebrew changes, launch-at-login, and Tailscale publication. The unsigned Debug app builds with Xcode 27; signed-app lifecycle, accessibility, and broader macOS integration validation remain pending.

## Design

- One signed menu-bar Aqua process and one responsive tailnet web UI.
- Tailscale Serve is the remote boundary; the HTTP backend stays on loopback and Funnel is unsupported.
- Plugins declare data and actions; KiwiOS renders the UI.
- Plugins are trusted executable code running as the logged-in user. Manifest permissions disclose intent and gate KiwiOS services; they are not a sandbox.
- Remote operation begins only after login and FileVault unlock. Missing macOS permissions fail closed rather than opening an unattended prompt.

## Build

The app's deployment target is macOS 15. Building requires a macOS release supported as an [Xcode 27 build host](https://developer.apple.com/xcode/system-requirements/), Xcode 27, and [XcodeGen 2.45 or newer](https://github.com/yonaskolb/XcodeGen). The deployment target is not the Xcode build-host requirement.

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

1. Open **Attended Setup…** from the menu bar. Enable launch at login, resolve Doctor findings, and optionally choose a development plugin directory or stage an exact GitHub revision locally.
2. Save prompt-capable secrets, then enable the tailnet web UI through Tailscale Serve.
3. Choose **Open Web UI** from the menu. Home, plugin pages, Events, Tools, Brew inventory, plugin configuration, layout, prompt-free settings, and reviewed exact-SHA plugin install/update/removal live there.
4. Arrange widgets and sidebar pages directly on **Home**; use **Settings** to inspect setup state. Configuration and layout survive relaunch; secret values remain in Keychain and never enter the remote snapshot.

Add the optional **Monitor** plugin for CPU, memory, thermal pressure, and SMART drive temperatures. Its declared Homebrew requirements are shown and installed only after attended confirmation. **Brew** provides a searchable installed inventory; **Tools** provides prompt-free host status plus the remote-safe process, named SSH, and authorized notification actions. Add **Watcher** to summarize plugins that declare persistent sessions.

Remote access starts only after the owning user logs in and unlocks FileVault. KiwiOS rejects conflicting Serve/Funnel settings, binds HTTP only on loopback, and never opens a macOS prompt from a browser request.

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
