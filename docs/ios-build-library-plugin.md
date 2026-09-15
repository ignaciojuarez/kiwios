# iOS build library and phone install plugin proposal

**Status:** inventory and tailnet tap-to-install plugin published at [`github.com/ignaciojuarez/kiwios-ios-build-library`](https://github.com/ignaciojuarez/kiwios-ios-build-library). The KiwiOS tree keeps an author copy in [`examples/ios-build-library/`](../examples/ios-build-library/). KiwiOS does not bundle the plugin source.

The plugin follows the current configuration and remote setup protocol: `description` is set for the Plugins card, `library_root` is required public configuration with no default, and KiwiOS reports `setup: configuration-required` until that field is saved. Saving the public Configure dialog is enough to promote the plugin. `keep_days` and `max_gb` are optional retention settings used only by the confirmed Clean old builds action. Checks emit `kiwios.watch/1` stat, table, and artifacts state. Install is host-owned `native.artifact-delivery`.

## Decision

Create a separately maintained `ios-build-library` plugin. It indexes a single, deliberately staged folder of exported iOS builds from many projects and gives each build a short title, description, version/build, and feature label.

The plugin is a **build library**, not a build system. An existing developer, agent, CI job, or future build-runner puts a signed `.ipa` and a tiny metadata sidecar into the library. The plugin never searches arbitrary project folders, invokes `xcodebuild`, signs/re-signs an app, uploads artifacts to a third party, or invents project-specific build settings.

The desired phone outcome is “tap a build and begin installation,” similar to [Sqim](https://www.sqim.dev/). Sqim achieves this with its own CLI, account, hosted build delivery, and install page. KiwiOS should not copy that service or use it as a required dependency. Its equivalent must stay tailnet-only, host-owned, and explicitly scoped to approved artifacts.

## Smallest build-library format

The configured root contains direct child directories only—one directory per build. The scanner does not recurse and rejects symbolic links. This makes one folder safe to understand and prevents a “scan my projects” feature from becoming a source-code crawler.

```text
~/iOS Builds/
  kiwi-notes-1.4.0-104/
    kiwios-build.json
    KiwiNotes.ipa
  field-log-2.0.0-31/
    kiwios-build.json
    FieldLog.ipa
```

`kiwios-build.json` is required because an IPA can reveal a bundle identifier and version but not a human mini-description or feature label:

```json
{
  "schema": 1,
  "project": "Kiwi Notes",
  "title": "Share-sheet rewrite",
  "description": "Faster sharing with offline drafts.",
  "version": "1.4.0",
  "build": "104",
  "feature": "share-sheet",
  "createdAt": "2026-09-14T18:30:00Z",
  "bundleID": "example.kiwi-notes",
  "ipa": "KiwiNotes.ipa"
}
```

All strings are short, plain text. `feature` is a free-form label rather than a global enum: individual projects should not be forced into one taxonomy. `version` is SemVer; `build` is a nonempty build string. The plugin computes the build identity from the root-relative directory, bundle ID, version/build, and IPA content hash. It never accepts an external URL, an absolute path, a parent traversal, or an installation manifest in this file.

On every scan, the wrapper verifies that the IPA is a regular file in that build directory and reads its archive metadata to compare bundle identifier, short version, and build number with the sidecar. A mismatch is displayed as invalid and is never offered for delivery. Apple remains the final authority for signature, provisioning, device registration, and installability.

## The user experience

The plugin gets one **Builds** sidebar tab. Its default view is newest builds first and shows a compact, paginated list:

| Project | Title | Version | Feature | Built | Install |
|---|---|---|---|---|---|
| Kiwi Notes | Share-sheet rewrite | 1.4.0 (104) | share-sheet | Sep 14 | Install on iPhone |

The library must support:

- project filter;
- exact feature-label filter;
- text search across project, title, description, version/build, and feature;
- sort by built date, semantic version/build, or title; and
- an explicit invalid/unavailable state instead of hiding malformed or changed builds.

The build folder is configured once as an ordinary public path setting. API 1 can render that as a string field but cannot offer a native directory picker. A future picker is optional; it is not a reason to scan `~/` or add a file-management dependency.

## Viability against the current plugin contract

| Requested capability | API 1 assessment | Smallest correct path |
|---|---|---|
| Point at one staged build folder | Viable | A public configuration string and a strict direct-child scanner. The plugin discloses the selected root as a trusted-code filesystem read. |
| List builds from multiple projects | Viable up to the generic table limit | Parse the sidecars and return a host-owned table/check. Invalid entries appear as findings. |
| Title, short description, version, feature | Viable | The sidecar supplies these fields; IPA metadata is a consistency check, not the source of editorial text. |
| Sort/filter/search in the Builds tab | Not fully expressible | API 1 tables have no in-tab filter/sort controls, pages contain one UI kind, and tables have a 100-row limit. A saved config can select one sort order, but that is not the requested phone library UX. |
| List every build, including a large history | Not fully expressible | It needs an artifact-specific paginated query rather than increasing generic plugin-table limits for every plugin. |
| Tap a build on iPhone to install it | Not viable as a plain plugin | Plugins cannot host files, create routes, or render links/buttons inside table rows. KiwiOS needs a host-owned artifact-delivery capability and a row-level install control. |
| Install without a VPN/public service | Not a KiwiOS fit | KiwiOS is intentionally tailnet-only. The iPhone must reach the KiwiOS Serve origin, normally with Tailscale connected; Funnel and a public artifact host remain unsupported. |
| Build, sign, or provision projects remotely | Deliberately out of scope | This library consumes already-exported artifacts. A project build runner is a different plugin/design with much larger signing, source, and job semantics. |

## Why “tap to install” needs native work

An iPhone cannot reliably install an arbitrary IPA simply because a PWA can list it. Apple’s over-the-air workflow requires an HTTPS-hosted manifest that refers to the IPA, and export records the app URL, title, bundle ID, and version in that manifest. The IPA still must use a valid distribution/development signing and provisioning arrangement for the receiving device. [Apple: export for OTA installation](https://help.apple.com/xcode/mac/current/en.lproj/dev23ea8b877.html) · [Apple: distribute to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)

KiwiOS’s present backend intentionally serves only its PWA/API on loopback behind Tailscale Serve. A plugin cannot add an HTTP listener, public route, or its own UI. Letting a folder-scanning shell plugin serve arbitrary files would break those boundaries.

Add one narrowly shaped, versioned native capability instead:

```text
native.artifact-delivery
  accepts: validated build records from an approved plugin
  serves: one generated OTA manifest and one immutable IPA only
  never serves: arbitrary plugin/root files, source trees, directories, logs, or URLs
```

The host owns the install button, generated `itms-services` link, manifest, HTTPS endpoint, expiry/revocation, audit record, streaming, and error presentation. The plugin owns only indexing and metadata validation.

Before issuing a delivery link, the host must revalidate the canonical root, no-symlink rule, file identity, size, content hash, and sidecar/IPA metadata match. It then creates a short-lived, unguessable capability restricted to exactly that manifest/IPA pair. It must stream the file without loading it in memory, revoke delivery when the source changes, and keep no general file-serving endpoint.

The iPhone installation service will not necessarily preserve the PWA session cookie when it fetches the manifest and IPA. Therefore this flow requires a small device proof-of-reachability spike before it is promised: confirm Tailscale Serve’s identity behavior for the installation client, HTTPS certificate acceptance, `itms-services` handoff, and token expiry during a real device download. The new endpoint remains behind Serve; it must not fall back to a LAN listener, Funnel, redirect, or public bearer URL.

## Required KiwiOS work

1. Define `native.artifact-delivery` and its bounded plugin-to-host artifact record. Do not give plugins an arbitrary HTTP or filesystem-serving API.
2. Add an `artifacts` UI kind (or equally narrow extension) with host-owned pagination, filters, sorts, text search, and per-row **Install on iPhone** action. This is preferable to turning generic tables into miniature application frameworks.
3. Bind the one-tap install gesture to the displayed artifact identity/content hash. Recheck the artifact immediately before link issuance and let iOS present its own install confirmation; audit the verified tailnet actor and selected build identity.
4. Add generated-manifest/IPA delivery endpoints with strict request/transfer limits, expiring capability tokens, and cancellation-safe transfer cleanup. Keep them separate from session/CSRF-protected JSON mutations because iOS’s installer performs a different download flow.
5. Update the plugin, UI, remote, permissions, operations, and test contracts together. This is a public contract addition, not a wrapper-script trick.

The requested interactive library and installation experience should wait for steps 1–4. A status-only scanner can be released earlier, but it should be described as a build inventory—not as phone installation.

## Delivery sequence

### Release A — external build-inventory plugin

- Publish a small exact-commit plugin with the direct-child layout, strict sidecar schema, IPA metadata consistency checks, and a single Builds table/check page.
- Allow manual folder-path configuration and one fixed, newest-first sort. Display at most the existing table limit with an honest “more builds exist” finding; do not fake complete search or arbitrary install buttons.
- Include fixtures for valid entries, malformed JSON, duplicate identities, symlinks, changed IPA bytes, missing IPA, and metadata mismatch.

### Release B — host artifact library

- Add the `artifacts` UI and native delivery capability.
- Move filtering, search, sorting, and pagination into the host. The plugin returns bounded index records; the host never lets the plugin specify HTML, route names, external URLs, or filesystem paths outside its approved root.
- Implement read-only delivery to a real iPhone on the tailnet. The phone user initiates every install; no background/automatic installation exists.

### Release C — signed-build readiness

- Add explicit preflight states for file hash changed, unreadable IPA, sidecar/IPA mismatch, unavailable delivery origin, and known iOS install failure response where observable.
- Test Ad Hoc/development distribution on a registered device and document prerequisites such as device registration, provisioning, Developer Mode where required, sufficient phone storage, and Tailscale reachability. Do not claim KiwiOS can repair Apple signing or provisioning.

### Separate future work — build runner

If remote project builds are required after the library works, design a different `ios-build-runner` plugin. It should require an explicit project manifest and fixed export command/profile per project, serial execution, signing/preflight status, bounded logs, artifact publication into this library, and no source discovery. Do not add it to the library plugin merely because both mention iOS builds.

## Non-goals

- No Sqim account, uploader, third-party cloud relay, public hosting, or automatic setup scripts.
- No public URLs, Funnel, direct LAN service, arbitrary file browser, arbitrary IPA upload, or plugin HTTP server.
- No installation of unsigned, unprovisioned, modified-after-index, or metadata-mismatched IPA files.
- No automatic build retention/deletion. The user owns the staged build folder; cleanup needs a separate, explicit policy.
- No TestFlight/App Store/MarketplaceKit integration. Those are distinct Apple distribution channels with different account, regional, entitlement, and review requirements.
