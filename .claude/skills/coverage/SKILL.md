---
name: coverage
description: List only the lines no test runs in the lib/ files this branch changed, without reading coverage/lcov.info. Use for the pre-merge coverage check.
argument-hint: "[base, default origin/main]"
---

1. `flutter test --coverage -r failures-only` as a background command (it takes a few minutes). Fix any failure first.
2. `dart tool/coverage_gaps.dart $ARGUMENTS`. One line per changed file: its coverage and the missed line ranges, or "no test loads it".
3. For each missed range, read just those lines with a few around them, then add a test or say why it isn't worth one (a platform dialog, a guard that can't be reached). Cite rule IDs in the new tests.
4. After adding tests, repeat 1–2 with the full suite: running only some test files measures only what those files load.

Never open `coverage/lcov.info`.
