# UI contract

KiwiOS owns all pixels: navigation, responsive layout, accessibility, loading/error states, confirmation, and theme. Plugins contribute descriptors in `plugin.toml` and JSON state through `kiwios.watch/1`. They cannot provide HTML, CSS, JavaScript, iframes, routes, or arbitrary links.

The host-owned PWA renders all API 1 kinds with phone-accessible navigation and horizontally scrollable tables. The macOS menu-bar app does not duplicate plugin content; its compact attended window handles secrets, prompt-capable setup, optional local trust/revision review, and recovery. The PWA reviews an existing plugin source or stages an immutable repository revision without running it, then presents the identity-bound confirmation before adding or enabling it. Inactive plugins contribute no Home widgets or sidebar pages. Home stat widgets omit result timestamps and descriptive source metadata, and retain the previous value until refreshed state arrives. Routine check rows omit result timestamps. Actions expose their state through plugin views, while routine monitoring checks update plugin content without creating visible history or separate log files.

## Sources

API 1 supports these source references:

| Source | Resolves to |
|---|---|
| `checks` | all checks in the current plugin |
| `checks.<id>` | latest result, state, and log for one check |
| `actions` | all actions in the current plugin |
| `actions.<id>` | one action plus its latest job |
| `config` | the plugin's supported config-schema fields |

Sources cannot cross plugin boundaries. A missing source is a manifest validation error. Runtime absence is rendered as unavailable, never as a blank page or crash.

## Kinds

| Kind | Valid source | Contract |
|---|---|---|
| `stat` | `checks.<id>` | `state.value` required; optional `unit`, `detail`, `delta` |
| `checks` | `checks` or `checks.<id>` | host-rendered severity rows from terminal events |
| `actions` | `actions` or `actions.<id>` | host-rendered buttons and latest job state |
| `table` | `checks.<id>` | `state.columns` plus `state.rows` |
| `log` | one check or action | bounded captured stdout/stderr |
| `form` | `config` | supported config-schema fields |
| `watchers` | `watchers` | one session row per active plugin with a valid `[watch]` declaration |

For `stat`, the state object may contain only `value`, `unit`, `detail`, and `delta`. `value` is required and is a string or number; the other three fields are optional strings. KiwiOS does not infer whether `delta` is good or bad in API 1. Missing live data and invalid shapes render an explicit unavailable or error state.

A table state has this shape:

```json
{
  "columns": [
    {"id":"name","label":"Name"},
    {"id":"status","label":"Status"}
  ],
  "rows": [
    {"id":"api","name":"API","status":"Up"}
  ]
}
```

Table state contains exactly `columns` and `rows`. A table has 1–12 columns and at most 100 rows. Each column contains exactly a unique contribution-ID `id` and a nonblank `label`; `id` is reserved for row identity and cannot be a column ID. Each row contains exactly its unique contribution-ID `id` and one cell for every declared column. Cell values are strings, numbers, booleans, or null. Nested arrays, objects, unknown cells, and missing cells make the table unavailable. Plugins should expose a narrower check rather than paginate through the UI contract.

Unknown kinds make that contribution unavailable and put the plugin in `error` on an API 1 host.

## Pages, sidebar, and widgets

```toml
[[ui.pages]]
id = "status"
title = "Service"
kind = "checks"
source = "checks"

[[ui.sidebar]]
id = "service"
label = "Service"
page = "status"

[[ui.widgets]]
id = "health"
title = "Health"
kind = "stat"
source = "checks.health"
size = "1x1"
```

A page contains one kind in API 1. A plugin may register zero or more pages, sidebar items, and widgets. Sidebar entries reference a page in the same plugin. Widget `size` is a fixed presentation width: `1x1` stays compact and `2x1` always spans two columns.

The user owns Home composition, sidebar order, and widget visibility. Home uses a compact four-column grid on wide screens and a two-column grid otherwise; it never uses three columns. **Edit layout** uses direct drag-and-drop, including touch and keyboard paths, plus a removal control and blueprint add tile. Its square, scrollable picker disables widgets already on Home. Sidebar-page controls remain in the edit view. KiwiOS persists each change. Installing or updating a plugin initializes contributions only when no saved layout exists and does not rewrite an existing layout. Removed plugins have their saved layout entries deleted. Settings remains pinned.

## Host-owned behavior

- Checks and actions distinguish running, succeeded, warning, failed, timed-out, canceled, interrupted, and unavailable results. While a job runs, live progress, state, and bounded logs replace the previous terminal presentation.
- A visible nonterminal job has an explicit Cancel control in its owning check, action, Watcher start action, or prompt-free native tool row.
- Buttons are disabled while their lock is held. `confirm = true` always uses a KiwiOS confirmation dialog.
- Plugins shows one configuration editor rather than repeating declared form pages. The PWA sends changed public fields with an expected config revision, retains drafts after a conflict, and requires an explicit selection for required enums without a default. Integers use the safe JSON range documented in the plugin contract. Forms render strings, numbers, integers, booleans, and enums. Write-only fields use secure controls only in attended setup, remain blank to preserve an existing secret, and appear remotely only as guidance.
- Plugins makes every lifecycle state visible. The PWA can stage a canonical GitHub repository, full SHA, and safe subfolder; it renders a bounded, scrollable source/metadata/digest/disclosure review and uses an identity-bound one-use confirmation to install or update. It also presents an exact-formula, identity-bound confirmation that queues the local Homebrew install for an approved plugin's missing requirements. Remote removal retains all Homebrew formulae and proceeds only when Keychain cleanup can remain interaction-disabled; package cleanup and any prompt-capable recovery remain in attended setup.
- Titles, labels, values, and messages are treated as untrusted text and escaped.
- Every control has a keyboard path and accessibility label derived from its manifest label.
- Empty collections show an explicit empty state. Old data shows its age. A disconnected PWA labels displayed results as potentially old and disables mutations; it never queues offline actions.
- PWA polling preserves focused and unsaved configuration edits, including across disconnection. Draft fields remain editable offline; Save requires a live connection. Blank numeric fields and the enum keep-current choice preserve saved values or defaults rather than clearing them. Secret fields explain how to update them in attended setup and never render an editable remote secret control.
- Home guides local setup using current Doctor, plugin, launch-at-login, and remote availability state. Interrupted-action controls request fresh work through ordinary confirmation; they never resume or replay the old action.
- Plugin output cannot choose colors, fonts, raw SF Symbols, or accessibility semantics in API 1.
- Events is a host-owned terminal-style tab with one latest line per plugin. It consumes the shared event protocol and is separate from action state in plugin views.

New visual needs should first be tested against an existing kind. After API 1 freezes, adding a kind requires a new `kiwios_api` version.

Plugin action views render retained, bounded progress. The PWA uses a near-black terminal/workbench system with monospaced typography, thin separators, single-color geometric status marks, and segmented progress bars; severity is always written as text as well as color. Brew is a host-owned web tab with a searchable installed formula/cask inventory. Tools exposes prompt-free power, process, LaunchAgent, SSH-peer, and notification state. Native web mutations are limited to revalidated process termination, confirmation-bound restart of an owned current-user LaunchAgent, a confirmation-bound local install of an approved plugin's exact missing formulae, configured SSH probes, and already-authorized notification delivery; other setup-capable native mutations remain local.
