# Xcodes for KiwiOS

This is the inventory and diagnosis release of the external KiwiOS Xcodes plugin. It reports the installed Xcodes, current developer-directory selection, local simulator runtimes and device instances for every verified Xcode, and the available Xcode/runtime catalogs. It does not build apps and is intentionally separate from the iOS build-library plugin.

Canonical repository: [`github.com/ignaciojuarez/kiwios-xcodes`](https://github.com/ignaciojuarez/kiwios-xcodes). This `examples/xcodes/` directory is the author copy inside the KiwiOS tree for local development. Ignacio Juarez (`@ignaciojuarez`) owns and maintains the plugin. KiwiOS does not bundle or auto-discover it. Install from Discover Featured, or from the GitHub URL plus an exact commit SHA.

## Requirements

- macOS 15 or later
- KiwiOS with `native.jobs = "1"`
- the Homebrew `xcodes` formula
- at least one full Xcode for simulator inventory
- the system Ruby and command-line utilities declared in `plugin.toml`

KiwiOS can install the declared core `xcodes` formula after an identity-bound confirmation, including from remote. The formula install is never automatic. Xcode and simulator-runtime **install** stay deferred until an attended-only action contract exists. The plugin never reads Xcodes Keychain items and reports authentication status as unknown.

The human-readable catalog output is fixture-tested for `xcodes` 2.1.x, including unlabeled `version (build)` rows such as `16.4 (16F6)` and optional `[Apple Silicon]|[Universal]|[Intel]` suffixes. Homebrew core currently bottles 2.1.0, which is inside that window. A later or older version remains visible in tool health, but catalog checks fail closed until its output has a fixture. Local Xcode and `simctl` JSON are still validated conservatively. Before `xcodebuild -version` or `simctl`, the wrapper probes `xcodebuild -checkFirstLaunchStatus` with `DEVELOPER_DIR` so a pending license/first-launch task fails closed without opening those tools. If that flag is missing, it continues with the existing timeout and output classification. A blocking Aqua dialog remains a residual remote-mode risk if a tool prompts without this probe covering it. Xcodes subprocesses receive an isolated `HOME` under `KIWIOS_DATA_DIR`; their nonsecret catalog cache cannot migrate or overwrite the user's Xcodes CLI configuration and remains inside the disclosed plugin-owned data path.

Architecture selection is automatic. The wrapper reports the effective Apple Silicon or Intel process architecture, and Xcodes applies its matching default catalog filter. There is no plugin setting to maintain. Release validation should still exercise both architectures because automatic detection itself is part of the compatibility surface.

## Test

```sh
./tests/test.rb
```

The test uses temporary fake commands and fixtures. It does not contact Apple, run Xcode, or inspect local credentials.

## Delivery plan

1. **Inventory (implemented):** publish these read-only checks and test them on clean Apple Silicon and Intel accounts with Xcode 15, 16, 26, and 27 where available.
2. **Fixed management actions:** only after KiwiOS adds an attended-only action scope, add a very small set of locally started, confirmed actions.
3. **Version/runtime choices:** only after KiwiOS owns dynamic action choices and binds/revalidates the selected item.
4. **Authentication:** defer unless an attended native handoff is designed; never accept Apple credentials or verification codes from the PWA.

The remaining publication decisions are enabling GitHub private vulnerability reporting and choosing the exact `xcodes`/Xcode versions included in the release test matrix.
