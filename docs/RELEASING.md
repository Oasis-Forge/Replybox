# Releasing

Every PR merged to `main` is a release. The app version is the source of truth: `x.y.z` follows [Semantic Versioning](https://semver.org) (major for breaking changes, minor for new features, patch for fixes and everything else). Mobile stores also need a build number `N` (`x.y.z+N`) that grows by one with every release. `bash scripts/version.sh name` and `build` read them.

1. **Before merging**, bump the version on the branch with `/release [major|minor|patch]`, or by hand: edit the version and add a `## [x.y.z] - YYYY-MM-DD` entry to `CHANGELOG.md`. CI fails if the version isn't above the one on `main` or has no changelog entry. Dependabot PRs are exempt and ship with the next release.
2. **On merge**, `release.yml` builds the release artifacts as a check, runs whatever gates the stack has, and says in its summary whether the merge was a release — a Dependabot merge is not, by design. It publishes nothing and tags nothing.

Any other platform's release workflow is run by hand from the Actions tab, or with `gh workflow run <workflow>.yml --ref main`.

## Nothing is published from CI

**The artifact a store receives is built on one machine and uploaded by a person.** No GitHub Release, no CI artifact, no store upload from a workflow.

A CI build is unsigned or debug-signed unless the signing secrets are set, so anything downloadable from a workflow is a build nobody can install over an existing copy and nobody can upload to a store — while looking exactly like the one that shipped. Keeping one source for the real artifact removes that class of mistake, and the upload key never has to leave the machine.

What that means in practice:

- **`release.yml` still builds**, because that proves the release build compiles somewhere other than the developer's machine, and it is where the release-manifest and permission gates run. Its build is a check, not a deliverable.
- **No tag is pushed either.** `scripts/version.sh check` compares a PR against the version on `origin/main` instead. On main — the merge build — `scripts/version.sh released` compares the merge with the commit before it and reports whether it was a release. A merge that left the version alone (a Dependabot PR, or one merged behind another that took the same version) is built and checked all the same; the summary says it is not a release, and its changes go out with the next version. The job needs `fetch-depth: 2` for it.
- **The record of a version is its `CHANGELOG.md` entry** and the commit that raised it, not a tag or a release page.
- **Signing is local.** Keep the keystore and `key.properties` in the project, both gitignored. The store-credential secrets below become unnecessary; set them only if a CI-built artifact ever has to be uploadable.
- **Check the signer before every upload.** The fall back to a debug key is silent, and a store rejects the upload rather than explaining it.

A store-publishing service account is not created at all.

<!-- Android and Google Play are the only targets, now and later (docs/ROADMAP.md). The iOS, macOS and desktop-store sections were deleted at kickoff, 21 September 2026. -->

## When a release is bad

Every merged PR is a release, so there will be a bad one. Decide none of this while it is happening.

1. **Stop the spread first.** In Play Console, halt the rollout on the track it is on. A version code that has been published can never be reused or re-uploaded, and an app cannot be rolled back to an earlier release: the only way out is a higher version going out.
2. **Fix forward, never backward.** `git revert` the merge and open a PR, and CI refuses it — the reverted tree's version is at or below main's, which is exactly what `scripts/version.sh check` exists to catch. That is a stuck pipeline during the one hour it matters. If the fix *is* a revert, revert on a branch off a freshly pulled `main` **and** run `/release patch` on it, so the undo is itself a release with its own version and changelog entry.
3. **Don't rewrite main's history to undo it.** The version gate reads the version off `origin/main`, so rewriting the commit that raised it makes the next check compare against the wrong thing. Go forward instead.
4. **Say what happened in the changelog**, in the same user-facing words as everything else: what was wrong and what the new version does about it.
5. **Read the crash before guessing.** Play symbolicates with the deobfuscation mapping carried inside the uploaded bundle, so the stack traces in Play Console are readable. Keep the bundle you uploaded: it is the only copy, since CI publishes nothing.

## GitHub secrets and variables

Add them in GitHub → Settings → Secrets and variables → Actions, or with `gh secret set NAME` (it prompts for the value).

| Name | Kind | Used by | Value |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | `claude.yml` | Output of `claude setup-token` |
| `ANDROID_KEYSTORE_BASE64` | secret | `release.yml` | Base64 of `upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | secret | `release.yml` | Keystore password |
| `ANDROID_KEY_ALIAS` | variable | `release.yml` | Key alias, e.g. `upload` (the default). A *secret* here would be worse than useless: GitHub masks a secret’s value everywhere it appears in a log, so `upload` turns `upload-keystore.jks` into `***-keystore.jks` |
| `ANDROID_KEY_PASSWORD` | secret | `release.yml` | Key password |
| ~~`PLAY_SERVICE_ACCOUNT_JSON`~~ | — | — | **Not used.** Nothing publishes to a store from CI; the artifact is built locally and uploaded by hand. Listed so nobody adds it back |

The release workflow is the one job that decodes the keystore and holds the Play key, so the third-party actions in it are pinned to a commit SHA with the version in a trailing comment (Dependabot still bumps them). A major-version tag is mutable: whoever controls the action can move it onto new code, and that code would run with those secrets. Actions under `actions/` stay on their major tag — same trust as the runner itself.

## Protect `main`

Settings → Rules → Rulesets → New branch ruleset, target `main`:
- Require a pull request before merging.
- Require status checks to pass: the CI job names. Run CI on one PR first so the names show up in the picker.
- Allowed merge methods: merge and squash, not rebase. After a rebase merge the commit before main's tip is the PR's own last commit, so a release whose version bump came earlier in the PR is reported as no release.
- Block force pushes and deletion.
- Bypass list: empty, so even the admin merges through a PR, or Repository admin if you want an emergency override.

Check it with `gh api repos/Oasis-Forge/Replybox/rulesets`. The classic branch-protection endpoint answers 404 for a branch protected only by a ruleset, which looks like no protection at all.

## Public repository

- **Secrets stay safe:** GitHub masks secret values in logs, and the workflows never print them. CI uses `pull_request`, not `pull_request_target`, so PRs from forks run without secrets. `claude.yml` runs only for `haskalach` -- `github.actor` is a person, not the `Oasis-Forge` organisation that owns the repo.
- **Nothing downloadable is produced**, so a public repo exposes no build at all: `release.yml` creates no GitHub Release and uploads no artifact.
- **Fork PRs:** Settings → Actions → General → "Approval for running fork pull request workflows" → "Require approval for all external contributors".
- **Commit emails are public.** This repo commits under the Oasis Forge support address: `git config user.email "oasisforge.support@gmail.com"`.
- **License:** with no `LICENSE` file the code is "all rights reserved". Worth deciding deliberately here: a readable repo is one of the few ways "nothing leaves your phone" can be checked rather than believed (`docs/PLAN.md` section 2).
- A public repo gets free GitHub-hosted runners. CI uses ubuntu-latest only, so a private repo costs the same.

## Privacy policy

Google Play requires a public privacy policy URL.
1. Settings → Pages → Deploy from a branch → `main` / `/docs`. **Pages on a private repository needs a paid plan.** `/kickoff` makes the repo private by default, so before the store needs the URL, either make the repo public (read "Public repository" above first) or host the policy somewhere else and put that URL in the listing. Deciding this late is what turns it into a blocker.
2. The policy is then live at `https://oasis-forge.github.io/Replybox/privacy-policy`.

**Pages publishes every file in `docs/`**, on the same domain the store listing points at — the roadmap, the product rules, this runbook and the competitor research included. `docs/_config.yml` excludes them, and CI runs `scripts/check_public_docs.sh` so a doc added later can't quietly go up with them. Add each new file there as either excluded or public; nothing is published by default.

## One-time setup: Android

1. Create the upload keystore and back it up with its passwords. Losing it means asking Google for an upload-key reset.
   ```bash
   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Base64 it into the clipboard for `ANDROID_KEYSTORE_BASE64` (PowerShell):
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Clipboard
   ```
3. Wire the signing config into the Android build (`docs/STACK_NOTES.md` → Scaffold). The scaffold does not generate one, so without it the release build is debug-signed and Play rejects the upload for not matching the upload certificate. **Keep the keystore and a `key.properties` in the Android project, both gitignored** — signing is local, so this is the path that produces every uploadable bundle, not an extra.
4. **Check the signer before every upload**, because the fall back to a debug key is silent: `keytool -printcert -jarfile dist/<slug>-X.Y.Z.aab`. The owner must be your certificate, not `CN=Android Debug`. On Windows `keytool` may not be on PATH — call it as `"$JAVA_HOME/bin/keytool.exe"`, since a bare `keytool` prints nothing and reads as a pass.
5. In Play Console, create the app with package `com.replybox.app` and keep Play App Signing enabled.
6. **Upload every AAB by hand** in Play Console → Testing → Internal testing. The API can't create an app's first release, and by the rule above it isn't used for the later ones either. No service account is created.
7. **Production access** for a new personal developer account is an application, not a counter. At least 12 testers opted in for 14 continuous days is the entry condition, but the form also asks what the testers did, what they said, and what changed as a result — so run the closed test as a real test and keep the notes. Confirm the current rule in Play Console, and start it before the features are finished: this is the longest-lead item in the whole roadmap.
8. **Contact details.** Play shows two public emails: the store listing's support email (App support) and the developer account's email (About the developer, on every app). Give both one dedicated support address, and keep the Play Console login private. A personal account also shows its legal name and country there; only an organization account (it needs a D-U-N-S number) shows the brand instead.
9. **Payments profile → Public merchant profile:** the merchant name is the publisher, never a personal name, with the same support email.
10. **In-app products:** a one-time product needs a purchase option (type Buy). Add the testers' Google accounts under Settings → Licence testing (account level, not per app), so their test purchases cost nothing. Products only show in a build installed from a Play testing track, once the product is Active.
11. **EU trader status** (Digital Services Act): an app with purchases makes you a trader, and Play then shows your address, phone and email to EU users. Declare it before applying for production; a virtual office address keeps a home address private.
12. **Release notes** for every release come from `/release`, in `store/play/release-notes/X.Y.Z.txt`. All store listing material lives in `store/` (gitignored).

Without the signing secrets, CI signs each APK with a throwaway debug key, which can't update an installed copy: back up in the app, uninstall, install, restore.

## One-time setup: Claude GitHub Action

Run `/install-github-app` from a `claude` terminal, or install the Claude GitHub app on the repo and add `CLAUDE_CODE_OAUTH_TOKEN`. Then comment `@claude <request>` on an issue or PR. Only `haskalach` can trigger it, and each run is capped at 15 turns.

## App icon and splash screen

Draw them from one committed source, generate the platform files with the stack's tools, and commit the results. The commands are in `docs/STACK_NOTES.md`.
