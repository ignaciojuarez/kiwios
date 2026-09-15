# Plugin contract: draft `kiwios_api = "1"`

A plugin is a trusted folder containing `plugin.toml` and executable commands. This is the API 1 design target, not a frozen contract: KiwiOS is pre-alpha and breaking corrections may land before its first supported release. The local app strictly validates the complete API 1 manifest surface and referenced files before a plugin can be approved or run.

| Manifest surface | Current status |
|---|---|
| Metadata, checks, actions, durations | decoded and validated |
| UI pages, sidebar, widgets, form descriptors, and sources | decoded, validated, and rendered by the host-owned PWA |
| Optional Watcher session | status-check and start-action references decoded, validated, and rendered by the optional Watcher plugin |
| Referenced `./` executables | validated as local regular executable files |
| Required dependencies | decoded; versions, missing requirements, and cycles validated |
| Homebrew requirements | decoded, validated, and shown as installed or missing; installed by KiwiOS only after local confirmation |
| Permission disclosures | decoded, validated, and shown during approval |
| Config schema | strict supported subset decoded, validated, and rendered |

## Minimal manifest

```toml
id = "hello-check"
name = "Hello"
description = "A short summary shown on the Plugins card."
version = "0.1.0"
kiwios_api = "1"
license = "MIT"
brew = []

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

Required top-level fields are `id`, `name`, `version`, `kiwios_api`, and `license`. `description` is an optional, nonblank summary displayed on the Plugins card. `version` is SemVer 2.0. `kiwios_api` is an exact string; an API 1 host rejects any other value.

Plugin IDs match `[a-z0-9]+(?:[.-][a-z0-9]+)*`. Contribution IDs match `[a-z0-9]+(?:-[a-z0-9]+)*` and are unique within their table. KiwiOS exposes them as `<plugin-id>/<contribution-id>`. IDs are stable storage and layout keys and must not change during an ordinary update.

Each widget declares `size = "1x1"` or `size = "2x1"`. This is its fixed Home presentation width: compact widgets remain one column and wide widgets span two.

`brew` is an optional list of unique Homebrew core formula names. KiwiOS shows every declared formula as installed or missing and blocks the plugin until all are installed. The web UI can present an identity-bound confirmation for the exact missing formulae of an already approved plugin, then queue a local KiwiOS-managed `brew install --formula` job. Formula detection supports the standard Apple Silicon and Intel Homebrew Cellars. KiwiOS does not install Homebrew itself.

The formula is a host requirement, not content embedded in the plugin. KiwiOS remembers only formulae it installed. When an installed plugin is removed, KiwiOS may offer to uninstall an owned formula after checking other plugin declarations and installed Homebrew reverse dependencies. Pre-existing or unverifiable formulae are retained, and the operator sees and controls the exact uninstall selection.

Canceling or failing a plugin-requested Homebrew installation returns that plugin to Not added so the single Add button can retry cleanly. The dependency operation stays associated with its originating plugin and is canceled if that plugin is removed.

The validator rejects unknown or missing fields, blank user-facing text, unsupported API versions, invalid IDs or SemVer, duplicate contribution IDs, invalid durations and descriptors, missing source references, empty argv, NUL arguments, control characters in executable names, unsafe paths, and referenced local executables that are missing, non-regular, non-executable, or resolve outside the plugin. Strict validation makes typos visible instead of silently weakening disclosure or changing behavior.

KiwiOS discovers every direct plugin folder in its bundled plugin roots and, when selected, one local development directory. The selected directory may itself be a plugin or contain direct plugin children. Approved exact-commit snapshots are also discovered from app-owned installed storage. Duplicate IDs in one source and conflicts between bundled, development, and installed sources are errors; discovery never executes plugin code or silently chooses a winner. Missing dependencies remain visible as plugin lifecycle errors so they do not hide otherwise valid plugins.

## Dependencies

```toml
[depends]
"native.jobs" = "1"
"native.tailscale" = "1"
"another-plugin" = "^0.2.0"
```

Native capability requirements use exact nonnegative integer-version strings. Plugin requirements use an exact SemVer version or a caret range. Required missing/incompatible dependencies prevent enablement and cycles are rejected. SemVer parsing follows the strict numeric and prerelease rules without imposing machine-integer limits on numeric identifiers. Caret ranges stay within the same nonzero major version, or within the same minor/patch boundary for `0.x` versions.

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
tcc = ["accessibility"]
notify = true
```

These fields disclose expected behavior. KiwiOS enforces them only when brokering its own capabilities, such as named secrets, SSH peers, Serve, or notifications. Arbitrary plugin code is not sandboxed and may use the user's ambient filesystem, process, and network access. See [permissions.md](permissions.md).

Unknown disclosure fields, duplicate entries, malformed names or paths, and unknown TCC values fail validation. API 1 accepts only `accessibility` and `screen-recording` for `tcc`, because macOS provides prompt-free preflight APIs for those grants. TCC grants that KiwiOS cannot verify without prompting are not supported prerequisites in API 1. An absent field means the plugin did not disclose that access. Enabling an installed plugin records its source, manifest, and content digest. A later version with expanded disclosure requires approval before the new version becomes active.

Approval fingerprints accept only regular files and directories: symbolic links are rejected. A source tree is limited to 4,096 entries and 32 MiB of file content. KiwiOS uses bounded reads and rejects a tree that changes while it is being reviewed. These checks make approval repeatable; they do not sandbox enabled code.

## Checks and actions

Checks are read-only status commands:

```toml
[[checks]]
id = "service"
label = "Service"
command = ["./status", "--jsonl"]
every = "30s"      # optional; otherwise Add + manual refresh only
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

Durations are positive integers followed by `ms`, `s`, `m`, or `h`; values that overflow the host timing representation are invalid. Checks run once when added, on manual refresh, and on their optional interval. A scheduled check never overlaps itself: KiwiOS skips the new run and retains only the latest typed result. Actions always run through the job queue. `confirm = true` makes KiwiOS show the confirmation UI; plugins cannot bypass it.

An external service, script, or build plugin can opt into the optional Watcher aggregator without giving up ownership of its logic:

```toml
[watch]
status = "service"
start = "restart"
```

`status` references a check in the same plugin and `start` optionally references one of its actions. Watcher uses their ordinary `kiwios.watch/1` status, log, error, and progress events; it does not introduce another task or process protocol.

## Execution environment

- Commands are argv arrays executed directly, never shell strings.
- A `./` executable resolves from the plugin root. A bare executable resolves through `PATH`. Absolute paths, other slash-containing relative forms, traversal, and symlink escape are rejected.
- The working directory is the plugin root and stdin is closed.
- The base environment contains `HOME`, `USER`, `TMPDIR`, `LANG`, and `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` when those values exist.
- KiwiOS adds `KIWIOS_PLUGIN_ID`, `KIWIOS_PLUGIN_ROOT`, `KIWIOS_DATA_DIR`, and `KIWIOS_CONFIG_FILE`.
- Requested secrets are written to a mode-`0600` temporary JSON file named by `KIWIOS_SECRETS_FILE`, then removed when the process exits. Declared named secrets retain their manifest names. The `<plugin-id>.config.*` namespace is reserved for write-only fields and cannot be declared as a shared named secret. A write-only config field uses the stable Keychain and delivered-file name `<plugin-id>.config.<field>`. Secret values never appear in argv.
- `SIGTERM` begins cancellation or timeout; KiwiOS sends `SIGKILL` after five seconds if the process remains alive.
- stdout is parsed as `kiwios.watch/1`; stderr is stored as log text. Both are UTF-8 with replacement for invalid bytes.

The fixed `PATH` is a default, not a guarantee that a tool is installed. A plugin's checks should report a useful error for missing external commands.

## Configuration and data

Configuration is stored by KiwiOS and exposed through `KIWIOS_CONFIG_FILE`. A configurable plugin may provide a `config.schema.json` path:

```toml
[config]
schema = "config.schema.json"
```

The schema root must declare `"type": "object"` and `properties`. API 1 deliberately supports only properties of type `string`, `number`, `integer`, or `boolean`, plus `title`, `description`, optional `warning`, nonempty typed `enum`, typed `default`, boolean `writeOnly`, and top-level `required`. `warning` is a nonblank string rendered in orange under the field; it is not a sandbox. Integer properties use the exact JSON/JavaScript safe range −9,007,199,254,740,991 through +9,007,199,254,740,991; larger integral numbers are rejected, including defaults and enum choices. Required names must identify declared properties. Unsupported keywords and values with the wrong declared type fail validation. A write-only property cannot declare a default.

A property with `"writeOnly": true` is stored under `<plugin-id>.config.<field>` as a named Keychain secret. Changing it is allowed only in attended setup mode, and an empty form field keeps the current secret. Write-only values never enter `KIWIOS_CONFIG_FILE` or the persisted nonsecret configuration JSON. KiwiOS creates that JSON with mode `0600` and replaces it atomically.

Native and remote editors submit changed fields with the public configuration revision they loaded. SQLite compares that revision atomically and rejects stale saves; a rejected save preserves the draft for review. Schema defaults are applied by validation. A required enum without a default requires an explicit choice. SQLite is the authoritative public store; `config.json` is derived again before execution, so a materialization failure blocks launch without losing a committed save.

KiwiOS exposes every schema-backed configuration through its plugin Configure dialog. A schema containing only public fields can be edited there remotely; a schema containing a write-only Keychain field instead directs the user to Attended Setup on the Mac mini. The dialog always remains available for a plugin with configuration options. If unmet public configuration is the only setup blocker, saving it promotes the already-approved plugin automatically; the user can then turn it off with its normal switch.

Configuration operations for one plugin are serialized across Keychain and SQLite. Ordinary secret-write failures restore previous Keychain values. An interrupted or uncompensated write leaves a durable recovery marker that blocks execution until every secret field is explicitly resaved during attended setup. Secret rollback values are never journaled outside Keychain.

Discovery reports errors per source candidate and continues with healthy plugins. Every contender for a duplicate ID or canonical source conflict is excluded; no source wins by search order. App-bundled plugins use a stable KiwiOS identity because an app update or development build can legitimately move the bundle directory; legacy app-bundle paths migrate to that identity. Development and installed sources remain bound to their canonical directory or repository. Re-enabling a required dependency rechecks enabled dependents without requiring a full reload.

Writable state belongs in `KIWIOS_DATA_DIR`. Plugins must not modify their installed code directory or another plugin's data. An update preserves config and data, revalidates config against the new schema, and remains inactive if validation fails. API 1 has no install/update hooks or automatic migrations.

## Lifecycle

The visible states are `installed`, `needs-setup`, `active`, `disabled`, `missing-dependency`, and `error`. The remote plugin protocol separately reports setup as `ready`, `configuration-required`, `authorization-required`, `attended-setup-required`, or `error`; the browser uses it to place Configure in place of the switch when configuration is incomplete. Ordinary enabled and disabled state is conveyed by the switch rather than a redundant badge. `Authorization needed` and `Error` are the only card badges. Missing declared TCC or Keychain setup yields `needs-setup`; it never opens a remote prompt. Three consecutive crashes/timeouts of the same check or action yield `error` until the source is enabled again or removed. A later source change clears that Error so the new contents can be reviewed. A new or changed source receives the same web review before it can be enabled.

## Author tooling

The app provides the current validator through development-directory discovery and installation staging. A standalone `kiwios validate` CLI is not implemented. Any future CLI must reuse the manifest, referenced-file, config, dependency, and UI-source validator without executing plugin commands. See the [authoring walkthrough](plugin-authoring.md) and [copyable template](../examples/plugin-template/). There is no language SDK in API 1; argv, environment variables, JSON, and JSONL are the SDK.
