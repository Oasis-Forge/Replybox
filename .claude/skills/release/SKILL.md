---
name: release
description: Bump the app version (SemVer, plus a build number where the stores need one), add its CHANGELOG.md entry, and write the store's release notes, on the current feature branch, so merging the PR releases it. Builds the local artifacts only with --build. Use when finalizing a PR.
argument-hint: "[major|minor|patch] [--build]"
---

Version bump for this branch: $ARGUMENTS (default: choose from the changes).

**Keep it to a handful of tool calls.** Every call re-sends the whole conversation, so the cost is the number of steps, not the size of the work: read the version and the top of `CHANGELOG.md` in one command, write both files, commit, write the notes file in one go. A release without `--build` should take under ten calls and about a minute.

A PR merged to `main` is a release only when it raises the version — leaving it alone is a normal, complete choice, and running this skill is how you opt in instead. On merge, `release.yml` builds as a check and leaves nothing behind — no GitHub Release, no artifact, no store upload, no tag. The artifact a store receives is the one built locally here and uploaded by a person (`docs/RELEASING.md`). CI (`bash scripts/version.sh check`) requires a version that moves to move above the one on `main` and bring a changelog entry; it always fails a version that moves down.

1. Stop if on `main`. Run `git fetch origin main --quiet`; the version to beat is `main`'s, which `bash scripts/version.sh check` compares against — there are no release tags. Read the branch's current version with `bash scripts/version.sh name` and `build`. If the branch is already above `main`, adjust the level if needed and update its entry rather than bumping twice.
2. Bump `main`'s version per SemVer and reset the lower parts (`1.4.2` → `1.5.0`):
   - `major`: breaks existing users, e.g. data or backups that older versions can't read, or a removed feature.
   - `minor`: new user-facing features or behavior.
   - `patch`: fixes, and changes users don't notice (dependencies, docs, CI, refactors).
   With a build number (`x.y.z+N`), set `N` to `main`'s build number + 1. Update every place the stack keeps the version (`docs/STACK_NOTES.md`).
3. In `CHANGELOG.md`, add `## [x.y.z] - YYYY-MM-DD` right below `## [Unreleased]`, and move anything listed under Unreleased into it. Write it from `git log --oneline origin/main..HEAD`: Added / Changed / Fixed, short, in words a user would use. Say what they can now do, not which class changed.
4. Commit `chore(release): x.y.z` with the message in a file (`git commit -F`), and put the version in the PR title or description.
5. **Only with `--build`:** build the local artifacts. `release.yml` builds them again on merge as a check, so building them here as well doubles the slowest step in the whole flow — minutes spent waiting, which no amount of better prompting shortens. Ask for it when the user is about to drive a release build by hand (`/ship` does, so it asks) or to upload to the store before the merge, and build only the artifact that will be used: the installable one for testing, the store's bundle only when it is being uploaded. Run `flutter build apk --release` in the background (`flutter build appbundle --release` when the bundle is the one being uploaded), copy the results to `dist/replybox-X.Y.Z.<ext>` (gitignored) along with any mapping or symbol file the store's crash reports need, check the built version matches, and give the user the paths. Rebuild after any later app change on the branch.
6. Write the store's release notes to `store/<store>/release-notes/X.Y.Z.txt` (`store/` is gitignored; create it if missing), in **one** write: what changed for the user, from this version's `CHANGELOG.md` entry alone, in two to four short `•` lines, once per store listing language. Don't open the app's translation catalogues to write them — they run to tens of kilobytes each, and opening two costs more than the rest of the release put together. For Google Play that's one `<code>`…`</code>` block per language (for example `<en-US>`…`</en-US>`), each at most 500 characters, in the same order as the previous file. Give the user the path: they paste the whole file into the release's notes box on each track.
