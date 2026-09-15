# KiwiOS curated catalog

This directory is the source format for the bundled KiwiOS featured catalog. [`catalog.json`](catalog.json) lists reviewed exact commits from dedicated public plugin repositories. Community repositories discovered through the `kiwios-plugin` GitHub topic are separate and remain unreviewed.

Each catalog entry identifies one public GitHub HTTPS repository, one exact 40-character commit SHA, and the plugin path within that commit. An optional `description` is the Featured card subtitle. Do not catalog a plugin from a path inside the KiwiOS application repository. Moving branches and tags are never approval identities. The manifest at that path must match the entry's ID, version, API version, and license. Seed an entry with the plugin repository's commit, not the later KiwiOS commit that contains this file.

The shape is defined by [`catalog.schema.json`](catalog.schema.json). The example embedded in that schema is illustrative metadata, not an approved plugin or an installable catalog entry.

Catalog additions and updates follow [`REVIEW_POLICY.md`](REVIEW_POLICY.md). Inclusion records a review of the named source and commit; it is not a warranty, security certification, or automatic-update channel.

Authors can prepare a reviewable dedicated repository using the [plugin-authoring walkthrough](../docs/plugin-authoring.md). Propose one plugin or update per pull request; never add illustrative, draft, branch, or tag-based entries to the catalog.
