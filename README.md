# Replybox

One inbox for every message that reaches your phone, answerable in place, with nothing leaving the device.

**Principles:** 1. Nothing leaves the phone: no account, no server, no analytics, no internet permission in the release build. 2. Free is complete: inbox, reply, waiting list and search never move behind a payment. 3. Honest about limits: the app says what it cannot see. 4. Never hides or answers another app's notification unless the user asked. 5. Two taps to reply or clear.

## Getting started

```bash
flutter pub get
flutter run
```

## Docs

- [Roadmap](docs/ROADMAP.md): phases and what's done
- [Product rules](docs/PRODUCT_RULES.md): how the app behaves, with rule IDs
- [Releasing](docs/RELEASING.md): versions, signing, stores
- [Privacy policy](docs/privacy-policy.md)
- [Changelog](CHANGELOG.md)

## Development

Built with Claude Code. `CLAUDE.md` holds the conventions. The project skills are `/spec` (rules before code), `/verify` (checks), `/release` (version bump), `/ship` (pre-merge gate), and `/handoff` (session notes). Every PR merged to `main` is a release.
