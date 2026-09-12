# Changelog

All notable user-visible changes will be recorded here.

## Unreleased

- Added public contribution and security guidance.
- Added Xcode 27 continuous integration for tests and the example plugin.
- Clarified that plugins are trusted executable code and that KiwiOS operates after login behind Tailscale Serve.
- Added the first local plugin slice: bundled loading, TOML decoding, initial validation, bounded command execution, Watcher events, live status, confirmation, and tests.
- Fixed descendant process leaks and caller-cancellation handling by adopting process-group-aware Swift Subprocess teardown.
- Fixed duplicate plugin runs, strict SemVer prerelease validation, malformed Watcher warnings, executable-path validation, and generated-project drift checks.
- Added strict validation for manifest metadata, checks, actions, durations, non-form UI descriptors and sources, and referenced local executables.
- Marked API 1 as a pre-release draft and reconciled Watcher limits and build-host documentation.
- Defined fail-closed Serve identity handling and a link-safe, source-bound exact-commit install design.

## 2026-09-11

- Created the initial macOS app shell, architecture documents, and `hello-check` example plugin.
