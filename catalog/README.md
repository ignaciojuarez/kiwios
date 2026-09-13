# KiwiOS curated catalog

This directory is the source format for the future KiwiOS curated plugin catalog. [`catalog.json`](catalog.json) intentionally contains no approved entries yet. Community repositories discovered through the `kiwios-plugin` GitHub topic are separate and remain unreviewed.

Each catalog entry identifies one public GitHub HTTPS repository, one exact 40-character commit SHA, and the plugin path within that commit. Moving branches and tags are never approval identities. The manifest at that path must match the entry's ID, version, API version, and license.

The shape is defined by [`catalog.schema.json`](catalog.schema.json). The example embedded in that schema is illustrative metadata, not an approved plugin or an installable catalog entry.

Catalog additions and updates follow [`REVIEW_POLICY.md`](REVIEW_POLICY.md). Inclusion records a review of the named source and commit; it is not a warranty, security certification, or automatic-update channel.

Catalog intake and external publication have not launched, so `catalog.json` remains empty. Authors can prepare a reviewable repository using the [plugin-authoring walkthrough](../docs/plugin-authoring.md). When intake opens, propose one plugin or update per pull request; never add illustrative, draft, branch, or tag-based entries to the catalog.
