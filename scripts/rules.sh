#!/usr/bin/env bash
# The rule IDs in docs/PRODUCT_RULES.md are the spine of the method: tests, code
# comments, PRs and roadmap items cite them. Nothing checked them, so both errors
# were invisible -- a rule nobody ever built, and a citation to an ID that does not
# exist because it was mistyped or renumbered. PRODUCT_RULES.md is then treated as
# settled behaviour when filling in the store's data-safety form.
#
#   bash scripts/rules.sh          list uncited rules; fail on a citation to no rule
#   bash scripts/rules.sh <ID>     show where one rule is cited
set -euo pipefail

rules=${RULES_FILE:-docs/PRODUCT_RULES.md}
[ -f "$rules" ] || { echo "::error::$rules is missing."; exit 1; }

# A definition is a rule's own bullet: "- **ABC-1** The rule."
defined=$(grep -oE '^- \*\*[A-Z]{2,6}-[0-9]+\*\*' "$rules" | sed 's/^- \*\*//; s/\*\*$//' | sort -u)
[ -n "$defined" ] || { echo "::error::$rules defines no rules in the form '- **ABC-1** ...'."; exit 1; }

# Only prefixes that name a real area count as citations, so UTF-8 and SHA-256 are
# not mistaken for rule IDs.
prefixes=$(printf '%s\n' "$defined" | sed 's/-[0-9]*$//' | sort -u | paste -sd'|' -)
idPattern="\b($prefixes)-[0-9]+\b"

# Tracked files only: never build output, dependencies or store material. This file
# is left out of its own scan: the examples in these comments are not citations.
self=${BASH_SOURCE[0]#./}
tracked() { git ls-files -z | grep -zv -- "$self" || true; }

mentions() {
  tracked | xargs -0 grep -hoEI "$idPattern" -- 2>/dev/null || true
}

# The roadmap cites a whole area as a range, "ADS-1–ADS-9". Counting only the two
# ends would report the seven rules between them as cited by nobody, and a report
# that is mostly noise on day one is one nobody reads. An en or em dash only: a
# plain hyphen cannot be told apart from the one inside an ID.
# The dashes are alternated rather than bracketed: outside a UTF-8 locale a bracket
# expression matches single bytes, and an en dash is three of them.
ranges() {
  tracked \
    | xargs -0 grep -hoEI "($prefixes)-[0-9]+(–|—)($prefixes)-[0-9]+" -- 2>/dev/null \
    | sed -e 's/–/ /' -e 's/—/ /' \
    | awk '{
        split($1, from, "-"); split($2, to, "-")
        if (from[1] == to[1]) for (n = from[2]; n <= to[2]; n++) print from[1] "-" n
      }' || true
}

if [ $# -gt 0 ]; then
  git ls-files -z | xargs -0 grep -nEI "\b$1\b" -- 2>/dev/null || echo "$1 is cited nowhere."
  exit 0
fi

cited=$(mentions | sort -u)
# Every rule is mentioned at least once, by its own definition, so "cited" means
# mentioned more than once. A range counts for every rule it covers.
cited_elsewhere=$(printf '%s\n%s\n' "$(mentions)" "$(ranges)" \
  | grep -v '^[[:space:]]*$' | sort | uniq -c | awk '{ print $2, $1 }' || true)

unknown=$(comm -13 <(printf '%s\n' "$defined") <(printf '%s\n' "$cited") || true)
uncited=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  # Every rule appears at least once: in its own definition. More than once means
  # something else refers to it.
  count=$(printf '%s\n' "$cited_elsewhere" | awk -v id="$id" '$1 == id { print $2 }')
  if [ "${count:-0}" -le 1 ]; then uncited="$uncited $id"; fi
done <<< "$defined"

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
{
  echo "### Product rules"
  echo ""
  echo "$(printf '%s\n' "$defined" | grep -c .) defined in \`$rules\`."
} >> "$summary"

if [ -n "$uncited" ]; then
  echo "Defined but cited nowhere else:$uncited"
  { echo ""; echo "Cited nowhere else:$uncited"; } >> "$summary"
  echo "Each is either not built yet, or built without saying which rule it implements."
fi

if [ -n "$unknown" ]; then
  # This one is always a mistake: a typo, or an ID that was renumbered against the
  # file's own rule that IDs are stable.
  echo "::error::Cited but not defined in $rules: $(echo $unknown). A rule ID is stable once written, so this is a typo or a renumbering."
  { echo ""; echo "**Cited but not defined:** $(echo $unknown)"; } >> "$summary"
  exit 1
fi

[ -n "$uncited" ] || echo "Every rule in $rules is cited somewhere else."
