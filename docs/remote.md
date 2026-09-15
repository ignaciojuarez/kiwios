# Remote HTTP and PWA

KiwiOS exposes its primary UI after the owning Aqua user logs in. Hummingbird 2.26.0 serves a fixed `127.0.0.1:31928` backend, and a KiwiOS-owned Tailscale Serve HTTPS mapping is the only supported publisher. Direct localhost browsing, LAN binding, alternate proxies, Tailscale Services, and Funnel are unsupported.

## Publication lifecycle

Publishing is an explicit native action:

1. Read Tailscale status and the complete Serve configuration. Require a running user-owned node, no Funnel-enabled entries, and an empty Serve configuration.
2. Bind Hummingbird on the fixed loopback address while its request gate is closed. Binding must succeed before changing Serve.
3. Recheck the empty configuration digest, then create one background root HTTPS mapping to `http://127.0.0.1:31928`.
4. Atomically record the HTTPS origin, complete Serve digest, and enabled intent while clearing the publication journal. Revalidate ownership and open the request gate only after that record is durable. Failed startup closes the backend and exact owned mapping while retaining enabled intent for bounded retries.

After KiwiOS issues the Serve mutation it retains the attempted origin until status confirms the exact root loopback mapping or cleanup removes it. A transient status failure can therefore be retried without forgetting ownership. Cleanup still requires exact origin, target, and configuration evidence and never resets another operator's Serve configuration.

KiwiOS refuses to overwrite an existing Serve configuration. On relaunch it restores a recorded mapping only when the current origin, complete configuration digest, root loopback target, and Funnel state still match. It revalidates them every ten seconds. Drift closes the listener, revokes browser sessions, and directly updates native remote state; there is no second liveness poll. Backend failure and normal app shutdown remove only the exact owned Serve mapping while retaining enabled intent, so relaunch can publish it again. Explicit remote disable clears that intent and removes the mapping only when the exact ownership digest still matches.

The app never runs `tailscale up`, changes tailnet policy, enables HTTPS certificates, installs Tailscale, or configures Funnel. Readiness distinguishes a missing CLI, signed-out/stopped backend, unavailable tailnet HTTPS, and configuration conflict. Tailscale commands use fixed argv, `TAILSCALE_BE_CLI=1`, a small environment, bounded concurrent output capture, an eight-second timeout, and process-group teardown.

## Identity and browser sessions

Current Tailscale Serve removes incoming `Tailscale-User-*` and Funnel headers before resolving the peer. It supplies `Tailscale-User-Login` and `Tailscale-User-Name` only for a human-owned tailnet node; tagged nodes and Funnel requests receive no human identity. Serve also preserves the external Host for an HTTP backend, overwrites `X-Forwarded-Host`, and sets `X-Forwarded-Proto: https` after TLS termination. KiwiOS requires that exact configured host and HTTPS forwarding context together with both human identity headers. Missing, malformed, tagged-node, direct-loopback, and wrong-origin requests fail closed.

`GET /api/session` exchanges the current Serve identity for a random, bounded, absolute eight-hour browser session. Authentication and mutations do not extend that expiry. The bearer value is stored only as a SHA-256 digest and sent as a `Secure; HttpOnly; SameSite=Strict` cookie with the same lifetime. A custom same-origin request header prevents cross-site session creation. Sessions are bound to the exact login and display name and are revoked when publication stops or trust validation fails. Refreshing a presented matching session replaces its slot. Global session-capacity exhaustion is reported separately from the one-minute mutation limit and requires retaining the current browser session, waiting for expiry, or restarting remote access.

Every mutation additionally requires:

- an exact configured `Origin`;
- `Content-Type: application/json` and a body no larger than 64 KiB;
- the session cookie and its current one-use CSRF token;
- a unique request UUID retained for ten minutes;
- no more than 30 mutations for that session in one minute.

The CSRF token rotates when a mutation is admitted, including when the runtime later rejects it. The browser reads the replacement from the response header. Snapshot work carries a ten-second cooperative budget, and mutation work must pass a fifteen-second cooperative deadline before admission. Cancellation and deadlines are checked again at the durable queue boundary. An accepted job is not detached behind an HTTP timeout: the response waits for its authoritative accepted/skipped result. A non-cancellation-aware store operation can finish after its nominal budget rather than produce a false timeout while a state change continues.

The same-user loopback-process threat remains outside API 1's boundary, consistent with [permissions.md](permissions.md). Tailnet reachability and a browser cookie alone are never treated as identity.

## Wire API

The PWA uses three session endpoints plus cookie-less OTA GETs for iPhone install. API responses are `no-store`; errors contain a stable generic message and do not expose runtime details.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/session` | Establish an identity-bound cookie and return the first CSRF token. |
| `GET` | `/api/snapshot` | Return current host-owned navigation, descriptors, and state. |
| `POST` | `/api/mutate` | Submit one typed operation to the runtime. |
| `GET` | `/ota/{token}/manifest.plist` | Cookie-less OTA manifest for a confirmed iPhone install. Token is the capability. |
| `GET` | `/ota/{token}/app.ipa` | Cookie-less IPA stream for that token. Funnel requests are rejected. |

The snapshot root is `kiwios.remote/1`:

```json
{
  "api": "kiwios.remote/1",
  "mode": "remote",
  "viewer": {"loginName": "person@example.com", "displayName": "Person"},
  "plugins": [],
  "jobs": [],
  "catalog": [],
  "pluginSearch": {"query": "", "error": null, "searchedAt": null, "results": []},
  "nativeTools": null,
  "nativeToolsRefreshing": false,
  "layout": {"widgets": [], "hiddenWidgets": [], "wideWidgets": [], "sidebar": []},
  "settings": {
    "operationMode": {"value": "remote", "guidance": "..."},
    "launchAtLogin": {"status": "passed", "detail": "...", "guidance": "..."},
    "remoteAccess": {"enabled": true, "desired": true, "message": "...", "guidance": "..."},
    "developmentPlugins": {"configured": false, "guidance": "..."},
    "namedSecrets": {"guidance": "..."}
  },
  "doctor": []
}
```

Each plugin includes identity and lifecycle fields; `setup` (`ready`, `configuration-required`, `authorization-required`, `attended-setup-required`, or `error`); configuration availability and remote-editability; check and action metadata; page, widget, and sidebar descriptors; latest and live results keyed by source; host-scoped action resource keys; public configuration values; and the host-supported configuration schema. A plugin with public schema fields can be configured through the web dialog; write-only Keychain fields remain attended-only. Descriptor kinds remain exactly `stat`, `checks`, `actions`, `table`, `log`, `form`, `watchers`, and `artifacts`. All plugin strings are inserted as text. Plugins cannot contribute markup, script, CSS, routes, links, or accessibility semantics.

The snapshot includes every current nonterminal job so the owning check, action, and native control can cancel it; completed plugin outcomes live in each plugin's bounded latest results. KiwiOS starts a prompt-free native inventory on launch and rechecks it when the five-minute cache becomes stale; an explicit refresh or host-changing operation also refreshes it. During collection, `nativeToolsRefreshing` keeps the Tools and Brew pages in an inline collecting state without a warning banner. When collection finishes, `nativeTools` contains sampled power, application, user LaunchAgent, named SSH peer, notification-authorization, and installed Homebrew state. SSH destinations and secret values are never serialized. The overall response is bounded to 8 MiB.

A mutation contains `requestID`, `operation`, and exactly the required fields for that operation. Plugin operations are `refreshCheck`, `requestAction`, `confirmAction`, `cancelJob`, `disablePlugin`, `enablePlugin`, `requestPluginDependencies`, `confirmPluginEnable`, `requestPluginInstall`, `searchPlugins`, `requestPluginUpdate`, `confirmPluginInstall`, `requestPluginRemoval`, `confirmPluginRemoval`, `saveConfig`, and `reloadPlugins`. `enablePlugin` restores an unchanged approved source immediately; otherwise it returns a bounded source review. `confirmPluginEnable` consumes an identity-bound, one-use 60-second token, rechecks the exact source fingerprint, records approval, and begins prompt-free readiness checks. `requestPluginDependencies` exposes only the exact currently missing `brew` formulae declared by an approved plugin, returns an identity-bound, one-use 60-second confirmation, and queues the noninteractive Homebrew install locally after `confirmNativeOperation` revalidates those formulae. It accepts no package names from the browser. `requestPluginInstall` accepts exactly one of two shapes: `{repository}` or `{repository, commit, pluginPath, catalogID}`. The URL shape resolves the repository's current `HEAD` to a full commit SHA and stages the repository root. The catalog shape looks up `catalogID` in the bundled catalog and stages that entry's repository, commit, and path; client strings must match the entry, but they are not used as fetch identity. After a catalog match, KiwiOS compares the staged manifest ID, version, API, and license with the catalog and returns `reviewed: true` on the confirmation. The confirmation lists currently missing declared Homebrew formulae; `confirmPluginInstall` copies the snapshot and, when that list is still missing, queues the same noninteractive Homebrew install. It never accepts a branch, tag, arbitrary community pin, filesystem path, or credential. Snapshot `installingPluginIDs` names plugins whose install or removal transition is in progress; plugin rows include `sourceRepository` for GitHub installs. `searchPlugins` accepts `{query}` (empty string means the `kiwios-plugin` topic only), calls GitHub search directly, and stores results or `rateLimited`/`github`/`invalidQuery` errors in `pluginSearch` for the next snapshot, with `searchedAt` set on both success and failure. It does not reuse native marketplace busy state. Catalog rows may include an optional `description` used as the Discover card subtitle. `requestPluginUpdate` accepts only an installed plugin ID with a currently detected higher manifest version and stages its recorded repository, subfolder, and detected exact SHA through the same review. `confirmPluginInstall` consumes an identity-bound, one-use 60-second token and rechecks the staged revision before activation.

`requestPluginRemoval` first verifies that the plugin's owned write-only Keychain accounts can be enumerated with an interaction-disabled Keychain context. It then returns a separate identity-bound, one-use 60-second review. `confirmPluginRemoval` deletes only KiwiOS-owned plugin content and those prompt-free config accounts; an enumeration or deletion that would require Keychain UI fails closed and is recoverable in Attended Setup. Remote removal never changes Homebrew: the review names every declared formula as retained, and package cleanup remains an attended, separately confirmed operation. Settings operations are `refreshDoctor` and `saveLayout`. Native operations are `refreshNativeTools`, `requestProcessTermination`, `requestLaunchAgentRestart`, `confirmNativeOperation`, `probeSSH`, `deliverNotification`, `requestArtifactInstall`, and `confirmArtifactInstall`; a dedicated remote Homebrew confirmation is created only by `requestPluginDependencies`; first-time install queues reviewed missing formulae from `confirmPluginInstall`. `requestArtifactInstall` is identity-bound confirmation; the following OTA GETs use the token, not the session cookie. Unknown, unrelated, missing, and null required top-level fields are rejected. `saveConfig` carries only fields changed from the loaded form plus its `configRevision`; KiwiOS applies the patch only when that revision still matches and returns HTTP 409 on conflict. `saveLayout` accepts only known, unique widget and sidebar contribution keys.

Actions declared with `confirm = true` use a two-step runtime exchange. `requestAction` returns a random, identity-bound, one-use challenge with its host-owned label and a 60-second expiry. The PWA renders a KiwiOS confirmation dialog and returns that token through `confirmAction`. Browser state cannot mint a grant, and neither request waits for job completion. Every admitted job, cancel, configuration change, disable, and confirmation event records the verified `tailscale:<login>` actor. If a response is lost after admission, the durable request UUID prevents replay; the owning plugin view shows the accepted action's state.

Process termination and current-user LaunchAgent restart use the same two-step principle. The browser supplies only a PID or an already-discovered label; KiwiOS binds a one-use challenge and revalidates it at confirmation, queue admission, and execution. A restart never edits a plist or calls `sudo`: it runs only `launchctl kickstart -k` for one regular, nonsymlink plist owned by the current user under `~/Library/LaunchAgents`; changed, invalid, and duplicate labels fail closed. SSH probes accept only a configured peer name. Notification delivery requires authorization already granted during attended setup. Apart from a confirmed install of an approved plugin's declared missing core formulae and the confined, interaction-disabled deletion of a confirmed removed plugin's owned config accounts, the remote contract has no Homebrew mutation, SSH-peer edit, notification-authorization, Keychain-secret creation or update, development-directory, login-item, operation-mode, or Serve-publication operation.

## Offline behavior

The service worker caches only the application shell: `/`, CSS, JavaScript, the web manifest, and the host-owned PNG favicon/app icons. It never intercepts or caches `/api/` requests. When the Mac, app, Tailscale, or Serve is unavailable, the shell states that live status and actions are unavailable and polls for reauthentication. Previously displayed results are labeled as potentially old, controls are disabled until reconnection, and no mutation is queued for replay. Phone navigation includes Home, Tools, Brew, Plugins, Events, Settings, and active plugin pages. Events shows one latest line per plugin. Interrupted work directs the user to inspect effects before requesting a fresh action. Secret fields remain attended-setup guidance, and polling does not replace focused or unsaved configuration drafts. Drafts remain editable offline; Save and other mutations require a live connection. Blank numeric fields and the enum keep-current choice preserve existing values. Identical polling snapshots do not rebuild the page, and plugin reloads retain the last complete display until the new runtime is ready.

Session creation has its own five-per-minute limit per verified login. Each login retains at most four device sessions; a new session without a replaceable cookie evicts that login's oldest session once the allowance is full. Clearing cookies cannot consume all 64 global slots. Replacing a valid session preserves its mutation-rate window. Global capacity exhaustion remains a distinct 503 response.

Publication also journals the checked plan before changing Serve. After a crash, startup or a local retry verifies and removes only that exact attempted mapping before clearing the journal. Failed verification retains recovery state and never resets another Serve configuration.
