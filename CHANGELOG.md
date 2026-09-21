# Changelog

Notable changes per release, written for users. Versions follow [Semantic Versioning](https://semver.org) and match the app version. Every merged PR is a release (see `docs/RELEASING.md`).

## [Unreleased]

## [0.1.1] - 2026-09-21

### Added
- A throwaway notification-capture spike, debug builds only, that records what
  the phone's notifications actually contain. It answers three of the five
  questions the product depends on and writes the results to
  `docs/research/spike.md`. Nothing user-facing changed.

### Changed
- The Android SDK levels the app compiles and targets are now written down
  rather than inherited from whatever Flutter is installed.

### Fixed
- The release check that keeps unwanted permissions out of the app was rejecting
  a clean build. It had never run before, because it only runs when a release
  raises the version and none had.

## [0.1.0] - 2026-09-21

### Added
- Project setup: docs, Claude Code tooling, CI, and the release workflow.
- An empty Flutter app for Android, with strict lints and release signing wired in. No features yet.
