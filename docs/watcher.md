# Watcher protocol: `kiwios.watch/1`

Checks, actions, and jobs report through JSON Lines on stdout: one UTF-8 JSON object per line. stderr is always plain log text. Commands do not need a library or language-specific SDK.

This protocol is a pre-release draft. The implemented vertical slice handles terminal events, logs, state shape, unknown event types, malformed structured lines, and bounded output; retaining typed state and progress remains roadmap work. Supervised-child declarations are deferred until a real consumer establishes their lifecycle requirements.

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

The last log, progress, or state update replaces that display state; logs append in the future persistent runner. For terminal status, an `error` is sticky for the run; otherwise the latest `ok` or `warn` wins. Unknown `t` values become info logs for forward compatibility. A line beginning with `{` or `[` that fails structured decoding becomes a log and marks a protocol warning. Ordinary text is a plain log without a warning. Secret values must never be emitted.

## Exit status

Checks and actions exit after emitting zero or more events:

| Exit | Result |
|---|---|
| `0` | success unless an `error` event was emitted |
| `1` | warning unless an `error` event was emitted |
| `2` or any other nonzero value | error |

An emitted `error` cannot be erased by a later zero exit. If a command emits no terminal event, KiwiOS creates one from the exit status. Cancellation is recorded separately from failure.

For checks, the latest `ok` or `warn` is displayed unless any `error` was emitted. For actions, `progress` remains visible until the job reaches succeeded, warning, failed, timed-out, or canceled.

## Progress

A missing `pct` means indeterminate progress. A command may include one level of steps:

```json
{"t":"progress","pct":42,"msg":"build","steps":[
  {"id":"resolve","label":"Packages","pct":100},
  {"id":"compile","label":"Compile","pct":35}
]}
```

Step IDs follow the contribution-ID grammar. Steps cannot be nested. The author supplies the main percentage; KiwiOS does not average steps. A terminal event completes or fails the bar.

## Ticks and jobs

- A **tick** is a one-shot scheduled check. KiwiOS owns the clock and skips overlap.
- A **job** is a user/plugin-started action with a lock, log, cancellation, and terminal result.

API 1 does not declare supervised children. Add that manifest and lifecycle surface only after a real consumer proves it is needed; until then, use launchd for independent long-running processes.

## Limits

- Maximum encoded event line: 64 KiB. A longer line is truncated into a log and records a protocol warning.
- Maximum encoded `state`: 48 KiB, leaving room for its event envelope. Larger state is rejected while the process continues.
- Maximum step count: 32.
- The current runner captures at most 64 KiB from each output stream and then shows a visible truncation marker. Persistent job logs will define a separate on-disk retention cap before API 1 freezes.
- Checks default to a 30-second timeout; actions default to one hour. Manifest values may override them.

These limits prevent a broken trusted plugin from exhausting the control plane. After API 1 freezes, changing them incompatibly requires an API bump.

## Plain commands

A command that emits ordinary text still works: stdout and stderr become logs and the exit code supplies status. Structured JSONL is needed only for state, severity messages, or progress.
