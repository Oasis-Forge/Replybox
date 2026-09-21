#!/usr/bin/env bash
# Drives the app on the Android emulator with text instead of screenshots:
# `screen` lists what is showing, `tap` presses an element by its label.
#
#   bash tool/emu.sh <command> [args]
#
#   start              run the emulator (as a background command: it lasts as
#                      long as the emulator does). EMU_ARGS passes flags through,
#                      e.g. EMU_ARGS=-no-snapshot-load to cold-boot a wedged one;
#                      AVD picks a device other than Medium_Phone
#   stop               shut the emulator down
#   ready              wait until it has booted
#   save <name>        snapshot the whole emulator: data, language, theme,
#                      dark mode, Downloads
#   load <name>        go back to a snapshot
#   snapshots          list snapshots
#   forget <name>      delete a snapshot
#   install <apk>      install over the app, keeping its data
#   launch             restart the app
#   app                print the application id `launch` uses: APP_ID if set,
#                      else the Android build file's applicationId
#   screen             one line per element: label @ x,y (flags)
#   tap <label> [n]    tap the nth element (default 1st) labelled <label>
#                      exactly, or else containing it, ignoring case
#   hold <label> [n]   long-press it the same way
#   tapxy <x> <y>      tap a point, in device pixels as `screen` prints them
#   type <text>        type ASCII text into the focused field
#   key <name>         press a key: back, enter, del, tab, home
#   scroll <up|down>   swipe the middle of the screen
#   push <file>        copy a file into Downloads, for the file picker
#   shot <file.png>    save a screenshot, for when the look matters
set -euo pipefail
export MSYS_NO_PATHCONV=1 # stops Git Bash rewriting /sdcard into a Windows path

sdk=${ANDROID_HOME:-${LOCALAPPDATA:-$HOME}/Android/Sdk}
if command -v cygpath >/dev/null; then sdk=$(cygpath -u "$sdk"); fi

# Everything between the shebang and the first line of code, so adding a command to
# the header cannot leave the help text describing an older set. It used to print a
# fixed line range, which started mid-sentence and stopped one line short of `shot`.
usage() {
  sed -n '2,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p; } }' "$0" >&2
  exit 64
}

# The application id `launch` starts: APP_ID when set, else the applicationId in
# the Android build file, wherever the Flutter project sits under this repo. Read
# at use rather than filled in by /kickoff, so this file carries no placeholder
# and a fix to it reaches every app outright instead of landing as a .kit-new to
# merge by hand.
app_id() {
  if [ -n "${APP_ID:-}" ]; then echo "$APP_ID"; return; fi
  local gradle id
  for gradle in android/app/build.gradle.kts android/app/build.gradle \
    */android/app/build.gradle.kts */android/app/build.gradle; do
    [ -f "$gradle" ] || continue
    id=$(sed -nE 's/^[[:space:]]*applicationId[[:space:]]*=?[[:space:]]*"([^"]+)".*/\1/p' "$gradle" | head -n 1)
    if [ -n "$id" ]; then echo "$id"; return; fi
  done
  echo "No application id to launch: set APP_ID, or put applicationId in android/app/build.gradle(.kts)." >&2
  return 1
}

# adb obeys ANDROID_SERIAL for every subcommand, `emu` included, so pinning it once
# keeps a phone that happens to be plugged in out of a test run -- and turns "more
# than one device" from a silent wrong target into a question.
use_device() {
  [ -n "${ANDROID_SERIAL:-}" ] && return 0
  local found count
  found=$(adb devices | awk '$2 == "device" && $1 ~ /^emulator-/ { print $1 }')
  count=$(printf '%s' "$found" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "No booted emulator. Run 'bash tool/emu.sh start' in the background, then 'ready'." >&2
    exit 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "More than one emulator is running. Set ANDROID_SERIAL to one of:" >&2
    printf '  %s\n' $found >&2
    exit 1
  fi
  export ANDROID_SERIAL=$found
}

start() {
  if [[ $(adb devices) == *emulator-* ]]; then
    echo "An emulator is already running."
    return
  fi
  local emulator=$sdk/emulator/emulator
  if [ -f "$emulator.exe" ]; then emulator=$emulator.exe; fi
  # EMU_ARGS passes flags through, e.g. EMU_ARGS=-no-snapshot-load to cold-boot
  # after a snapshot load has wedged the device.
  # shellcheck disable=SC2086 # a list of flags, deliberately split
  exec "$emulator" -avd "${AVD:-Medium_Phone}" -no-boot-anim ${EMU_ARGS:-} >/dev/null 2>&1
}

ready() {
  adb -e wait-for-device
  use_device
  until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do
    sleep 2
  done
  echo "Booted."
}

# `adb emu` prints OK or KO and exits 0 either way, so a refused save looked exactly
# like a successful one -- and the snapshot the drill relies on to put the user's
# emulator back was not there when it came time to load it.
snapshot() {
  local action=$1 name=$2 out
  out=$(adb emu avd snapshot "$action" "$name" 2>&1 || true)
  printf '%s\n' "$out"
  if printf '%s' "$out" | grep -qiE '^(KO|error)'; then
    echo "Snapshot $action of \"$name\" failed, so nothing was saved or restored." >&2
    exit 1
  fi
}

# Elements on screen, tab separated: label, x, y, flags. The status and
# navigation bars are left out; so is anything with no label that can't be
# tapped, typed into, or scrolled.
elements() {
  # Delete the previous dump first. Without this, three failed attempts still left
  # the last successful ui.xml on the device and `screen` printed it with exit 0 --
  # so a tap landed on a screen that was no longer showing, or a control was
  # reported missing from a screen that was never read. The failure happens exactly
  # when something is animating, which is exactly after a tap or a launch.
  adb shell rm -f /sdcard/ui.xml >/dev/null 2>&1 || true
  local dumped=
  for _ in 1 2 3; do
    # Fails with "could not get idle state" while something animates.
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && { dumped=1; break; }
    sleep 1
  done
  if [ -z "$dumped" ]; then
    echo "Could not read the screen: uiautomator would not settle after three tries." >&2
    echo "Something is still animating. Wait a moment and run 'screen' again." >&2
    exit 1
  fi
  adb exec-out cat /sdcard/ui.xml | tr '>' '\n' | awk '
    function attr(name) {
      if (!match($0, " " name "=\"[^\"]*\"")) return ""
      s = substr($0, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
      # Lines become " / "; emoji (category icons) are dropped.
      gsub(/&#10;/, " / ", s); gsub(/&#[0-9]+;|\xef\xb8\x8f/, "", s)
      gsub(/( \/ )+/, " / ", s); sub(/^ \/ /, "", s); sub(/ \/ $/, "", s)
      gsub(/  +/, " ", s); gsub(/^ +| +$/, "", s)
      gsub(/&quot;/, "\"", s)
      gsub(/&apos;/, "'"'"'", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s)
      gsub(/&amp;/, "\\&", s)
      return s
    }
    /<node / {
      if (attr("package") == "com.android.systemui") next
      text = attr("text"); desc = attr("content-desc")
      if (desc == "") label = text
      else if (text == "" || text == desc) label = desc
      else label = desc " | " text
      # A text field has its label as a hint; the typed text follows it.
      # (No apostrophes anywhere in this awk program: it is single-quoted.)
      hint = attr("hint")
      if (hint != "") label = label == "" ? hint : hint " | " label
      flags = ""
      if (attr("class") == "android.widget.EditText") flags = flags " field"
      if (attr("checked") == "true") flags = flags " checked"
      if (attr("selected") == "true") flags = flags " selected"
      if (attr("focused") == "true") flags = flags " focused"
      if (attr("enabled") == "false") flags = flags " disabled"
      if (attr("scrollable") == "true") flags = flags " scrollable"
      if (label == "") {
        if (attr("clickable") != "true" && flags !~ /field|scrollable/) next
        label = "(no label)"
      }
      b = attr("bounds"); gsub(/[^0-9]+/, " ", b); split(b, n, " ")
      printf "%s\t%d\t%d\t%s\n", label, (n[1] + n[3]) / 2, (n[2] + n[4]) / 2,
        substr(flags, 2)
    }'
}

screen() {
  elements | awk -F'\t' '{
    printf "%s @ %d,%d%s\n", $1, $2, $3, ($4 == "" ? "" : "  (" $4 ")")
  }'
}

# "x y" of the nth element labelled $1 exactly, or else containing it.
locate() {
  local label=${1:?needs a label} n=${2:-1} all hit
  all=$(elements)
  hit=$(awk -F'\t' -v want="$label" -v n="$n" '
    $1 == want { exact[++e] = $2 " " $3 }
    index(tolower($1), tolower(want)) { loose[++l] = $2 " " $3 }
    END { if (e >= n) print exact[n]; else if (l >= n) print loose[n] }
  ' <<<"$all")
  if [ -z "$hit" ]; then
    echo "No element $n labelled \"$label\". On screen:" >&2
    awk -F'\t' '{ printf "  %s @ %d,%d\n", $1, $2, $3 }' <<<"$all" >&2
    exit 1
  fi
  echo "$hit"
}

tap() {
  local pos
  pos=$(locate "$@")
  adb shell input tap $pos
  echo "Tapped \"$1\" @ ${pos/ /,}."
}

hold() {
  local pos
  pos=$(locate "$@")
  adb shell input swipe $pos $pos 800
  echo "Held \"$1\" @ ${pos/ /,}."
}

type_text() {
  local text=${1:?needs text}
  if [[ $text == *"'"* ]]; then
    echo "Typing a ' isn't supported." >&2
    exit 1
  fi
  adb shell "input text '${text// /%s}'"
}

scroll() {
  local size w h
  size=$(adb shell wm size | tr -d '\r' | awk 'END { print $NF }')
  w=${size%x*} h=${size#*x}
  case ${1:-} in
  down) adb shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 300 ;;
  up) adb shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 7 / 10)) 300 ;;
  *) usage ;;
  esac
}

command=${1:-}
if [ $# -gt 0 ]; then shift; fi

# Every command but these needs a device, and needs it to be the right one.
case $command in
start | app | '' | -h | --help | help) ;;
*) use_device ;;
esac

case $command in
start) start ;;
stop) adb emu kill && echo "Stopping the emulator." ;;
ready) ready ;;
save) snapshot save "${1:?needs a name}" ;;
load) snapshot load "${1:?needs a name}" && adb wait-for-device ;;
snapshots) adb emu avd snapshot list ;;
forget) snapshot delete "${1:?needs a name}" ;;
install) adb install -r "${1:?needs an apk}" | tail -1 ;;
launch) app=$(app_id) && adb shell am start -S -n "$app/.MainActivity" >/dev/null && echo "Launched." ;;
app) app_id ;;
screen) screen ;;
tap) tap "$@" ;;
hold) hold "$@" ;;
tapxy) adb shell input tap "${1:?needs x}" "${2:?needs y}" ;;
type) type_text "$@" ;;
key) adb shell input keyevent "KEYCODE_${1^^}" ;;
scroll) scroll "$@" ;;
push) adb push "${1:?needs a file}" /storage/emulated/0/Download/ | tail -1 ;;
shot) adb exec-out screencap -p >"${1:?needs a file}" && echo "Saved $1." ;;
*) usage ;;
esac
