# Replybox

One inbox for every message that reaches your phone, answerable in place, with nothing leaving the device. Built with Flutter 3.44.8 / Dart 3.12.2. Targets Android.

## Commands (use the quiet forms)
- `flutter pub get > $null`
- `flutter analyze`
- `flutter test test/<file>_test.dart` while iterating; `flutter test -r failures-only` once at the end
- `dart format lib test`: rarely needed if the format hook runs on every edit
- `flutter build apk --release` builds the installable artifact and `flutter build appbundle --release` the bundle Play receives; `flutter run` runs the app
- `/verify` runs format check + analyze + tests and reports failures only
- `bash scripts/version.sh name|build|check|notes` reads the version, runs CI's bump check, prints the changelog entry
- `bash scripts/rules.sh [ID]` lists rules nothing cites, and fails on a citation to a rule that does not exist

## Architecture
<!-- Fill in as Phase 1 lands: one line per folder or key file, plus the data flow (screen → state → storage). Update it in the PR that changes the structure. -->

## Conventions
- Product principles: 1. Nothing leaves the phone: no account, no server, no analytics, no internet permission in the release build. 2. Free is complete: inbox, reply, waiting list and search never move behind a payment. 3. Honest about limits: the app says what it cannot see. 4. Never hides or answers another app's notification unless the user asked. 5. Two taps to reply or clear. Every feature keeps them.
- Behavior is defined in `docs/PRODUCT_RULES.md` with stable rule IDs (`ADD-3`). Code comments, tests, PRs, and roadmap items cite them. No rule yet? `/spec <area>` before coding.
- State lives in the state layer; screens stay presentational. Don't add a second state library.
- Schema change = append a migration step and test the upgrade; never edit a merged step.
- Device services (notifications, auth, files, widgets) sit behind an interface. Tests get a no-op fake by default; only the app's entry point builds the real one.
- Every model/state change gets a test. Tests assert what the user sees (text on screen, contents of a file), never just that output exists.
- Feature order: model → migration → state → screen → test → analyze.
- One branch per theme, PR to `main`; CI (`.github/workflows/ci.yml`) must pass.
- Every merged PR is a release: `/release [major|minor|patch]` on the branch (SemVer + `CHANGELOG.md` entry; CI checks it). Nothing is tagged. The local build goes to `dist/replybox-X.Y.Z.*` (gitignored); rebuild it after any app change on the branch. It also writes the store's release notes, in every listing language, to `store/<store>/release-notes/X.Y.Z.txt`.
- **Nothing is published from CI and nothing is tagged:** no GitHub Release, no artifact, no store upload, no `vX.Y.Z`. `release.yml` builds and runs its gates as a *check*, and that is all it leaves behind. The artifact a store receives is built locally, signed from the project's gitignored keystore, and uploaded by a person — so check its signer before handing it over, because falling back to a debug key is silent (`docs/RELEASING.md`).
- Before a branch is merged: `/ship` (coverage of changed files, missing tests, docs, `/verify`, `/release`, drive it by hand, PR). The format check is the last thing before a commit, never a mid-session step.

## Workflow
- Start of an item: `git switch main`, `git pull --ff-only`, then branch from it. Never stack on an unmerged branch.
- Bundle related roadmap items into one PR by theme, and tick their boxes in that PR.
- Pass PR/issue bodies and commit messages through files (`gh pr create --body-file`, `git commit -F`): PowerShell 5.1 splits double quotes in here-strings.
- Before `gh workflow run --ref <branch>`, check `git ls-remote origin refs/heads/<branch>` matches `HEAD`.
- Anything that shows on screen gets driven by hand before the PR, and the PR says what was driven and what was only compiled. Put back any test data or setting changed on a device.
- A green open PR waits for the user; don't merge it.
- Competitors are for learning: observed behavior → what to learn → our better rule. Never copy their rules, text, or assets.
- End of session: `/handoff`. On "resume": read the handoff memory, `gh pr list`, `git log --oneline -3`.

## Token rules
- The session is what costs: every turn re-sends the whole conversation, so a short question late in a long session is not cheap. Compact or clear between roadmap items; `/handoff` is what makes that safe.
- Screenshots never leave the conversation once read. One per thing that has to be judged by eye (right-to-left layout, a chart, a theme); dump the UI as text for everything else.
- Don't open generated or platform folders unless the task is platform-specific (list in `docs/STACK_NOTES.md`).
- Grep with a `path`, then read line ranges. Never read lockfiles or generated project files whole; grep them.
- Don't spawn subagents for tasks touching fewer than ~5 files, except routine work (next rule). Use the `build-doctor` agent for long build logs.
- Routine work goes to a Sonnet subagent whatever its size — translations, doc, roadmap and changelog edits, releases. Decide the change in the main session and hand over the exact files and wording, then check the result with `git diff --stat` rather than by re-reading. A subagent's context never comes back; only its result does.
- Don't summarize diffs back; state the result in 1–3 lines.

## Adding a tool
Before installing a skill or plugin, answer five questions: does it run every session or only when called; does it ingest tool output and replay it later (a prompt-injection surface, and the one that matters most); does it spend tokens in the background; is its state reviewable in a diff or opaque; does it duplicate what `CLAUDE.md` and the docs already say. A skill — instructions loaded on demand — passes all five, so adding skills is close to free. A plugin with lifecycle hooks needs a real reason. Stale memory is worse than none: whatever a tool stored gets asserted later with the confidence of fact.

## Read on demand only
- `docs/ROADMAP.md`: phased plan and known bugs. Read when planning or picking up work.
- `docs/PRODUCT_RULES.md`: behavior rules with IDs. Read the relevant section before implementing or testing a feature.
- `docs/research/competitor-analysis.md`: what the competitor does, or a dated record that none was studied. Read before `/spec` either way — it decides whether a rules section opens with **They do** or with **Learn**.
- `docs/RELEASING.md`: signing, secrets, store release steps.
- `docs/STACK_NOTES.md`: stack commands, architecture that worked, traps, device drill.

## Gotchas
- If the repo is public: never commit secrets or personal data, and never print secrets in workflows.
- Store IDs are permanent after the first upload and carry no personal names: `com.oasisforge.replybox`.
- Store listing material (listing text, screenshots and graphics, data-safety answers and the scripts that make them, release notes) lives in `store/`, which is gitignored: one place in the repo, never Downloads.
- Quote paths in shell commands; project paths may contain spaces.
