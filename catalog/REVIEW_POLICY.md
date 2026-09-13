# Catalog review policy

A catalog pull request must add or update a single exact commit and include the evidence needed to review it. Reviewers verify all of the following:

- the repository is public, uses a normalized GitHub HTTPS identity, and provides an OSI-compatible license;
- the entry names a full 40-character commit SHA and a plugin path contained by that commit;
- the manifest at that path matches the catalog ID, version, `kiwios_api`, and license;
- KiwiOS validation passes without executing plugin commands;
- permission disclosures match the source's expected filesystem, process, network, secret, SSH, notification, and macOS access;
- the source contains no committed credentials, private device inventory, install hooks, submodules, symbolic links, or Git LFS placeholders;
- the repository documents a maintainer and a private security-reporting route.

The pull request description must include the exact repository, 40-character commit, and plugin path; identify the maintainer and private security contact; link to the license at that commit; list every permission disclosure and why it is required, or explicitly state that there are none; call out disclosures added since the previous cataloged commit; and report the result of local validation through KiwiOS. Authors should inspect the submitted snapshot with `git show --stat --oneline <commit>`, `git ls-tree -r --full-tree <commit>`, and `git show <commit>:LICENSE` (adjusting the license path for a plugin subfolder) before submission.

Review the full source tree at the proposed commit, including dependency changes and executable files. A previously reviewed repository receives no standing approval: every update requires a new exact commit and a fresh review. Changes that expand permissions must be called out in the pull request.

At least one maintainer other than the change author reviews an entry before merge. A maintainer must recuse when they publish the plugin. Remove an entry when its source disappears, its license becomes unclear, or a credible security issue cannot be resolved promptly. Removing catalog metadata does not remotely uninstall code from users' Macs.
