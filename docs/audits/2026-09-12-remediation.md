# Codebase audit remediation — 2026-09-12

All 27 findings in the [source audit](2026-09-12-codebase-audit.md) have an implementation or an explicit policy correction in the working tree. This is an implementation record, not a claim that the app has passed its release gates. Builds and tests were initially deferred while Xcode installed; the follow-up validation below records the completed run.

Three GPT Sol medium subagents implemented plugin/storage, remote/PWA, and native/UI changes. The primary agent integrated runtime/queue fixes and cleanup, and a separate source review checked the concurrency changes. Existing implementation work was preserved; nothing was committed or published.

## Finding disposition

| Finding | Change | Primary source |
|---|---|---|
| R01 | Integer schema/default/enum values use the exact JavaScript safe range; native forms never narrow an arbitrary Double to Int; PWA validates finite/safe input. | `PluginConfigSchema.swift`, `PluginContentView.swift`, `Web/app.js` |
| R02 | Policy transitions close main-actor admission and pause the queue before Doctor/work checks; mode is persisted before publication. Pending configuration/installation changes block mode changes, native validation rechecks policy after suspension, and execution revalidates admission. | `HubRuntime.swift`, `JobQueue.swift`, `HubIntegrations.swift` |
| R03 | Disablement closes all affected execution gates and cancels their schedules/jobs before any fallible persistence/audit write. Cancellation includes all transitive dependents; only enabled-intent states are persisted as such. | `HubRuntime.swift` |
| R04 | Uninstall gates admission, drains processes, records a durable pending removal, performs cleanup, then removes database records. Startup retries pending removals, which cannot be enabled/configured. Missing source trees remain removable. | `HubIntegrations.swift`, `Persistence.swift` |
| R05 | Delete-data uninstall removes owned write-only Keychain credentials. Persisted field ownership and reserved-prefix enumeration cover missing manifests and legacy accounts; longest known plugin-ID matching handles dotted IDs. Shared named secrets remain outside that reserved namespace. | `PluginConfiguration.swift`, `PluginPolicy.swift`, `PluginManifest.swift` |
| R06 | Publication remains tied to a canonical staged review ID until activation succeeds. Failed activation preserves the old selection and retryable staging. Old execution is drained before inactive code cleanup. | `PluginInstaller.swift`, `HubIntegrations.swift` |
| R07 | Discovery returns per-candidate/root errors and healthy plugins. Every duplicate-ID/canonical-source contender is excluded. Invalid installed records are isolated as source errors. | `PluginDiscovery.swift`, `HubRuntime.swift` |
| R08 | Per-plugin serialization, SQLite revision comparison, Keychain compensation, and a durable interrupted-secret-write marker replace ambiguous partial saves. SQLite is authoritative; derived config files are repaired before launch. Failed repairs retain the recovery marker. | `PluginConfiguration.swift`, `Persistence.swift` |
| R09 | Plugins presents one config editor; native/PWA editors submit changed fields and the loaded revision. Conflicts preserve drafts for review. | `PluginManagementView.swift`, `PluginContentView.swift`, `HubRemote.swift`, `Web/app.js` |
| R10 | Serve publication retains an attempted origin and journals the checked publication plan before mutation. Cleanup/restart retry verifies exact mapping ownership; unrelated configuration is never reset. | `TailscaleService.swift`, `HubRemote.swift` |
| R11 | Shutdown cancels and awaits startup and periodic tasks; initialization checks cancellation/stopped state after suspension and before creating new tasks. | `HubRuntime.swift`, `HubIntegrations.swift` |
| R12 | Readiness reconciliation restores enabled dependents in dependency order. Lifecycle versions and a final dependency recheck prevent stale Doctor results from undoing disablement. | `HubRuntime.swift` |
| R13 | Every redacted output chunk reaches the independently bounded file sink; the smaller result/live capture remains bounded separately. Cancellation flushes withheld redactor suffixes through the same sink. | `Runtime.swift`, `HubRuntime.swift` |
| R14 | Native completion invalidates and refreshes Tools on success and possible partial-effect failure. A refresh generation prevents an older in-flight snapshot from republishing stale state. | `HubIntegrations.swift`, `HubPresentation.swift` |
| R15 | LaunchAgent discovery bounds directory entries and plist reads, reports duplicate labels, and probes in batches of six with a 15-second aggregate admission budget plus bounded in-flight teardown. | `NativeCapabilities.swift`, `NativeToolsView.swift` |
| R16 | Successful activation and startup prune inactive snapshots and abandoned incoming directories; only the selected revision is retained. | `PluginInstaller.swift`, `HubIntegrations.swift` |
| R17 | Removed the misleading task-group request timeout. Monotonic deadlines/cancellation gate cooperative work and durable admission; accepted state changes are awaited rather than detached or falsely reported as canceled. Contracts distinguish admission budgets from an end-to-end guarantee. | `RemoteServer.swift`, `RemoteSecurity.swift`, `HubRemote.swift`, `docs/remote.md` |
| R18 | A missing Tailscale executable is resolved again on later service use. | `TailscaleService.swift` |
| R19 | Server and browser sessions have the same absolute eight-hour lifetime. | `RemoteSecurity.swift` |
| R20 | Required enums without saved/default values show an explicit blank choice in both clients. | `Web/app.js`, `PluginContentView.swift` |
| R21 | PWA Jobs renders retained progress-step labels and percentages. | `Web/app.js` |
| R22 | Mutation payloads must match their operation's exact required key set, including configRevision for config patches. | `RemoteServer.swift`, `RemoteSecurity.swift` |
| R23 | Session replacement preserves the mutation-rate window. Creation is limited separately; each login retains at most four sessions, with oldest-owned-session eviction. Global exhaustion has a distinct 503 response and accurate recovery advice. | `RemoteSecurity.swift`, `RemoteServer.swift`, `Web/app.js` |
| R24 | Shared lexical path/plugin-ID/commit helpers and aligned catalog schema rules reduce validator drift. Resolved containment, source fingerprints, and file-type checks remain. | `PluginContracts.swift`, `PluginConfigSchema.swift`, `PluginInstaller.swift`, `catalog/catalog.schema.json` |
| R25 | Ambient Aqua-user SSH configuration is explicitly part of the locally reviewed probe policy. UI/contracts disclose possible local/proxy/known-host commands and forwarding. Native SSH remains unavailable through remote mutations. Existing configured key/proxy use is preserved. | `NativeToolsView.swift`, `docs/permissions.md`, `docs/remote.md` |
| R26 | Per-plugin summaries derive from durable latest contribution records, independent of the global recent-200 job list. | `Persistence.swift`, `HubRuntime.swift` |
| R27 | Queue shutdown drains in-flight admission writes and supervised task handles before returning; interrupted-job recovery remains the crash fallback. | `JobQueue.swift` |

## Architecture and cleanup

- One `ProcessTransport` now owns common reader, capture, redaction, deadline, and teardown mechanics. Plugin, native, Git, and Tailscale adapters retain their own executable/environment/overflow/grace-period policies. No dependencies were added or removed.
- Native and remote presentation values are grouped in concrete structs. Existing service actors and the runtime admission facade retain their responsibilities; no additional orchestration framework or protocol layer was introduced.
- Remote listener termination directly updates presentation state. The duplicate hub liveness poll is removed, while independent Serve trust validation remains.
- One persistence snapshot supplies jobs, audit entries, and latest results. The hub decodes changed results and only republishes changed values.
- Home, Plugins/approval, Jobs, and Settings are separate existing screen types; stat/table parsing is in `PluginUIData.swift`. RootView owns navigation and presentation.
- Removed unused one-shot delayed admission, WatchEventStream and its isolated self-test, unused installer restoration/state fields, unrevisioned configuration wrappers, dead persistence adapters, and the dependency throwing adapter. Existing relevant regression sources now target production APIs and current output/discovery semantics; they were not run.
- Static asset routes share one guarded registration table. Listener readiness uses one checked continuation with cancellation, deadline, and exactly-once completion.
- SSH port zero is rejected, failed peer saves keep the sheet open, process buttons describe SIGTERM accurately, and Doctor/Tools share the FileVault query.

The audit's optional URLCache replacement remains unnecessary: current explicit GitHub validator/rate-limit handling has a real consumer and no measured defect. Existing host wire fields were retained for compatibility; strict mutation validation and revisioned config metadata address the demonstrated drift. A larger controller or complete wire-model rewrite was not required for these fixes.

## Validation and limits

Completed source checks: all application/test Swift files parse; PWA and service-worker JavaScript pass JavaScriptCore syntax checks without execution; catalog JSON parses; the project passes plist validation; XcodeGen regenerated the project; `git diff --check` passes. Source callsites and the new project-file coverage were inspected. These checks do not typecheck the app or establish macOS behavior.

The initial source pass ran no application build or test suite. A subsequent Xcode 27.0 (27A266a) unsigned Debug build succeeded, and all 43 tests passed with zero failures, including runtime subprocess execution and cancellation. Application launch opened a 1100×720 window, and graceful quit completed. This run fixed compiler compatibility, missing persistence helpers, and plugin fingerprint path normalization, and repaired stale approval/timeout fixtures. Remaining release checks include expanded migration/fault injection, sleep/wake, TCC/Keychain/Gatekeeper behavior, accessibility, browser workflows, signed-app lifecycle, and CI runner provisioning. Live SSH, Homebrew, and Tailscale operations were not exercised.

Two boundaries are explicit: HTTP admission budgets do not forcibly interrupt non-cooperative storage calls, and a crash during a secret write requires an attended resave rather than storing secret rollback data outside Keychain. Synchronous mounted-volume metadata behavior on hung network filesystems still requires macOS validation; this source pass does not claim an operating-system call can be forcibly canceled.

MCP and new roadmap features remain deferred.
