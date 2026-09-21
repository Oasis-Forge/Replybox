---
name: verify
description: Run the format check, analyzer, and tests for this app and report only failures. Use after code changes or before committing.
---

Run all three from the repo root, even if an earlier one fails.

1. `dart format --output=none --set-exit-if-changed lib test`
2. `flutter analyze`
3. `flutter test -r failures-only`

Report in at most 10 lines:
- One line per step, e.g. `format ✓`, `analyze ✗ (3 issues)`, `test ✓`.
- For each failure: `path:line` and a one-line cause.

Don't paste raw logs. Don't fix anything unless the same request asked for fixes (a format failure is fixed by `dart format lib test`).
