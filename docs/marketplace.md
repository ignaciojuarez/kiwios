# Plugin discovery and catalog

KiwiOS uses GitHub for immutable plugin source. It does not host packages or operate an executable-code marketplace.

## Two discovery levels

1. **Community discovery:** cached GitHub search support exists for the `kiwios-plugin` topic, but the web-primary product does not expose it yet. Installation currently starts from an operator-supplied repository and exact commit in attended setup.
2. **Curated catalog:** KiwiOS reads a bundled, read-only catalog containing metadata for approved exact commits. Catalog inclusion means the manifest, source, license, and basic behavior were reviewed at that SHA. It is not a warranty, security certification, or automatic-update channel. The catalog in the current build has no approved entries; publishing and maintaining it as an external repository remains future operational work.

A catalog entry contains:

```json
{
  "id": "example.plugin",
  "name": "Example",
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

When web discovery is added, reviewed commits must remain visually distinct from unreviewed community repositories; stars indicate interest, not trust. The existing search implementation runs only on user request, caches responses with GitHub's validators, and reports rate-limit or offline errors without requiring a GitHub token.

## Install

The API 1 installer supports bundled plugins, an explicitly selected local development directory, and installation from a repository plus exact commit. The repository install flow:

1. accepts only a normalized GitHub HTTPS repository identity and a full commit SHA, then fetches that object into a fresh temporary bare repository with hooks and recursive submodules disabled;
2. inspects the Git tree before extraction, rejecting submodules, symlinks, unsupported modes, path traversal, Unicode/case-fold collisions, excessive file count or size, and a plugin path outside the tree;
3. exports regular files into a fresh staging directory without following links and runs the single manifest validator;
4. shows repository identity, commit, manifest/content digest, license, dependencies, and disclosed permissions;
5. requires explicit trust and records those exact approval fields;
6. copies the staged snapshot atomically into `InstalledPlugins/<id>/<commit>` and verifies it again before launch;
7. enables it only after dependencies and attended-setup prerequisites pass.

The development directory is never treated as curated. Changes there are revalidated and require reapproval when their manifest disclosure changes.

An approved plugin ID is bound to its source repository. The same ID from another source is a conflict, not an update; a local development source has its own recorded fingerprint. Duplicate installed IDs, a mismatched catalog entry, a missing commit, Git submodules, Git LFS placeholders, and manifest paths escaping the repository fail installation. API 1 does not run install scripts, Git hooks, or content filters. Missing declared Homebrew formulae are installed only through a separate, explicitly confirmed local operation.

## Updates and removal

KiwiOS may report that the catalog contains a newer approved SHA, but it never activates one automatically. Updating repeats validation and trust review, preserves plugin data/config, and atomically switches versions only after the new version is ready. The review and staged source remain retryable until the SQLite activation transaction succeeds. New admission for that plugin is gated during the switch; old execution is canceled and drained before old files are pruned. A failed activation leaves the old revision selected and its checks recoverable. After successful activation, KiwiOS retains only the active revision; startup also removes inactive snapshots and abandoned incoming directories. Git remains the source of recovery.

Remove closes admission, disables the plugin and affected dependents, and waits for process teardown. Before deleting files it records a durable pending-removal entry. Cleanup removes approvals, config, owned write-only Keychain fields, data, results, internal job and audit records, layout contributions, and KiwiOS-installed code. Bundled app resources and a user-owned development source are not deleted; they return to the Not added state. Failed cleanup keeps the entry for retry at startup; a missing or invalid source tree does not prevent removal. Pending removals cannot be added or configured.

KiwiOS records ownership only for a declared formula that was missing when a confirmed KiwiOS Homebrew install began and is present afterward. The record includes the formula's current Homebrew receipt identity; a missing or changed receipt relinquishes ownership. Plugin removal reviews each declared formula separately. An owned formula is selected for uninstall only when no other added plugin declares it and `brew uses --installed --recursive` reports no installed Homebrew dependent. Pre-existing formulae, shared formulae, and formulae whose dependency use cannot be verified are kept. The selection names every formula and warns that KiwiOS cannot discover unrelated scripts or projects. The check runs again in attended setup immediately before the serialized `brew uninstall --formula` operation; KiwiOS never passes `--ignore-dependencies`, and disables Homebrew's install cleanup and autoremove behavior. Removing the plugin does not depend on successful package cleanup: a failed uninstall is reported in the app, retains its ownership record, and can be retried through **Review package cleanup**.

KiwiOS deletes plugin-owned `<plugin-id>.config.*` accounts, including legacy accounts discoverable without a healthy manifest; shared named secrets are retained. Ownership uses the longest known plugin-ID prefix to distinguish dotted IDs. Removing a required dependency blocks dependents while preserving their added intent.

## Catalog admission

The initial catalog policy is intentionally small:

- public source repository with an OSI-compatible license;
- one plugin manifest at the declared path;
- valid `kiwios_api` and executable example path;
- accurate permission disclosure and no committed secrets;
- maintainer and security-reporting contact in the repository;
- passing KiwiOS validator fixtures.

Ratings, payments, telemetry, package hosting, automatic updates, signing infrastructure, compatibility badges beyond validation, and dependency resolution are out of scope until the ecosystem demonstrates a need.
