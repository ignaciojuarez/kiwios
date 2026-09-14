# Plugin authoring

KiwiOS plugins are folders containing a strict `plugin.toml`, referenced executable files, and an optional supported config schema. There is no API 1 SDK: commands receive argv and environment variables, write `kiwios.watch/1` JSON Lines to stdout, and use stderr for plain logs. KiwiOS owns navigation, rendering, confirmation, and job lifecycle.

Start by copying [`examples/plugin-template`](../examples/plugin-template) into a new public or private repository. Before loading it, replace `author.sample` with an ID you control, such as `acme.service-health`. IDs are stable approval, configuration, data, and layout keys, so do not change one during an ordinary update. Update the name, version, license, contribution labels, schema, and commands, then keep each referenced `./` file executable. List required Homebrew core formulae in `brew`; use `brew = []` when none are required. KiwiOS reports installed or missing status and can install missing formulae after the operator confirms the exact list locally.

The template stays within the supported config-schema subset and demonstrates `stat`, `checks`, `actions`, `table`, `log`, and `form`. Remove descriptors you do not need. A source must resolve to a contribution in the same plugin, and table and stat checks must emit the state shape documented in the [UI contract](ui.md). Commands are argv arrays, not shell strings. Use `KIWIOS_CONFIG_FILE` for non-secret configuration, `KIWIOS_DATA_DIR` for writable state, and declared named secrets from `KIWIOS_SECRETS_FILE`. Never modify installed plugin code or read another plugin's data.

## Validate and load locally

The current validation entry point is the app; the documented `kiwios validate` CLI is future tooling and is not shipped. In KiwiOS:

1. Open **Attended Setup…** from the KiwiOS menu-bar item and switch the operation mode to **Attended setup**.
2. Under **Development plugins**, choose either the plugin folder itself or a directory whose immediate children are plugin folders.
3. Choose **Reload** in attended setup, or **Reload sources** on the web Plugins page, after an edit. KiwiOS validates the complete manifest, referenced executable bits and paths, config schema, dependencies, and UI sources without executing plugin commands. A validation failure appears as a discovery error.
4. Inspect the source, manifest details, license, disclosures, and digests in attended setup. Choose **Review and add…** only when they are correct. Adding runs checks, so keep checks read-only and safe on a developer machine.
5. Exercise each action in the PWA, inspect its result and logs, and check every page and widget state. Editing the source changes its digest and requires another local review before execution.

Follow the [plugin contract](plugin-contract.md), [watcher protocol](watcher.md), [UI contract](ui.md), and [permission model](permissions.md). In particular, emit one JSON object per stdout line, never emit a secret, keep each event within protocol limits, give checks finite timeouts, and let nonzero exits and terminal events agree. Remote mode must never trigger TCC, Keychain, Gatekeeper, `sudo`, license, or device-trust prompts.

## Prepare an installable release

Repository installation identifies immutable source, not a moving tag. Before sharing a release:

1. Put one plugin at the repository root or record its relative subfolder. Do not use symlinks, submodules, Git LFS placeholders, install hooks, or files that differ only by case or Unicode normalization.
2. Add an OSI-compatible license file and make its identifier match `plugin.toml`. Document the maintainer and a private security-reporting route. Remove credentials, host paths, device identifiers, and private operational inventory.
3. Make every permission disclosure match the source's expected filesystem, process, network, secret, SSH, notification, and macOS access. Explain why each disclosure is needed in the repository README.
4. Commit the exact reviewed tree. Record the lowercase 40-character commit with `git rev-parse HEAD^{commit}` and inspect that snapshot with `git show --stat --oneline <commit>` and `git ls-tree -r --full-tree <commit>`. Inspect the license at that commit with `git show <commit>:LICENSE`, adjusting the path if the plugin uses a subfolder.
5. In the web **Plugins** page or **Attended Setup…**, enter the normalized GitHub HTTPS repository, full commit SHA, and plugin subfolder (`.` for the root). Stage it, compare the manifest and content digest, review disclosures, and explicitly trust the snapshot to install it. The web confirmation is identity-bound and expires after 60 seconds. KiwiOS does not run hooks; declared Homebrew formulae require their own local confirmation.

The `kiwios-plugin` GitHub topic is reserved for future web discovery. Current installation requires the exact repository and commit in either the reviewed PWA flow or attended setup.

## Propose catalog inclusion

The curated catalog is currently empty, and its external publication process has not launched. When catalog intake opens, submit one plugin or update per pull request by adding one entry to `catalog/catalog.json`; do not treat the schema's example as an approved entry. Use the exact commit inspected above, a normalized repository URL of the form `https://github.com/owner/repository`, and the plugin path within that commit. The entry's `id`, `version`, `kiwios_api`, and `license` must exactly match the manifest.

The pull request must identify the maintainer and private security contact, link to the license at the exact commit, list every disclosure with its reason (or explicitly state that there are none), call out any disclosure added since the previous cataloged commit, and state the local KiwiOS validation result. Include enough review notes to locate the manifest and executables at that commit. Reviewers inspect the complete source tree; tags and branches are not approval identities, and every update requires a new exact commit and review. See the [catalog review policy](../catalog/REVIEW_POLICY.md).
