# Roadmap

Each phase ends in a working vertical slice. The API 1 plugin and watcher documents are pre-release drafts; freeze them and require explicit version bumps only after validator conformance and real-plugin testing.

## 0 — public foundation

- [x] macOS app shell and MIT license
- [x] authoritative product, architecture, development, testing, plugin, watcher, UI, permission, operations, and catalog docs
- [x] tiny `hello-check` source fixture
- [x] public build prerequisites and contributor guide
- [x] `SECURITY.md` with vulnerability-reporting guidance and the trusted-plugin threat model
- [x] CI build and local runtime tests

## 1 — local plugin platform

### Completed foundation

- [x] Decode the core `kiwios_api = "1"` metadata, checks, and actions.
- [x] Bundle/load `hello-check`; run a real check and require confirmation in the native UI before its sample action.
- [x] Add bounded local execution, process-group timeout/cancellation, and initial `kiwios.watch/1` decoding.
- [x] Add initial regression tests for SemVer, malformed output, unsafe executable paths, descendant teardown, and duplicate-run admission.

### 1A — contract-complete loading

- [x] Strictly decode and validate the current manifest surface: metadata, checks, actions, durations, non-form UI descriptors and sources, and referenced local executables.
- [ ] Define and validate required dependencies, disclosed permissions, and the supported config-schema subset.
- [ ] Discover every bundled plugin and one explicitly selected development directory; reject duplicate IDs and source conflicts without executing plugin code.

Optional-dependency contribution behavior and supervised-child declarations are deferred until real consumers establish their requirements.

### 1B — typed run results

- [ ] Retain typed Watcher state, progress, logs, protocol warnings, and terminal outcomes for each check and action.
- [ ] Validate exact event, state, step, and log boundaries and honor distinct check/action timeout defaults and overrides.
- [ ] Represent succeeded, warning, failed, timed-out, canceled, and interrupted runs separately.

### 1C — durable jobs and policy

- [ ] Add one GRDB migration chain for plugin records, approvals, jobs, audit entries, latest results, config, and layout.
- [ ] Route checks and actions through one queue with resource locks, scheduling, cancellation, bounded file logs, and restart recovery.
- [ ] Centralize confirmation and authorization; implement enable/disable, disclosure approval, temporary secret delivery, and log redaction.

### 1D — host-owned UI and setup

- [ ] Render all six API 1 kinds: `stat`, `checks`, `actions`, `table`, `log`, and `form`.
- [ ] Add setup/remote mode and Doctor without prompting remotely.
- [ ] Complete dependency, symlink-race, scheduling, persistence, authorization, accessibility, and recovery tests.

Exit: a technical user can clone, build, validate, explicitly enable `hello-check`, invoke it through the durable runtime, and understand every permission and failure state without Tailscale.

## 2 — remote UI

- Add one embedded HTTP server and one responsive PWA renderer for the same UI kinds.
- Publish only through KiwiOS-owned, tailnet-only Tailscale Serve.
- Verify Tailscale identity, CSRF/origin handling, audit logs, and local recovery.
- Exercise phone, desktop browser, sleep/wake, logout/login, and FileVault restart behavior.

Exit: after login, a tailnet administrator can inspect status and run a confirmed action from a phone; before login, the product states that it is unavailable.

## 3 — useful native capabilities

- Monitor CPU, memory, uptime, thermals, and volumes.
- Add bounded process/launchd operations, Homebrew status/actions, named SSH peers, power checks, and notifications.
- Keep privileged or GUI-prompting work behind Doctor and attended setup.

Add capabilities only alongside a real built-in or plugin consumer.

## 4 — discovery and explicit install

- Add repository-plus-exact-SHA install and update.
- Add in-app GitHub search for the `kiwios-plugin` topic, with cached/rate-limited results.
- Launch the curated catalog repository and pull-request review policy.
- Show source, commit, license, dependency, and disclosure diffs before trust.

Exit: a stranger can author, validate, publish, discover, inspect, install, update, disable, and remove a plugin without an SDK or automatic code execution.

## 5 — first real plugins

Build plugins driven by actual host needs. Use those implementations to test whether the manifest, six UI kinds, and process protocol are sufficient. Do not add plugin-to-plugin IPC or an SDK until repeated code demonstrates the missing stable interface.

## 6 — MCP, if still needed

Add supervised local/remote MCP entries and a confirmed gateway only after the core process, permission, and HTTP paths are stable. See [mcp.md](mcp.md). MCP is not part of `kiwios_api = "1"`.

## Later, only with evidence

Additional roles, theme packs, richer charts, a sandboxed plugin runner, resumable jobs, root helper, package hosting, ratings, automatic updates, language SDKs, and a brokered plugin API.

## Explicit non-goals

Docker, arbitrary plugin HTML, public Funnel exposure, MDM, high availability, pre-login service, and a second native client shell.
