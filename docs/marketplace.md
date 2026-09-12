# Plugin discovery and catalog

KiwiOS uses GitHub for plugin source and discovery. It does not host packages or operate an executable-code marketplace.

## Two discovery levels

1. **Community discovery:** KiwiOS queries GitHub repository search for the `kiwios-plugin` topic. These results are unreviewed; users choose whether to trust and install them.
2. **Curated catalog:** a KiwiOS-maintained repository containing metadata for approved exact commits. Catalog inclusion means the manifest, source, license, and basic behavior were reviewed at that SHA. It is not a warranty, security certification, or automatic-update channel.

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

The in-app result list puts curated commits first, then community repositories by GitHub stars and recent activity. Stars indicate interest, not trust. Search runs only on user request, caches responses with GitHub's validators, and surfaces rate-limit or offline errors without requiring a GitHub token. Authentication can be added later if public API limits become a real constraint.

## Install

The planned API 1 installer supports bundled plugins, an explicitly selected local development directory, and installation from a repository plus exact commit. The remote install flow:

1. accepts only a normalized GitHub HTTPS repository identity and a full commit SHA, then fetches that object into a fresh temporary bare repository with hooks and recursive submodules disabled;
2. inspects the Git tree before extraction, rejecting submodules, symlinks, unsupported modes, path traversal, Unicode/case-fold collisions, excessive file count or size, and a plugin path outside the tree;
3. exports regular files into a fresh staging directory without following links and runs the single manifest validator;
4. shows repository identity, commit, manifest/content digest, license, dependencies, and disclosed permissions;
5. requires explicit trust and records those exact approval fields;
6. copies the staged snapshot atomically into `InstalledPlugins/<id>/<commit>` and verifies it again before launch;
7. enables it only after dependencies and attended-setup prerequisites pass.

The development directory is never treated as curated. Changes there are revalidated and require reapproval when their manifest disclosure changes.

An approved plugin ID is bound to its source repository. The same ID from another source is a conflict, not an update; a local development source has its own recorded fingerprint. Duplicate installed IDs, a mismatched catalog entry, a missing commit, Git submodules, Git LFS placeholders, and manifest paths escaping the repository fail installation. API 1 does not run install scripts, Git hooks, content filters, or automatically install dependencies.

## Updates and removal

KiwiOS may report that the catalog contains a newer approved SHA, but it never activates one automatically. Updating repeats validation and trust review, preserves plugin data/config, and atomically switches versions only after the new version is ready. The previous code version may be removed after successful activation because Git remains the source of recovery.

Uninstall disables the plugin, cancels its jobs, removes installed code, and asks whether to retain its data. Removing a required dependency first disables dependents with a reason.

## Catalog admission

The initial catalog policy is intentionally small:

- public source repository with an OSI-compatible license;
- one plugin manifest at the declared path;
- valid `kiwios_api` and executable example path;
- accurate permission disclosure and no committed secrets;
- maintainer and security-reporting contact in the repository;
- passing KiwiOS validator fixtures.

Ratings, payments, telemetry, package hosting, automatic updates, signing infrastructure, compatibility badges beyond validation, and dependency resolution are out of scope until the ecosystem demonstrates a need.
