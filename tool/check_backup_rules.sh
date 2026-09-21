#!/usr/bin/env bash
# CAP-24: automatic cloud backup and device-to-device transfer are the only way
# captured messages can leave the phone without the internet permission, and
# RUN-2's permissions gate cannot see them -- it reads `uses-permission` lines and
# capture declares none (CAP-20). So CAP-24 asks for this check by name: the
# release workflow checks the built manifest the way it checks permissions, and
# fails on a change.
#
# It reads the BUILT manifest out of the release APK, never
# android/app/src/main/AndroidManifest.xml. The source file is not what ships: the
# manifest merger folds in every library's manifest, and a plugin whose manifest
# says android:allowBackup="true" wins over the app's node unless that node
# carries tools:replace. That merge is the whole reason this gate exists, so
# reading the source would check the one copy that cannot regress.
#
#   aapt2 dump xmltree build/app/outputs/flutter-apk/app-release.apk \
#     --file AndroidManifest.xml > manifest.txt
#   bash tool/check_backup_rules.sh manifest.txt
#
# What it does not cover: whether @xml/data_extraction_rules still excludes the
# `database` and `file` domains. The manifest only names the resource, so this
# gate can say the pointer is intact and no more -- emptying that file would pass
# here. Nothing checks it today; CAP-24's other half lives in review.
set -euo pipefail

dump=${1:-}
[ -n "$dump" ] && [ -f "$dump" ] || { echo "::error::usage: check_backup_rules.sh <aapt2-xmltree-dump>" >&2; exit 2; }

# Dumped on Windows by hand as often as on the runner, and a trailing CR would
# make the literal `false` this gate is looking for never match.
tree=$(tr -d '\r' < "$dump")

printf '%s\n' "$tree" | grep -qE '^[[:space:]]*E: application[[:space:]]*\(' || {
  echo "::error::No <application> element in $dump (CAP-24): this is not an \`aapt2 dump xmltree <apk> --file AndroidManifest.xml\` dump, so nothing was checked." >&2
  exit 2
}

# aapt2 prints an element's own attributes before its children, so <application>'s
# attributes are the A: lines between `E: application` and the next E:. Grepping
# the whole file instead would let an <activity>'s android:allowBackup -- which
# Android ignores, because backup is an application-level setting -- answer for
# the application's and turn this gate green on a manifest that backs up.
app_attrs=$(printf '%s\n' "$tree" | awk '
  /^[[:space:]]*E: application[[:space:]]*\(/ { in_app = 1; next }
  in_app && /^[[:space:]]*E: / { exit }
  in_app && /^[[:space:]]*A: / { print }
')

# The raw value of one android: attribute on <application>, empty if absent. The
# resource id in parentheses is optional: aapt2 omits it for an attribute the
# platform it linked against does not know.
attr() {
  # % delimits the substitution because the attribute name is a URL: a / here
  # would end the expression halfway through http://schemas.android.com/.
  local pattern="^[[:space:]]*A: http://schemas\.android\.com/apk/res/android:$1(\(0x[0-9a-fA-F]+\))?="
  printf '%s\n' "$app_attrs" | sed -nE "s%$pattern%%p" | sed -n '1p'
}

# aapt2 prints a compiled boolean as `false`/`true` (build-tools 36) or as
# `(type 0x12)0x0` / `(type 0x12)0xffffffff` (older ones), and a resource
# reference as `@0x7f010000`. Everything else is `other` on purpose: a bool
# *resource* reading android:allowBackup="@bool/allow_backup" is a value a
# flavour or a library overlay can flip after this gate has looked at it, so it
# is not accepted as false however it resolves today.
kind() {
  case "$1" in
    'false' | '(type 0x12)0x0') echo false ;;
    'true' | '(type 0x12)0xffffffff') echo true ;;
    '@0x00000000') echo absent ;;
    '@'*) echo resource ;;
    '') echo absent ;;
    *) echo other ;;
  esac
}

status=0

require_false() {
  local name=$1 value=$2
  case "$(kind "$value")" in
    false) return 0 ;;
    absent)
      echo "::error::The built manifest's <application> carries no android:$name (CAP-24). Android's default is to back the app up, so the message database and the native queue would be copied to the user's Google Drive and to the next device. Restore android:$name=\"false\" in android/app/src/main/AndroidManifest.xml; if a merged library manifest is what dropped it, pin the app's node with tools:replace=\"android:$name\"."
      ;;
    *)
      echo "::error::The built manifest sets android:$name=$value, and CAP-24 requires the literal false. Captured messages would leave the phone by backup, which is the one path RUN-2's permissions gate cannot see (CAP-20). Find what merged it in -- build/app/outputs/logs/manifest-merger-release-report.txt names the library -- then drop that library or pin the app's node with tools:replace=\"android:$name\"."
      ;;
  esac
  status=1
}

allow_backup=$(attr allowBackup)
full_backup=$(attr fullBackupContent)
extraction=$(attr dataExtractionRules)

require_false allowBackup "$allow_backup"
require_false fullBackupContent "$full_backup"

# Checked separately: this one is meant to be a reference, and the two ways it
# goes wrong are being dropped and being turned into a literal. On API 31+ it is
# what the system reads, so a manifest with allowBackup="false" and no extraction
# rules is still a device-to-device transfer waiting to happen.
case "$(kind "$extraction")" in
  resource) ;;
  absent)
    echo "::error::The built manifest's <application> points android:dataExtractionRules at nothing (CAP-24). From API 31 that is the file the system reads, so cloud backup and device-to-device transfer fall back to copying everything. Point it at @xml/data_extraction_rules in android/app/src/main/AndroidManifest.xml."
    status=1
    ;;
  *)
    echo "::error::The built manifest sets android:dataExtractionRules=$extraction, which is not a resource reference (CAP-24). It has to name the XML that excludes the database and file domains, not a literal."
    status=1
    ;;
esac

[ "$status" -eq 0 ] && echo "Backup is off in the built manifest (CAP-24): allowBackup=$allow_backup, fullBackupContent=$full_backup, dataExtractionRules=$extraction."
exit "$status"
