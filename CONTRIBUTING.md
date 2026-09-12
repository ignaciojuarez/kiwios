# Contributing to KiwiOS

KiwiOS is early-stage. Focused fixes, protocol feedback, tests, and small plugins that exercise the existing contract are the most useful contributions.

## Before changing code

Read the [architecture](docs/architecture.md), [roadmap](docs/ROADMAP.md), and the contract relevant to your change. For plugin work, start with the [plugin contract](docs/plugin-contract.md) and [`hello-check`](plugins/hello-check).

Please open an issue before a large feature, new dependency, public protocol, or architectural split. Security reports follow [SECURITY.md](SECURITY.md), not the public issue tracker.

## Build and check

Install Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run:

```sh
xcodegen generate
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -configuration Debug build
xcodebuild -project KiwiOS.xcodeproj -scheme KiwiOS -destination 'platform=macOS' test
./plugins/hello-check/check.sh
```

Keep the generated Xcode project in sync with `project.yml`. Add a focused test when changing non-trivial parsing, scheduling, authorization, persistence, or process behavior.

## Pull requests

- Keep each change narrow and explain the user-visible result.
- Update the relevant document when a public manifest, protocol, permission, or UI kind changes.
- Add an entry to `CHANGELOG.md` for externally visible behavior.
- Use native frameworks or the standard library before adding a package.
- Do not commit machine-specific configuration, absolute home paths, tokens, secrets, logs, signing material, device identifiers, or personal operational inventory.

## Plugin contributions

Plugins are executable code, not sandboxed extensions. An enabled plugin runs with the logged-in user's authority.

- Declare every command, path, network destination, secret name, and macOS permission the plugin intends to use.
- Treat manifest permissions as reviewable intent and access to KiwiOS services, not as containment of arbitrary child processes.
- Emit `kiwios.watch/1` JSONL on stdout and never emit secret values.
- Use argv arrays; do not require KiwiOS to assemble shell command strings.
- Keep checks bounded and side-effect free. Run mutations as jobs and mark destructive actions for confirmation.
- Never cause a TCC, Keychain, Gatekeeper, `sudo`, license, or device-trust prompt in remote mode.
- Avoid background daemons, private web UIs, and direct Tailscale Serve configuration; KiwiOS owns lifecycle and presentation.

Only generic example plugins belong in this repository. Personal and household automation should live in the operator's private configuration.

## License

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
