# KiwiOS plugin template

Copy this directory into your own repository. It is a generic API 1 plugin with a strict supported config schema, safe JSONL commands, and examples of the standard plugin-owned UI kinds. The host-owned `watchers` kind is supplied by the optional Watcher plugin.

## Rename before loading

Change `id = "author.sample"` in `plugin.toml` to an ID you control before KiwiOS sees the plugin. Use lowercase letters and digits separated by `.` or `-`, for example `acme.backup-status`. The ID becomes the stable key for approval, configuration, data, and layout; do not rename it in a normal update.

Also replace the sample name, contribution labels and behavior, the placeholder copyright line in `LICENSE`, and the maintainer/contact placeholders in `SECURITY.md`. Keep the manifest license value consistent with the license file.

The configuration form demonstrates schema rendering; the static sample commands do not consume its values. When adding real behavior, read public values from `KIWIOS_CONFIG_FILE` and keep write-only values out of output.

Keep `plugin.sh` executable after copying:

```sh
chmod +x plugin.sh
```

Checks must be bounded and read-only. Put changes behind actions, use `confirm = true` when an action can be destructive, and disclose every expected command, path, network destination, secret, SSH peer, notification, and macOS permission in `[permissions]`. An enabled plugin is trusted executable code running with the Aqua user's authority; disclosures do not sandbox it.

See [Plugin authoring](../../docs/plugin-authoring.md) for validation, local installation, release, and catalog-submission steps.
