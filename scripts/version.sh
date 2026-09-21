#!/usr/bin/env bash
# One version tool for CI, the release workflow, and /release.
#
#   scripts/version.sh name      print x.y.z
#   scripts/version.sh build     print the build number N (0 when there is none)
#   scripts/version.sh check     fail unless the version is above the base branch's
#                                and CHANGELOG.md has a "## [x.y.z] - YYYY-MM-DD" entry.
#                                On the base branch itself there is no PR to gate, so
#                                it reports whether this commit is a release instead
#   scripts/version.sh released  print true when this commit raised the version above
#                                the previous commit's, else false: whether a merge to
#                                the base branch is a release (the merge build)
#   scripts/version.sh notes     print the CHANGELOG.md entry for the current version
#
# The version lives in the first file found of pubspec.yaml (x.y.z, +N optional),
# package.json ("version": "x.y.z"), or VERSION (x.y.z or x.y.z+N).
# Set VERSION_FILE to choose one explicitly, and VERSION_BASE_BRANCH to compare
# against a branch other than main.
set -euo pipefail

fail() { echo "::error::$1" >&2; exit 1; }

# Everything between the shebang and the first line of code, so a command added to
# the header cannot leave the help text describing an older set.
usage() {
  sed -n '2,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p; } }' "$0" >&2
  exit 2
}

version_file() {
  if [ -n "${VERSION_FILE:-}" ]; then echo "$VERSION_FILE"; return; fi
  for f in pubspec.yaml package.json VERSION; do
    if [ -f "$f" ]; then echo "$f"; return; fi
  done
  fail "no pubspec.yaml, package.json, or VERSION file found"
}

# Reads a version file's content on stdin and prints "x.y.z N".
# The build number is optional everywhere: `build` reports 0 when there is none.
parse() {
  case "$(basename "$1")" in
    pubspec.yaml) sed -nE 's/^version: *([0-9]+\.[0-9]+\.[0-9]+)(\+([0-9]+))?[[:space:]]*$/\1 \3/p' | head -n 1 ;;
    package.json) sed -nE 's/^[[:space:]]*"version": *"([0-9]+\.[0-9]+\.[0-9]+)".*$/\1 0/p' | head -n 1 ;;
    *) sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+)(\+([0-9]+))?[[:space:]]*$/\1 \3/p' | head -n 1 ;;
  esac
}

changelog_entry() {
  awk -v heading="## [$1] - " '
    index($0, heading) == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
    END { exit !found }
  ' CHANGELOG.md
}

# True when x.y.z $1 is above x.y.z $2.
above() {
  if [ "$1" = "$2" ]; then return 1; fi
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

base_branch=${VERSION_BASE_BRANCH:-main}
base_ref="refs/remotes/origin/$base_branch"

# Brings origin's base branch to $base_ref. Returns 1 when there is no baseline
# yet: no origin (before /kickoff creates the GitHub repo), or a trunk that was
# never pushed. Release tags are not used: nothing is published from CI, so there
# are none to compare with.
#
# An origin that is configured but unreachable is an error worth naming: a
# silent pass would skip the gate exactly when the network is the problem, and
# without this, set -e killed the script on the command substitution and
# printed git's raw "fatal:" with exit 128, so the ::error:: annotation this
# script exists to produce never appeared.
fetch_base_branch() {
  local heads status
  if ! git remote get-url origin > /dev/null 2>&1; then
    echo "No origin remote yet, so there is nothing to compare against." >&2
    return 1
  fi

  # Reachable and the branch exists? 0. Reachable and it doesn't (a repo whose
  # trunk was never pushed)? 2, and there is simply no baseline. Anything else
  # is the network, and has to be said out loud.
  status=0
  heads=$(git ls-remote --exit-code --heads origin "$base_branch" 2>&1) || status=$?
  case "$status" in
    0) ;;
    2) echo "origin has no $base_branch yet, so there is nothing to compare against." >&2
       return 1 ;;
    *) fail "can't reach origin to read $base_branch's version: $(printf '%s' "$heads" | head -n 1)" ;;
  esac

  if ! git rev-parse --verify --quiet "$base_ref" > /dev/null; then
    # --depth=1 is a property of the fetch, not of the refspec: run against a full
    # local clone it writes .git/shallow and truncates the repository, silently, so
    # a later `git log origin/main..HEAD` reads across the cut. CI is already shallow
    # (actions/checkout defaults to fetch-depth 1), which is the only case that wants it.
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
      git fetch --quiet --depth=1 origin "+refs/heads/$base_branch:$base_ref"
    else
      git fetch --quiet origin "+refs/heads/$base_branch:$base_ref"
    fi
  fi
}

# "x.y.z N" as committed at $1, or nothing when the version file is not there.
version_at() {
  { git show "$1:$file" 2>/dev/null || true; } | parse "$file"
}

# Whether this commit raised the version above the previous commit's: the merge
# build's question, asked on the trunk where there is no PR to gate. It needs the
# previous commit (fetch-depth 2 in CI) and no origin.
#
# A merge that leaves the version alone is a Dependabot PR, exempt from the gate
# by design, or a PR merged behind another that took the same version. It is not a
# release, and nothing a failed build could fix -- the trunk cannot raise its own
# version -- so it is a notice, never an error. The gate used to fail release.yml
# on every Dependabot merge.
release_of_this_commit() {
  local prev_name
  if ! git rev-parse --verify --quiet HEAD~1 > /dev/null; then
    echo "::warning::No previous commit to compare $name+$build with (the first commit, or a checkout without fetch-depth 2): taking it as a release." >&2
    return 0
  fi
  read -r prev_name _ <<< "$(version_at HEAD~1)" || true
  if [ -z "$prev_name" ]; then
    echo "::warning::The previous commit has no version in $file to compare $name+$build with: taking it as a release." >&2
    return 0
  fi
  if above "$name" "$prev_name"; then
    return 0
  fi
  echo "::notice::$base_branch is still on $prev_name after this commit, so it is not a release: a dependency bump, or a PR merged behind another. Its changes go out with the next version." >&2
  return 1
}

file=$(version_file)
read -r name build < <(parse "$file" < "$file") || true
[ -n "${name:-}" ] || fail "$file: the version must look like x.y.z (x.y.z+N where the stores need a build number)"
build=${build:-0}

case "${1:-}" in
  name) echo "$name" ;;
  build) echo "$build" ;;
  notes) changelog_entry "$name" || fail "CHANGELOG.md has no '## [$name] - ' entry" ;;
  released)
    if release_of_this_commit; then echo true; else echo false; fi
    ;;
  check)
    last_name=
    last_build=0
    # The remote checks run in the current shell, not a `$(...)` or `< <(...)`,
    # so `fail` inside them ends the script: a process substitution runs in a
    # subshell whose exit status the script never sees, so the annotation would
    # print and then be ignored.
    if fetch_base_branch; then
      if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$base_ref")" ]; then
        # HEAD is the base branch itself: the merge build. There is no PR to gate
        # and nothing to refuse, so say whether this commit is a release and stop.
        echo "HEAD is $base_branch itself, so there is no PR to gate." >&2
        if release_of_this_commit; then
          echo "Releasing $name+$build."
        else
          echo "Not a release: this commit left $base_branch on $name."
        fi
        exit 0
      fi
      read -r last_name last_build <<< "$(version_at "$base_ref")" || true
      last_build=${last_build:-0}
    fi

    if [ -n "$last_name" ]; then
      if ! above "$name" "$last_name"; then
        fail "$base_branch was already on $last_name: raise the version above it (major, minor, or patch)"
      fi
      if [ "$build" != 0 ] && [ "$build" -le "$last_build" ]; then
        fail "$base_branch was already on build $last_build: raise the build number above it"
      fi
    fi
    changelog_entry "$name" > /dev/null || fail "CHANGELOG.md needs a '## [$name] - YYYY-MM-DD' entry"
    echo "Releasing $name+$build (was ${last_name:-nothing yet})."
    ;;
  *) usage ;;
esac
