#!/usr/bin/env bash
# GitHub Pages publishes every file in docs/. The roadmap, the product rules, the
# release runbook and the competitor research are working documents, and the domain
# they would be served on is the one in the store listing. docs/_config.yml decides
# what is published; this fails when a file there is neither excluded nor declared
# public, so adding a doc cannot quietly put it on the internet.
#
#   bash scripts/check_public_docs.sh
set -euo pipefail

config=${1:-docs/_config.yml}
[ -f "$config" ] || { echo "::error::$config is missing, so every file in docs/ would be published."; exit 1; }

docs=$(dirname "$config")
# The two lists out of the YAML, without needing a YAML parser: entries are
# "  - name" under each key, up to the next unindented line.
listed() { sed -n "/^$1:/,/^[^ -]/{ s/^  *- *//p; }" "$config"; }

# `|| true`: with both lists empty grep selects nothing and exits 1, and under
# set -e that ended the script right here -- exit 1, but silently, with no
# ::error:: line to say what was wrong.
known=$(printf '%s\n%s\n' "$(listed exclude)" "$(listed public)" | grep -v '^[[:space:]]*$' | sort -u || true)

missing=""
while IFS= read -r entry; do
  name=${entry#"$docs"/}
  case "$name" in _config.yml | '') continue ;; esac
  printf '%s\n' "$known" | grep -qxF "$name" || missing="$missing $name"
done < <(find "$docs" -mindepth 1 -maxdepth 1 | sort)

if [ -n "$missing" ]; then
  echo "::error::$docs has entries $config does not account for:$missing. Add each to 'exclude' (working document) or to 'public' (meant to be served at the store's privacy-policy domain)."
  exit 1
fi
echo "Every entry in $docs is accounted for: $(listed public | tr '\n' ' ')published, the rest excluded."
