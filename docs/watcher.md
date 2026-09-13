# Shared event protocol: `kiwios.watch/1`

Every plugin check and action can report through JSON Lines on stdout: one UTF-8 JSON object per line. stderr is always plain log text. Commands do not need a library or language-specific SDK. KiwiOS uses the same result shape in plugin views, the one-line Events tab, and the optional Watcher plugin.

This protocol is a pre-release draft. KiwiOS retains typed state, progress, steps, logs, protocol warnings, and terminal results for each check and action. Supervised-child declarations are deferred until a real consumer establishes their lifecycle requirements.

## Events

Every event has a `t` field:

| `t` | Fields | Meaning |
|---|---|---|
| `log` | `msg`, optional `lvl` | diagnostic text |
| `progress` | optional `pct`, `msg`, `id`, `steps` | determinate or indeterminate progress |
| `ok` | `msg`, optional `state` | healthy terminal status |
| `warn` | `msg`, optional `state` | degraded terminal status |
| `error` | `msg`, optional `state` | failed terminal status |
| `state` | `state` | replace the latest structured state without ending progress |

`lvl` is `debug`, `info`, `warn`, or `error`. `pct` is a number from 0 through 100. `msg` is a user-visible string. `state` is a JSON object consumed by a KiwiOS UI kind.

```jsonl
{"t":"log","lvl":"info","msg":"checking service"}
{"t":"progress","pct":40,"msg":"building"}
{"t":"ok","msg":"service is up","state":{"value":"Up"}}
```

The latest progress and state are retained independently; logs append and retain their stdout or stderr source. For terminal status, an `error` is sticky for the run; otherwise the latest `ok` or `warn` wins. Unknown `t` values become info logs for forward compatibility. A line beginning with `{` or `[` that fails structured decoding becomes a log and marks a protocol warning. Ordinary text is a plain log without a warning. Secret values must never be emitted.

## Exit status

Checks and actions exit after emitting zero or more events:

| Exit | Result |
|---|---|
| `0` | success unless an `error` event was emitted |
| `1` | warning unless an `error` event was emitted |
| `2` or any other nonzero value | error |

An emitted `error` cannot be erased by a later zero exit. If a command emits no terminal event, KiwiOS creates one from the exit status. Cancellation is recorded separately from failure.

For checks, the latest `ok` or `warn` is displayed unless any `error` was emitted. For actions, `progress` remains visible until the job reaches succeeded, warning, failed, timed-out, canceled, or interrupted. These six outcomes remain distinct in retained results. Cancellation keeps output received before process teardown. A run left active across app termination is recorded as interrupted during recovery; it is not silently changed into a failure or retried.

## Progress

A missing `pct` means indeterminate progress. A command may include one level of steps:

```json
{"t":"progress","pct":42,"msg":"build","steps":[
  {"id":"resolve","label":"Packages","pct":100},
  {"id":"compile","label":"Compile","pct":35}
]}
```

Step IDs follow the contribution-ID grammar. Steps cannot be nested. The author supplies the main percentage; KiwiOS does not average steps. A terminal event completes or fails the bar.

## Watcher sessions

Watcher is an optional bundled plugin, not a second scheduler or action-history view. A plugin representing an external service, script, build, or project can opt into its single sessions surface by pointing at its own status check and optional start action:

```toml
[watch]
status = "service"
start = "start"
```

`status` must name a check in the same plugin. `start`, when present, must name an action in that plugin. The observed plugin remains responsible for deciding how to validate the external target, whether it is up, what command starts it, and which events or progress it emits. Watcher shows the latest status, last log line, and progress, and exposes Start only when the status is unavailable or unhealthy. Multiple plugins can declare sessions; Watcher renders one row per active declaration in one page and widget.

The session is persistent as KiwiOS state: its latest result and schedule survive between ticks and app launches. It does not mean KiwiOS keeps the status command running. An independently long-running service should still be owned by launchd or its normal service manager; the declared check observes it and the action may start it.

The separate Events tab shows one current terminal-style line per plugin. It is a compact diagnostic view over the same protocol, including setup and protocol problems, rather than action history.

## Checks and jobs

- A **check** is a one-shot observation. KiwiOS owns optional schedules, skips overlap, and retains only the latest typed result.
- A **job** is a user-started action with a lock, bounded log, cancellation, audit entries, and terminal result.

API 1 does not declare supervised child processes. Use launchd for independent long-running processes and `[watch]` to describe how KiwiOS observes and starts them.

## Limits

- Maximum encoded event line: 64 KiB. A longer line is truncated into a log and records a protocol warning.
- Maximum encoded `state`: 48 KiB, leaving room for its event envelope. Larger state is rejected while the process continues.
- Maximum step count: 32.
- Step IDs use the contribution-ID grammar, must be unique within an event, and steps cannot contain nested steps. Percentages include both endpoints: `0` and `100` are valid; values outside that range are rejected.
- The runner captures at most 64 KiB from each output stream and records truncation in the typed result. No separate per-run log files are created.
- Checks default to a 30-second timeout; actions default to one hour. Manifest values may override them.

These limits prevent a broken trusted plugin from exhausting the control plane. After API 1 freezes, changing them incompatibly requires an API bump.

Known secret values are removed from captured stdout, stderr, live updates, and retained results. Streaming holds back enough bytes to recognize a secret split across subprocess chunks before releasing output. This is a last-resort safeguard; plugins must still avoid emitting secrets.

## Plain commands

A command that emits ordinary text still works: stdout and stderr become logs and the exit code supplies status. Structured JSONL is needed only for state, severity messages, or progress.
