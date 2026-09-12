# Plugin contract: draft `kiwios_api = "1"`

A plugin is a trusted folder containing `plugin.toml` and executable commands. This is the API 1 design target, not a frozen contract: KiwiOS is pre-alpha and breaking corrections may land before its first supported release. The current vertical slice strictly validates metadata, checks, actions, durations, non-form UI descriptors and sources, and referenced local executables. Rendering and the remaining manifest sections are tracked in the roadmap.

| Manifest surface | Current status |
|---|---|
| Metadata, checks, actions, durations | decoded and validated |
| Non-form UI pages, sidebar, widgets, and sources | decoded and validated; not rendered yet |
| Referenced `./` executables | validated as local regular executable files |
| Required dependencies | decoding and validation pending |
| Permission disclosures | decoding and validation pending |
| Config schema | decoding and validation pending |

## Minimal manifest

```toml
id = "hello-check"
name = "Hello"
version = "0.1.0"
kiwios_api = "1"
license = "MIT"

[[checks]]
id = "hello"
label = "Hello"
command = ["./check.sh"]

[[actions]]
id = "ping"
label = "Ping"
confirm = true
command = ["./check.sh"]

[[ui.pages]]
id = "status"
title = "Hello"
kind = "checks"
source = "checks"

[[ui.sidebar]]
id = "hello"
label = "Hello"
page = "status"

[[ui.widgets]]
id = "hello"
title = "Hello"
kind = "stat"
source = "checks.hello"
size = "1x1"
```

Required top-level fields are `id`, `name`, `version`, `kiwios_api`, and `license`. `version` is SemVer 2.0. `kiwios_api` is an exact string; an API 1 host rejects any other value.

Plugin IDs match `[a-z0-9]+(?:[.-][a-z0-9]+)*`. Contribution IDs match `[a-z0-9]+(?:-[a-z0-9]+)*` and are unique within their table. KiwiOS exposes them as `<plugin-id>/<contribution-id>`. IDs are stable storage and layout keys and must not change during an ordinary update.

The current validator rejects unknown or missing fields in its implemented surface, blank user-facing text, unsupported API versions, invalid IDs or SemVer, duplicate contribution IDs, invalid durations and descriptors, missing source references, empty argv, unsafe paths, and referenced local executables that are missing, non-regular, non-executable, or resolve outside the plugin. `form` descriptors, dependencies, permission disclosures, and config remain pending. Strict validation makes typos visible instead of silently weakening disclosure or changing behavior.

## Dependencies

```toml
[depends]
"native.jobs" = "1"
"native.tailscale" = "1"
"another-plugin" = "^0.2.0"
```

Native capability requirements use exact integer-version strings. Plugin requirements use an exact SemVer version or a caret range. Required missing/incompatible dependencies prevent enablement and cycles are rejected. Dependency decoding and validation are not implemented yet.

Optional-dependency contribution behavior is deferred until a real plugin needs it. API 1 currently defines no `optional_depends` field or conditional-contribution syntax.

Dependencies provide no IPC or shared storage in API 1. A plugin must not read another plugin's data directory.

## Disclosed permissions

```toml
[permissions]
exec = ["xcodebuild", "xcrun"]
read_paths = ["~/Developer"]
write_paths = ["/Volumes/Builds"]
network = ["tailnet"]
ssh_peers = ["build-mac"]
secrets = ["apple.team-id"]
tcc = ["fda"]
notify = true
```

These fields disclose expected behavior. KiwiOS enforces them only when brokering its own capabilities, such as named secrets, SSH peers, Serve, or notifications. Arbitrary plugin code is not sandboxed and may use the user's ambient filesystem, process, and network access. See [permissions.md](permissions.md).

An absent field means the plugin did not disclose that access. Enabling an installed plugin records its source repository, commit, manifest, and content digest. A later version with expanded disclosure requires approval before the new version becomes active.

## Checks and actions

Checks are read-only status commands:

```toml
[[checks]]
id = "service"
label = "Service"
command = ["./status", "--jsonl"]
every = "30s"      # optional; otherwise enable + manual refresh only
timeout = "10s"    # optional; default 30s
```

Actions are user-started jobs:

```toml
[[actions]]
id = "restart"
label = "Restart service"
confirm = true
command = ["./service", "restart"]
timeout = "5m"     # optional; default 1h
lock = "service"   # optional; defaults to the scoped action id
```

Durations are positive integers followed by `ms`, `s`, `m`, or `h`; values that overflow the host timing representation are invalid. Checks run once on enable, on manual refresh, and on their optional interval. A scheduled check never overlaps itself: KiwiOS skips the new run and records it. Actions always run through the job queue. `confirm = true` makes KiwiOS show the confirmation UI; plugins cannot bypass it.

## Execution environment

- Commands are argv arrays executed directly, never shell strings.
- A `./` executable resolves from the plugin root. A bare executable resolves through `PATH`. Absolute paths, other slash-containing relative forms, traversal, and symlink escape are rejected.
- The working directory is the plugin root and stdin is closed.
- The base environment contains `HOME`, `USER`, `TMPDIR`, `LANG`, and `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` when those values exist.
- KiwiOS adds `KIWIOS_PLUGIN_ID`, `KIWIOS_PLUGIN_ROOT`, `KIWIOS_DATA_DIR`, and `KIWIOS_CONFIG_FILE`.
- Requested secrets are written to a mode-`0600` temporary JSON file named by `KIWIOS_SECRETS_FILE`, then removed when the process exits. Secret values never appear in argv.
- `SIGTERM` begins cancellation or timeout; KiwiOS sends `SIGKILL` after five seconds if the process remains alive.
- stdout is parsed as `kiwios.watch/1`; stderr is stored as log text. Both are UTF-8 with replacement for invalid bytes.

The fixed `PATH` is a default, not a guarantee that a tool is installed. A plugin's checks should report a useful error for missing external commands.

## Configuration and data

Configuration is stored by KiwiOS and exposed through `KIWIOS_CONFIG_FILE`. A configurable plugin may provide a `config.schema.json` path:

```toml
[config]
schema = "config.schema.json"
```

API 1 deliberately supports only JSON Schema object properties of type `string`, `number`, `integer`, or `boolean`, plus `title`, `description`, `enum`, `default`, `writeOnly`, and top-level `required`. Unsupported keywords fail validation. A property with `"writeOnly": true` is stored as a named Keychain secret rather than in the config file.

Writable state belongs in `KIWIOS_DATA_DIR`. Plugins must not modify their installed code directory or another plugin's data. An update preserves config and data, revalidates config against the new schema, and remains inactive if validation fails. API 1 has no install/update hooks or automatic migrations.

## Lifecycle

The visible states are `installed`, `needs-setup`, `active`, `disabled`, `missing-dependency`, and `error`. Missing declared TCC or Keychain setup yields `needs-setup`; it never opens a remote prompt. Repeated crashes/timeouts yield `error` until the user retries or disables the plugin.

## Author tooling

The app and future CLI use one validator. `kiwios validate <plugin-directory>` must validate the manifest, referenced files, config schema subset, dependency graph, and UI sources without executing plugin commands. There is no language SDK in API 1; argv, environment variables, JSON, and JSONL are the SDK.
