#!/usr/bin/env bash
# RUN-2: the release build declares no permission a shipped feature doesn't need,
# so the store's data-safety answers stay true. Plugins add permissions silently,
# so this compares what the built artifact actually declares against the list the
# release workflow allows -- in both directions, because a permission the app needs
# and lost is as much a bug as one it gained.
#
#   ALLOWED='android.permission.POST_NOTIFICATIONS' PACKAGE_NAME=com.example.app \
#     bash tool/check_permissions.sh permissions.txt
#
# permissions.txt is the output of `aapt2 dump permissions <apk>`. An empty ALLOWED
# means "declares no permissions at all", never "allow anything".
set -euo pipefail

dump=${1:-}
[ -n "$dump" ] && [ -f "$dump" ] || { echo "::error::usage: check_permissions.sh <aapt2-permissions-dump>" >&2; exit 2; }

allowed=$(mktemp)
declared=$(mktemp)
trap 'rm -f "$allowed" "$declared"' EXIT

# Unquoted on purpose: ALLOWED is a space-separated list.
# shellcheck disable=SC2086
printf '%s\n' ${ALLOWED:-} | grep -v '^[[:space:]]*$' | sort -u > "$allowed" || true

# The app's own permissions (<package>.SOMETHING) are generated, not declared by us.
sed -nE "s/^uses-permission(-sdk-23)?: name='([^']+)'.*/\2/p" "$dump" \
  | { [ -n "${PACKAGE_NAME:-}" ] && grep -v "^${PACKAGE_NAME}\." || cat; } \
  | grep -v '^[[:space:]]*$' | sort -u > "$declared" || true

unexpected=$(grep -vxF -f "$allowed" "$declared" || true)
missing=$(grep -vxF -f "$declared" "$allowed" || true)

status=0
if [ -n "$unexpected" ]; then
  echo "::error::The release build declares permissions outside the allowed list (RUN-2): $(echo $unexpected). If a shipped feature needs one, add it to ALLOWED in release.yml and update docs/privacy-policy.md in the same PR."
  status=1
fi
if [ -n "$missing" ]; then
  echo "::error::The allowed list names permissions the release build no longer declares (RUN-2): $(echo $missing). Remove them from ALLOWED, or find out which change dropped them."
  status=1
fi
[ "$status" -eq 0 ] && echo "Permissions match the allowed list ($(wc -l < "$declared" | tr -d ' ') declared)."
exit "$status"
