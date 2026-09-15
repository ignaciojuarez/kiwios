# Plugin discovery and catalog

KiwiOS uses GitHub for immutable plugin source. It does not host packages or operate an executable-code marketplace.

## Two discovery levels

1. **Community discovery:** the Plugins **Discover** section searches public GitHub repositories tagged `kiwios-plugin` on submit. Empty query means the topic only. Results are unreviewed; stars measure interest, not trust. Installing a community result sends only `{repository}`; KiwiOS resolves `HEAD` to an immutable commit and stages the repository root. The header **+** dialog is the same URL install. Attended setup retains the explicit commit and subfolder workflow for author tooling.
2. **Featured catalog:** KiwiOS reads a bundled, read-only catalog of approved exact commits in dedicated plugin repositories. Catalog inclusion means the manifest, source, license, and basic behavior were reviewed at that SHA. It is not a warranty, security certification, or automatic-update channel. Featured **Install** sends `{repository, commit, pluginPath, catalogID}`; the server stages the bundled catalog fields after they match, then compares the staged manifest with the catalog before showing `reviewed: true`. Do not catalog a plugin from a path inside the KiwiOS application repository.

A catalog entry contains:

```json
{
  "id": "example.plugin",
  "name": "Example",
  "description": "Optional card subtitle from the catalog, not GitHub.",
  "repository": "https://github.com/example/kiwios-plugin",
  "commit": "40-character-git-sha",
  "path": ".",
  "version": "1.2.0",
  "kiwios_api": "1",
  "license": "MIT"
}
```

The manifest at `path` must match the entry's ID, version, API, and license. Catalog changes are reviewed pull requests. Tags and branches are never approval identities because they can move; each update requires a newly approved commit SHA.

The app loads `catalog/catalog.json` from its signed resources as read-only data. It rejects malformed entries, duplicate IDs, non-normalized repositories, unsafe paths, and non-exact commits. Selecting a reviewed entry fills its repository, commit, and plugin path; after staging, KiwiOS compares the validated manifest with the catalog metadata before presenting it as that reviewed revision. The catalog never bypasses the ordinary source inspection and trust confirmation.

Reviewed catalog rows stay visually distinct from unreviewed community repositories: Featured cards show a Reviewed label and the catalog description; community cards show a Community label and GitHub description. Stars indicate interest, not trust. Search runs only on user submit, caches responses with GitHub's validators, and reports rate-limit or offline errors in Discover without requiring a GitHub token. An installed plugin is recognized by matching `catalog[].id` to `plugins[].id`; Discover does not add a separate installed flag.

## Install

The API 1 installer supports bundled plugins, an explicitly selected local development directory, and installation from a GitHub repository. The PWA resolves the supplied repository URL to an exact commit before the repository install flow:

1. accepts only a normalized GitHub HTTPS repository identity and the resolved full commit SHA, then fetches that object into a fresh temporary bare repository with hooks and recursive submodules disabled;
2. inspects the Git tree before extraction, rejecting submodules, symlinks, unsupported modes, path traversal, Unicode/case-fold collisions, excessive file count or size, and a plugin path outside the tree;
3. exports regular files into a fresh staging directory without following links and runs the single manifest validator;
4. shows repository identity, commit, manifest/content digest, license, dependencies, disclosed permissions, and disclosure changes in a bounded review;
5. requires explicit trust and records those exact approval fields. In the PWA, the review is bound to the verified tailnet identity, expires after 60 seconds, and is consumed once;
6. copies the staged snapshot atomically into `InstalledPlugins/<id>/<commit>` and verifies it again before launch;
7. records it as enabled and begins readiness checks. If the reviewed confirmation listed missing declared formulae, KiwiOS revalidates that exact list and queues the local Homebrew install without a second dialog. Retry of still-missing formulae uses **Install packages** on the plugin card; it never opens a system prompt.

The development directory is never treated as curated. Changes there are revalidated and require reapproval when their manifest disclosure changes.

An approved plugin ID is bound to its source repository. The same ID from another source is a conflict, not an update; a local development source has its own recorded fingerprint. Duplicate installed IDs, a mismatched catalog entry, a missing commit, Git submodules, Git LFS placeholders, and manifest paths escaping the repository fail installation. API 1 does not run install scripts, Git hooks, or content filters. Missing declared Homebrew formulae are named in the install confirmation and queued with that one confirm. A later retry remains a separate **Install packages** confirmation. KiwiOS never opens a system prompt for this.

## Updates and removal

For installed GitHub plugins, KiwiOS checks the repository's default-branch `HEAD` every 15 minutes. It offers Update only when that immutable commit contains the same plugin ID at the recorded subfolder and its manifest has a newer semantic version; unrelated repository commits and version downgrades are ignored. KiwiOS never activates an update automatically. Updating repeats validation and trust review, preserves plugin data/config, and atomically switches versions only after the new version is ready. The PWA stages the detected SHA using the same canonical repository and safe subfolder; its metadata/digest review is identity-bound, one-use, and 60 seconds long. New admission for that plugin is gated during the switch; old execution is canceled and drained before old files are pruned. A failed activation leaves the old revision selected and its checks recoverable. After successful activation, KiwiOS retains only the active revision; startup also removes inactive snapshots and abandoned incoming directories. Git remains the source of recovery.

Remove closes admission, disables the plugin and affected dependents, and waits for process teardown. Before deleting files it records a durable pending-removal entry. Cleanup removes approvals, config, owned write-only Keychain fields, data, results, internal job and audit records, layout contributions, and KiwiOS-installed code. Bundled app resources and a user-owned development source are not deleted; they return to the Not added state. Failed cleanup keeps the entry for retry at startup; a missing or invalid source tree does not prevent removal. Pending removals cannot be added or configured.

KiwiOS records ownership only for a declared formula that was missing when a confirmed KiwiOS Homebrew install began and is present afterward. The record includes the formula's current Homebrew receipt identity; a missing or changed receipt relinquishes ownership. A remote removal review explicitly retains every declared formula and cannot mutate Homebrew. An attended removal review may select an owned formula for uninstall only when no other added plugin declares it and `brew uses --installed --recursive` reports no installed Homebrew dependent. Pre-existing formulae, shared formulae, and formulae whose dependency use cannot be verified are kept. The selection names every formula and warns that KiwiOS cannot discover unrelated scripts or projects. The check runs again in attended setup immediately before the serialized `brew uninstall --formula` operation; KiwiOS never passes `--ignore-dependencies`, and disables Homebrew's install cleanup and autoremove behavior. Removing the plugin does not depend on successful package cleanup: a failed uninstall is reported in the app, retains its ownership record, and can be retried through **Review package cleanup**.

KiwiOS deletes plugin-owned `<plugin-id>.config.*` accounts, including legacy accounts discoverable without a healthy manifest; shared named secrets are retained. Remote deletion is permitted only after both enumeration and deletion use an interaction-disabled Keychain context; failure gives an explicit Attended Setup recovery path rather than opening a prompt. Ownership uses the longest known plugin-ID prefix to distinguish dotted IDs. Removing a required dependency blocks dependents while preserving their added intent.

## Catalog admission

The initial catalog policy is intentionally small:

- public source repository with an OSI-compatible license;
- one plugin manifest at the declared path;
- valid `kiwios_api` and executable example path;
- accurate permission disclosure and no committed secrets;
- maintainer and security-reporting contact in the repository;
- passing KiwiOS validator fixtures.

Ratings, payments, telemetry, package hosting, automatic updates, signing infrastructure, compatibility badges beyond validation, and dependency resolution are out of scope until the ecosystem demonstrates a need.
