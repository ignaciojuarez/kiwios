# UI contract

KiwiOS owns all pixels: navigation, responsive layout, accessibility, loading/error states, confirmation, and theme. Plugins contribute descriptors in `plugin.toml` and JSON state through `kiwios.watch/1`. They cannot provide HTML, CSS, JavaScript, iframes, routes, or arbitrary links.

The macOS window and PWA share the same information architecture. On a phone, the sidebar becomes a navigation stack and tables become rows.

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

`stat` values are strings or numbers. `delta` is a string; KiwiOS does not infer whether it is good or bad in API 1.

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

Column and row IDs use the contribution-ID grammar. Cell values are strings, numbers, booleans, or null. API 1 tables are capped at 100 rows and 12 columns; plugins should expose a narrower check rather than paginate through the UI contract.

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
id = "uptime"
title = "Uptime"
kind = "stat"
source = "checks.uptime"
size = "1x1"
```

A page contains one kind in API 1. A plugin may register zero or more pages, sidebar items, and widgets. Sidebar entries reference a page in the same plugin. `size` is `1x1` or `2x1`; it is only the initial suggestion.

The user owns Home composition, sidebar order, and widget size. Plugin install or update never changes an existing layout. Unknown saved IDs are retained but skipped so reinstalling a plugin restores its placement. Settings remains pinned.

## Host-owned behavior

- Checks render `loading`, `ok`, `warn`, `error`, `stale`, and `unavailable` consistently.
- Buttons are disabled while their lock is held. `confirm = true` always uses a KiwiOS confirmation dialog.
- Titles, labels, values, and messages are treated as untrusted text and escaped.
- Every control has a keyboard path and accessibility label derived from its manifest label.
- Empty collections show an explicit empty state. Old data shows its age.
- Plugin output cannot choose colors, fonts, raw SF Symbols, or accessibility semantics in API 1.

New visual needs should first be tested against an existing kind. After API 1 freezes, adding a kind requires a new `kiwios_api` version.
