#!/usr/bin/env bash
# PERM-16: the three claims the disclosure makes — what is read, that it includes
# apps the user never named, and that nothing leaves the phone — "exist once, as
# PERM-2's and PERM-3's message IDs, and the policy quotes them; a script
# compares the two files". This is that script.
#
# Why a gate and not a convention. Those three sentences are on four surfaces:
# the disclosure screen a user reads before granting notification access
# (PERM-2, PERM-3), the app's own policy page (PERM-16, which draws the very
# same getters rather than a second wording), docs/privacy-policy.md, and the
# store listing and data-safety answers written from it by hand
# (docs/RELEASING.md). The first two cannot drift from each other — they are one
# string, and that is the whole design. The third can, silently, and it is the
# one strangers and Play read. The failure it would produce is the worst kind
# this project has: the app telling a user one story on the permission screen
# and the published policy telling them another, with nothing red anywhere.
#
# What it checks, and what it deliberately does not. It compares the English
# source (`lib/l10n/app_en.arb`, the one file a human writes — LANG-6's other
# languages are translated from it and are checked by their own tooling)
# character for character against the quoted lines in the policy. It does NOT
# check that the surrounding prose still makes sense, that the claims are true,
# or that the policy covers what the app stores. Those are the reading CAP-27
# and PERM-16 ask a person to do before the merge; this catches only the one
# thing a person reliably misses, which is a sentence edited on one side.
#
# Shape follows tool/check_queries.sh (one pass, then a question per failure,
# each with a ::error:: line saying what to do about it) and lives in scripts/
# beside check_public_docs.sh, which is the other gate over docs/ rather than
# over a built artifact. ci.yml runs the two in the same step on purpose: the
# branch protection ruleset requires exactly two check names, and a third job
# would leave this one ungated.
#
#   bash scripts/check_policy_claims.sh [docs/privacy-policy.md] [lib/l10n/app_en.arb]
set -euo pipefail

policy=${1:-docs/privacy-policy.md}
arb=${2:-lib/l10n/app_en.arb}

[ -f "$policy" ] || { echo "::error::$policy is missing, and PERM-16 makes it a merge condition for this area." >&2; exit 2; }
[ -f "$arb" ] || { echo "::error::$arb is missing, so there is nothing to compare $policy against (PERM-16)." >&2; exit 2; }

# The three IDs PERM-16 names, in the order the policy quotes them. Adding a
# fourth here is how a fourth shared claim joins; the policy then has to carry
# its marker or this fails, which is the direction we want that to break in.
claims='permissionsDisclosureReads permissionsDisclosureAppsExplainer permissionsDisclosureStaysHere'

# Edited on Windows as often as on the runner. A trailing CR would put one
# invisible character on the end of every quoted line and fail all three
# comparisons for a reason nobody could see in the diff.
policy_text=$(tr -d '\r' < "$policy")
arb_text=$(tr -d '\r' < "$arb")

# The ARB is JSON, and this reads one line of it rather than parsing it: every
# message in the file is written as `  "id": "…"` on a single line by
# tool/add_messages.dart, and a dependency on a JSON parser in a bash gate that
# runs before `flutter pub get` would be a worse trade. The two-space indent and
# the closing quote are both part of the match, so `"@id": {` metadata and a
# description that happens to contain the id cannot answer for the message.
arb_value() {
  printf '%s\n' "$arb_text" | sed -nE "s/^  \"$1\": \"(.*)\",?$/\1/p"
}

# The policy marks each quote with `<!-- claim: <id> -->`, and the quote is the
# first non-blank line after it, a Markdown blockquote. A blank line between the
# two is required rather than tolerated: kramdown (GitHub Pages) parses an HTML
# comment as a block element and would swallow a `>` line that followed it
# immediately, so the published page would silently lose the quote while this
# gate still found it.
policy_value() {
  printf '%s\n' "$policy_text" | awk -v id="$1" '
    $0 == "<!-- claim: " id " -->" { looking = 1; next }
    looking && $0 ~ /^[[:space:]]*$/ { next }
    looking { print; exit }
  '
}

# Which file moved last, where git can say. On a full clone this turns "these
# two disagree" into "the app was edited on Tuesday and the page was not", which
# is the difference between a useful error and a puzzle. On a shallow CI clone
# both files report the same single commit, so the answer is "cannot tell" and
# the failure says both halves instead of guessing — the same refusal PERM-9
# makes about a time it does not hold.
touched() { git log -1 --format=%ct -- "$1" 2>/dev/null || true; }
arb_touched=$(touched "$arb")
policy_touched=$(touched "$policy")

direction() {
  if [ -n "$arb_touched" ] && [ -n "$policy_touched" ] && [ "$arb_touched" != "$policy_touched" ]; then
    if [ "$arb_touched" -gt "$policy_touched" ]; then
      printf '%s' "The app's wording moved last ($arb was committed after $policy), so the likely fix is to paste the app's sentence into $policy exactly as it is above."
    else
      printf '%s' "The page moved last ($policy was committed after $arb), so either the edit belongs in the app — change the message in every language (LANG-6) rather than in $policy — or the quote should go back to what the app says."
    fi
  else
    printf '%s' "Which of the two is right is not something this gate can know. If the app's sentence is the one you meant, paste it into $policy unchanged; if the page's is, change the message in every language (LANG-6) so the disclosure and the app's own policy page change with it."
  fi
}

status=0
checked=0

for id in $claims; do
  value=$(arb_value "$id")
  found=$(printf '%s\n' "$value" | grep -c . || true)

  if [ "$found" -eq 0 ]; then
    echo "::error::$arb has no message \`$id\`, but $policy quotes it as one of PERM-16's three shared claims. Drift towards the app: a claim the policy makes that no screen in the app makes any more. Restore the message, or — if the claim really is gone — remove its quote and its \`<!-- claim: $id -->\` marker from $policy and from the \`claims\` list in this script, in the same PR." >&2
    status=1
    continue
  fi
  if [ "$found" -gt 1 ]; then
    echo "::error::$arb defines \`$id\` $found times, so this gate cannot tell which one the app shows. Remove the duplicate before trusting anything else here." >&2
    status=1
    continue
  fi

  # JSON escapes, handled for the two that can appear in a message with no
  # placeholders and refused for the rest. A gate that silently compared `\n`
  # against the two characters backslash-n would report drift that is not there,
  # and one that ignored the escape entirely would miss drift that is; saying so
  # and stopping is the only honest third option.
  case $value in
    *'\n'* | *'\t'* | *'\u'* | *'\/'*)
      echo "::error::\`$id\` in $arb carries a JSON escape this gate cannot unescape, so it compared nothing. Teach the unescape below \`arb_value\` before merging — a quoted claim nobody is checking is the state PERM-16 exists to prevent." >&2
      status=1
      continue
      ;;
  esac
  value=${value//\\\"/\"}
  value=${value//\\\\/\\}

  quoted=$(policy_value "$id")
  if [ -z "$quoted" ]; then
    echo "::error::$policy has no \`<!-- claim: $id -->\` marker with a quoted line under it. PERM-16 requires the policy to quote this claim rather than retell it, and the marker is what makes that checkable. Add the marker, a blank line, then the app's sentence as a Markdown blockquote: \`> $value\`" >&2
    status=1
    continue
  fi
  case $quoted in
    '> '*) ;;
    *)
      echo "::error::The line after \`<!-- claim: $id -->\` in $policy is not a Markdown blockquote: \`$quoted\`. It must be the app's sentence prefixed with \`> \`, so the page shows it as a quotation and this gate can find its end." >&2
      status=1
      continue
      ;;
  esac
  quoted=${quoted#> }

  if [ "$quoted" != "$value" ]; then
    echo "::error::PERM-16's claim \`$id\` has drifted between the app and the published policy." >&2
    echo "::error::  $arb says:    $value" >&2
    echo "::error::  $policy says: $quoted" >&2
    echo "::error::  $(direction)" >&2
    status=1
    continue
  fi

  checked=$((checked + 1))
done

# A marker in the policy for an ID this script does not know is a fourth claim
# that looks checked and is not, which is worse than an unquoted one.
while IFS= read -r marker; do
  [ -n "$marker" ] || continue
  printf '%s\n' "$claims" | tr ' ' '\n' | grep -qxF "$marker" || {
    echo "::error::$policy carries a \`<!-- claim: $marker -->\` marker that this gate does not check, so that quote is drifting unwatched. Add \`$marker\` to the \`claims\` list in scripts/check_policy_claims.sh, or drop the marker and quote nothing." >&2
    status=1
  }
done < <(printf '%s\n' "$policy_text" | sed -nE 's/^<!-- claim: ([A-Za-z0-9_]+) -->$/\1/p')

[ "$status" -eq 0 ] && echo "$policy quotes all $checked of PERM-16's shared claims exactly as $arb states them: $(echo $claims)."
exit "$status"
