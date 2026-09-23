#!/usr/bin/env bash
# INB-16, INB-13: the release workflow checks the built manifest's `<queries>`
# against lib/data/shipped_apps.dart the way CAP-24's gate checks allowBackup.
#
# What this protects is a sentence on screen and a control under it, and since the
# developer's decision of 22 September 2026 the declaration has two halves that
# fail in opposite directions.
#
#   1. The MAIN + LAUNCHER intent filter. It is what makes every launchable app
#      visible, which is what lets INB-13's `Open <app>` resolve and INB-16 tell
#      installed from gone for an app that joined the inbox by posting (INB-20).
#      Lost in a merge, nothing fails: `getApplicationInfo` goes back to throwing
#      NameNotFound for those packages, and `PackageManager` throws exactly the
#      same NameNotFoundException for "there is no such app" and for "package
#      visibility hides it from you" -- so every conversation from every app that
#      is not one of the six grows a `sourceAppGone` line about an app sitting on
#      the user's home screen, and loses its launch control. That is the one
#      sentence INB-16 does not allow to be guessed, said about nearly everything.
#
#   2. The six `<package>` entries. Same failure, narrowed to the apps captured by
#      default (CAP-1) -- and they carry one thing the filter cannot: they are
#      visible whatever shape the app is in, and PERM-3's disclosure resolves
#      their labels before any of them has posted.
#
# The other direction matters too, and more than it used to. The declaration is
# now the whole of what Android lets this app see, so a dependency that adds a
# third `<intent>` or a `<provider>` widens that quietly, and the privacy policy's
# claim (CAP-27) would stop being true with nothing failing. So the intent actions
# inside `<queries>` are checked against an exact list, not merely scanned for the
# two that should be there.
#
# What this gate does NOT check, because it cannot: that the app only ever *asks*
# about a package that has already sent the user a notification. Visibility is
# what Android grants and asking is what the app chooses, and the choosing lives
# in SourceAppInfo.mayAsk with SourceAppInfoTest and AppLaunchTest on it.
#
# It reads the BUILT manifest out of the release APK, never
# android/app/src/main/AndroidManifest.xml, for CAP-24's reason: the merger folds
# in every library's manifest and a plugin can add, and in principle remove,
# elements the source file still shows. test/shipped_apps_test.dart and
# QueriesDeclarationTest cover the source copies; this covers the one that ships.
#
#   aapt2 dump xmltree build/app/outputs/flutter-apk/app-release.apk \
#     --file AndroidManifest.xml > manifest.txt
#   bash tool/check_queries.sh manifest.txt [lib/data/shipped_apps.dart]
set -euo pipefail

dump=${1:-}
shipped=${2:-lib/data/shipped_apps.dart}
[ -n "$dump" ] && [ -f "$dump" ] || { echo "::error::usage: check_queries.sh <aapt2-xmltree-dump> [shipped_apps.dart]" >&2; exit 2; }
[ -f "$shipped" ] || { echo "::error::No $shipped to check the manifest against (INB-16)." >&2; exit 2; }

# Dumped on Windows by hand as often as on the runner, and a trailing CR would put
# one invisible character on the end of every package name and fail every
# comparison below for the wrong reason.
tree=$(tr -d '\r' < "$dump")

printf '%s\n' "$tree" | grep -qE '^[[:space:]]*E: manifest[[:space:]]*\(' || {
  echo "::error::No <manifest> element in $dump (INB-16): this is not an \`aapt2 dump xmltree <apk> --file AndroidManifest.xml\` dump, so nothing was checked." >&2
  exit 2
}

declared=$(mktemp)
expected=$(mktemp)
actions=$(mktemp)
categories=$(mktemp)
others=$(mktemp)
trap 'rm -f "$declared" "$expected" "$actions" "$categories" "$others"' EXIT

# One pass over the tree, scoped by indentation rather than grepped for out of the
# whole file: aapt2 indents two spaces per level, and a `<package>` anywhere else
# in the manifest -- or, more to the point, a shipped package name appearing as
# some other element's attribute -- would otherwise answer for the declaration and
# turn this gate green on a manifest that declares nothing. Each line it prints is
# tagged with what it came from, so the four questions below read one file each.
#
# `element` names any child element of <queries> other than <intent> and
# <package>: `<provider>` is the third visibility mechanism and would be as much a
# widening as an extra intent, and anything new Android adds lands here too rather
# than passing unseen.
scan=$(printf '%s\n' "$tree" | awk '
  {
    line = $0
    match(line, /^ */)
    indent = RLENGTH
    if (line ~ /^ *E: /) {
      # Nesting is read from the indent alone, and never from a fixed step:
      # aapt2 36 indents an element four spaces under its parent and an
      # attribute two under its element, and a gate that assumed one number
      # would silently find nothing on the next build-tools release and pass.
      if (in_queries && indent <= queries_indent) { in_queries = 0; in_package = 0; in_intent = 0; kind = "" }
      if (line ~ /^ *E: queries[ \t]*\(/) { in_queries = 1; queries_indent = indent; kind = ""; next }
      if (!in_queries) { kind = ""; next }
      if (in_package && indent <= package_indent) in_package = 0
      if (in_intent && indent <= intent_indent) in_intent = 0
      if (!in_package && !in_intent) {
        if (line ~ /^ *E: package[ \t]*\(/) { in_package = 1; package_indent = indent; kind = "package"; next }
        if (line ~ /^ *E: intent[ \t]*\(/) { in_intent = 1; intent_indent = indent; kind = ""; next }
        name = line
        sub(/^ *E: /, "", name)
        sub(/[ \t]*\(.*$/, "", name)
        print "element\t" name
        kind = ""
        next
      }
      if (in_intent && line ~ /^ *E: action[ \t]*\(/) { kind = "action"; next }
      if (in_intent && line ~ /^ *E: category[ \t]*\(/) { kind = "category"; next }
      kind = ""
      next
    }
    if (line ~ /^ *A: / && kind != "") {
      if (kind == "package" && !(in_package && indent > package_indent)) next
      print kind "\t" line
    }
  }
')

value() {
  printf '%s\n' "$scan" \
    | sed -nE "s/^$1\t//p" \
    | sed -nE 's%^.*schemas\.android\.com/apk/res/android:name(\(0x[0-9a-fA-F]+\))?="([^"]*)".*%\2%p' \
    | grep -v '^[[:space:]]*$' | sort -u
}

value package > "$declared" || true
value action > "$actions" || true
value category > "$categories" || true
printf '%s\n' "$scan" | sed -nE 's/^element\t//p' | grep -v '^[[:space:]]*$' | sort -u > "$others" || true

# The packages in lib/data/shipped_apps.dart, read from the list itself rather
# than from the whole file, so a package name written in a comment above it
# cannot stand in for one that was actually removed from the constant.
sed -nE "/const List<String> shippedMessagingApps/,/^\];/p" "$shipped" \
  | sed -nE "s/^[[:space:]]*'([^']+)'.*/\1/p" \
  | grep -v '^[[:space:]]*$' | sort -u > "$expected" || true

# A gate that checked an empty list against an empty list would pass on a build
# with no <queries> at all, which is the failure it exists to catch.
[ -s "$expected" ] || {
  echo "::error::No packages parsed out of $shipped (INB-16). The constant was renamed or reshaped, so this gate checked nothing. Fix the parser rather than leaving it comparing two empty lists." >&2
  exit 2
}

missing=$(grep -vxF -f "$declared" "$expected" || true)
extra=$(grep -vxF -f "$expected" "$declared" || true)

# The two intent filters the app declares, and nothing else. PROCESS_TEXT is the
# Flutter engine's (io.flutter.plugin.text.ProcessTextPlugin); MAIN + LAUNCHER is
# INB-13's.
allowed_actions=$'android.intent.action.MAIN\nandroid.intent.action.PROCESS_TEXT'
allowed_categories='android.intent.category.LAUNCHER'

status=0
if [ -n "$missing" ]; then
  echo "::error::The built manifest's <queries> does not declare shipped packages (INB-16): $(echo $missing). The app captures from them by default (CAP-1) but cannot resolve their label or icon before they first post (PERM-3), and worse, PackageManager answers NameNotFound for a package it cannot see -- so a conversation from these apps would be shown as uninstalled while the app is still on the phone. Restore them in android/app/src/main/AndroidManifest.xml; if the manifest merge dropped them, build/app/outputs/logs/manifest-merger-release-report.txt names what merged."
  status=1
fi
if [ -n "$extra" ]; then
  echo "::error::The built manifest's <queries> names packages the shipped list does not (INB-16, INB-20): $(echo $extra). A <package> entry declares a package by name, which is a claim the disclosure has to match (PERM-3): if a dependency added it, drop the dependency, and if it is ours, add it to lib/data/shipped_apps.dart, ShippedApps.kt and PERM-3's disclosure in the same PR."
  status=1
fi

if ! grep -qxF 'android.intent.action.MAIN' "$actions" || ! grep -qxF 'android.intent.category.LAUNCHER' "$categories"; then
  echo "::error::The built manifest's <queries> has lost the MAIN + LAUNCHER intent filter (INB-13, INB-16, developer decision 22 September 2026). Without it every package outside the six above is invisible again: INB-13's \`Open <app>\` resolves nothing, and every conversation from an app that joined by posting (INB-20) is reported uninstalled -- the one sentence INB-16 forbids the app to guess. Restore the <intent> in android/app/src/main/AndroidManifest.xml; if the merge dropped it, build/app/outputs/logs/manifest-merger-release-report.txt names what merged."
  status=1
fi

if ! grep -qxF 'android.intent.action.PROCESS_TEXT' "$actions"; then
  echo "::error::The built manifest's <queries> has lost the PROCESS_TEXT intent the Flutter engine needs (io.flutter.plugin.text.ProcessTextPlugin). Text selection in the app breaks and nothing else reports it."
  status=1
fi

unexpected_actions=$(grep -vxF -f <(printf '%s\n' "$allowed_actions") "$actions" || true)
unexpected_categories=$(grep -vxF "$allowed_categories" "$categories" || true)
if [ -n "$unexpected_actions" ] || [ -n "$unexpected_categories" ]; then
  echo "::error::The built manifest's <queries> declares an intent filter nobody asked for (INB-20, CAP-27): $(echo $unexpected_actions $unexpected_categories). The declaration is the whole of what Android lets this app see, and docs/privacy-policy.md describes it; a filter added by a dependency widens that with nothing on screen or in the policy saying so. Find what merged it and remove it, or state it in the policy and add it here in the same PR."
  status=1
fi

if [ -s "$others" ]; then
  echo "::error::The built manifest's <queries> holds an element that is neither <intent> nor <package> (INB-20, CAP-27): $(tr '\n' ' ' < "$others"). <provider> is package visibility by another route and anything else here is one nobody has reviewed. Same treatment as an unexpected intent filter: find what merged it, or state it in docs/privacy-policy.md and add it here."
  status=1
fi

# INB-20: the app never enumerates installed packages. With QUERY_ALL_PACKAGES
# granted, every package is visible, INB-16's third state could never honestly be
# reached, and SourceAppInfo.mayAsk's refusal to ask about a package that has
# never posted would be the only thing left between the app and the phone's app
# list -- with the manifest no longer backing it up. RUN-2's gate would also catch
# this today, with an empty ALLOWED; it will not once PERM-15's POST_NOTIFICATIONS
# is added and that list stops being empty, and this is the gate that knows why it
# matters.
if printf '%s\n' "$tree" | grep -qF 'android.permission.QUERY_ALL_PACKAGES'; then
  echo "::error::The built manifest names QUERY_ALL_PACKAGES (INB-20, CAP-20). The app never enumerates installed packages: it declares what it can see in <queries> and asks only about apps that have messaged the user. Find what added it -- build/app/outputs/logs/manifest-merger-release-report.txt names the library -- and remove it."
  status=1
fi

[ "$status" -eq 0 ] && echo "The built manifest's <queries> declares the shipped list, the launcher filter and nothing else (INB-13, INB-16): $(tr '\n' ' ' < "$declared")+ $(tr '\n' ' ' < "$actions")"
exit "$status"
