#!/usr/bin/env bash
# Drives the capture spike of docs/PLAN.md section 5 on an emulator or phone,
# headlessly. Every check writes into one JSONL dump, and `pull` fetches it.
#
#   bash tool/spike.sh <command> [args]
#
#   install            build nothing, just install build/app/outputs/flutter-apk/app-debug.apk
#   enable             grant the spike listener notification access
#   disable            revoke it again, for putting the device back
#   status             is the listener allowed, and is it currently connected
#   reset              delete the dump and start a clean run
#   burst              check 2: five messages in one chat, then three chats at once
#   redact             GONE. `cmd notification redact_otp_from_untrusted_listeners`
#                      fails from the shell at API 37 with "Package android does not
#                      belong to 2000", so this step never did what it claimed. It is
#                      kept as a command only to say so; redaction is on by default.
#   otp                check 4: post a one-time-code message, redaction on by default
#   sms <from> <text>  check 1/5: a real SMS into Google Messages, which posts a
#                      genuine third-party MessagingStyle with a reply action
#   smsapp             make Google Messages the default SMS app (needed once)
#   dismiss            clear all notifications, for check 5's "after dismissal"
#   reply [key] [text] check 5: fire a held reply action, by default the last one
#                      seen, after its notification is gone
#   grant-post         grant POST_NOTIFICATIONS, which the raw poster needs to post
#   post <shape> [text] [--es k v ...]
#                      CAP-21/6/7/8: post a shape nothing else on the device can.
#                      Shapes: raw-msg raw-social raw-email raw-reply raw-nocategory
#                      repost title-empty title-absent ongoing summary summary-child
#                      raw-otp raw-otp-control
#   repost [n] [text]  post ONE id n times (default 3), each time with a different
#                      text: the everyday duplication shape (CAP-5)
#   bridge on|off|status
#                      CAP-21's STORAGE half. Replays the poster's notifications
#                      through the SHIPPED projection, store and queue under the
#                      substituted package com.oasisforge.spikeraw. Off on every
#                      install and after every `reset`; read SpikeCaptureBridge's
#                      header before trusting a result (PERM-12).
#   raw                post every CAP-21 shape in one go, in drill order
#   db [file]          copy the app database off the device (default $TMP/replybox.db)
#   pull [file]        copy the dump off the device (default docs/research/spike-dump.jsonl)
#   summary            read the pulled dump and print one line per notification
#
# DEVICE picks a device other than the only attached one.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # stops Git Bash rewriting /sdcard into a Windows path

APP_ID=com.oasisforge.replybox
SERVICE="$APP_ID/$APP_ID.spike.SpikeListenerService"
DUMP_ON_DEVICE="/sdcard/Android/data/$APP_ID/files/spike-dump.jsonl"
# Existence is the flag. SpikeCaptureBridge writes it and only the SPIKE_BRIDGE
# broadcast reaches that code, so `bridge status` reads the device rather than
# remembering what the last command claimed.
BRIDGE_FLAG_ON_DEVICE="/sdcard/Android/data/$APP_ID/files/spike-bridge.on"
# Kept in step with SpikeCaptureBridge.SUBSTITUTE_PACKAGE, which SpikeCaptureBridgeTest
# pins. It is deliberately not $APP_ID and not under it: PERM-12 promises Replybox
# never appears as a source app, and a bridged row under the app's own id would.
SUBSTITUTE_PACKAGE=com.oasisforge.spikeraw
APK=build/app/outputs/flutter-apk/app-debug.apk

device=${DEVICE:-}
adb() { if [ -n "$device" ]; then command adb -s "$device" "$@"; else command adb "$@"; fi; }

# Everything between the shebang and `set -e`, so a command added to the header
# cannot leave the help text describing an older set.
usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

# `cmd notification post` posts as the shell, and the shell attaches no
# RemoteInput. It is therefore honest for check 2 (is every message recoverable)
# and check 4 (redaction), and says nothing at all about check 1 (reply actions),
# which needs a real messaging app. Keep that distinction in spike.md.
#
# Quoting matters twice here. `adb shell` hands the command to a shell ON the
# device, which re-splits it on spaces, so an argument quoted only locally
# arrives in pieces: the first version of this function sent
# --conversation "Ada Lovelace" and the notification came back with tag
# "Lovelace" and text "--message". Everything therefore goes to adb as ONE
# string with the device-side quoting written into it.
post_msg() {
  local conv=$1 who=$2 text=$3 tag=$4
  adb shell "cmd notification post -S messaging --conversation '$conv' --message '$who:$text' '$tag' '$text'" >/dev/null
}

# One notification carrying several messages, which is the case check 2 is
# really about: the visible text collapses to the newest line and every earlier
# message has to still be there in EXTRA_MESSAGES.
post_thread() {
  local conv=$1 who=$2 tag=$3; shift 3
  local args=''
  for m in "$@"; do args="$args --message '$who:$m'"; done
  adb shell "cmd notification post -S messaging --conversation '$conv'$args '$tag' 'thread'" >/dev/null
}

case "${1:-}" in
  install)
    [ -f "$APK" ] || { echo "no $APK -- run: flutter build apk --debug" >&2; exit 1; }
    adb install -r "$APK"
    ;;
  enable)
    adb shell cmd notification allow_listener "$SERVICE"
    echo "allowed: $SERVICE"
    ;;
  disable)
    adb shell cmd notification disallow_listener "$SERVICE"
    echo "revoked: $SERVICE"
    ;;
  status)
    echo "allowed listeners:"
    adb shell settings get secure enabled_notification_listeners
    echo "dump on device:"
    adb shell "ls -l $DUMP_ON_DEVICE 2>/dev/null || echo '  (none yet)'"
    ;;
  reset)
    adb shell "rm -f $DUMP_ON_DEVICE"
    # The bridge goes off with the dump. It is opt-in per drill on purpose -- while
    # it is open the app's own notification text reaches the shipped capture queue --
    # so a "clean run" that left it on from yesterday would be the one state nobody
    # would think to check (PERM-12).
    bash "$0" bridge off >/dev/null 2>&1 || true
    echo "dump cleared; bridge off"
    ;;
  burst)
    # Five in one chat, as one notification: the collapse case.
    post_thread "Ada Lovelace" "Ada" spike-burst \
      "first message" "second message" "third message" "fourth message" "fifth message"
    # Then three chats at once, which is where a per-package assumption breaks:
    # all three arrive under the same package and differ only by tag and title.
    post_msg "Grace Hopper" "Grace" "first of three conversations" spike-conv-a
    post_msg "Alan Turing" "Alan" "second of three conversations" spike-conv-b
    post_msg "Katherine Johnson" "Katherine" "third of three conversations" spike-conv-c
    echo "posted a 5-message thread and 3 separate conversations"
    ;;
  redact)
    # Removed rather than fixed, because there is nothing to fix: the command it
    # wrapped now refuses the shell outright at API 37 --
    # `cmd notification redact_otp_from_untrusted_listeners true|false` answers
    # "Package android does not belong to 2000" for BOTH values, so the old `redact
    # off` step silently did nothing and the run that followed it was a run with
    # redaction ON. It did not change any result -- redaction is on by default at
    # this level and CAP-8 treats it as permanent -- but the step claimed a control
    # it never had. Kept as a command only so an old note lands here instead of on
    # the usage text (device drill, 21 September 2026).
    echo "spike.sh redact is gone: cmd notification redact_otp_from_untrusted_listeners" >&2
    echo "fails from the shell at API 37 (\"Package android does not belong to 2000\")" >&2
    echo "for both true and false. Redaction is on by default; it cannot be toggled" >&2
    echo "from here, and CAP-8 treats it as a permanent condition." >&2
    exit 1
    ;;
  otp)
    # The pair is the point: if redaction is working, the code message comes
    # through altered and the ordinary one right beside it comes through intact.
    # A run that redacts both, or neither, tells you nothing.
    post_msg "Bank" "Bank" "Your one-time code is 418923. Do not share it." spike-otp
    post_msg "Bank" "Bank" "an ordinary message with no code in it" spike-plain
    echo "posted one OTP message and one ordinary message"
    ;;
  smsapp)
    adb shell cmd role add-role-holder android.app.role.SMS com.google.android.apps.messaging
    adb shell settings put secure sms_default_application com.google.android.apps.messaging
    echo "default SMS app: $(adb shell settings get secure sms_default_application)"
    ;;
  sms)
    from=${2:?usage: spike.sh sms <from> <text>}
    text=${3:?usage: spike.sh sms <from> <text>}
    # `adb emu` talks to the emulator console, not to adb's device protocol, so
    # it takes no -s and only works on an emulator.
    command adb emu sms send "$from" "$text"
    echo "sent SMS from $from"
    ;;
  dismiss)
    # Goes through the listener's own cancelAllNotifications, which is what a
    # user clearing the shade does. `service call notification 1` looked like it
    # worked and did nothing.
    adb shell "am broadcast -a com.oasisforge.replybox.SPIKE_DISMISS \
      -n $APP_ID/$APP_ID.spike.SpikeReplyReceiver" >/dev/null
    sleep 1
    left=$(adb shell cmd notification list 2>/dev/null | grep -c . || true)
    echo "shade cleared; $left notifications still listed"
    ;;
  reply)
    # Check 5. With no key it replies to the last action the listener saw, which
    # after a `dismiss` is the one whose notification no longer exists.
    text=${3:-a reply sent after the notification was dismissed}
    adb shell "am broadcast -a com.oasisforge.replybox.SPIKE_REPLY \
      -n $APP_ID/$APP_ID.spike.SpikeReplyReceiver \
      ${2:+--es key '$2'} --es text '$text'" | tail -2
    ;;
  grant-post)
    # From API 33 a denied POST_NOTIFICATIONS makes `notify` a no-op with no error,
    # which reads exactly like a broken poster. Grant it before the first `post`.
    adb shell pm grant "$APP_ID" android.permission.POST_NOTIFICATIONS
    echo "granted POST_NOTIFICATIONS to $APP_ID"
    ;;
  post)
    # CAP-21's raw path, CAP-6, CAP-7 and CAP-8's absent-vs-emptied title. See
    # SpikeRawPoster's header for why none of these can be posted any other way.
    # Same device-side quoting as post_msg above: one string, quoted for the shell
    # ON the phone, or `adb shell` re-splits the text on spaces.
    shape=${2:?usage: spike.sh post <shape> [text] [extra am args]}
    text=${3:-}
    shift 2
    if [ $# -gt 0 ]; then shift; fi
    args="--es shape '$shape'"
    if [ -n "$text" ]; then args="$args --es text '$text'"; fi
    adb shell "am broadcast -a com.oasisforge.replybox.SPIKE_POST \
      -n $APP_ID/$APP_ID.spike.SpikeRawPoster $args $*" >/dev/null
    echo "posted shape $shape${text:+ -- \"$text\"}"
    ;;
  repost)
    # One id, posted n times with a different text each time. Three by default and
    # not two: two posts can pass a dedup that only ever compares against the last
    # row, and a chat notification updating as lines arrive posts the same id many
    # times over. That is the shape that duplicated a raw message on every update
    # (CAP-5), so it is drivable on its own and not only inside `raw`.
    n=${2:-3}
    base=${3:-text}
    for i in $(seq 1 "$n"); do
      bash "$0" post repost "the $base, post $i of $n" >/dev/null
      sleep 1
    done
    echo "posted one id $n times"
    ;;
  bridge)
    # CAP-21's storage half. See SpikeCaptureBridge's header: the shipped listener's
    # own-package drop is NOT touched by this and never has been. The bridge is a
    # debug-source-set class that replays the poster's notifications through the
    # shipped projection, store and queue with the package field substituted, and it
    # is the only way the raw path's storage behaviour can be driven at all without a
    # second APK.
    case "${2:-status}" in
      on|off)
        on=$([ "${2}" = on ] && echo true || echo false)
        adb shell "am broadcast -a com.oasisforge.replybox.SPIKE_BRIDGE \
          -n $APP_ID/$APP_ID.spike.SpikeRawPoster --ez on $on" >/dev/null
        sleep 1
        ;;
      status) ;;
      *) echo "usage: spike.sh bridge on|off|status" >&2; exit 1 ;;
    esac
    if adb shell "ls $BRIDGE_FLAG_ON_DEVICE" >/dev/null 2>&1; then
      echo "bridge ON -- rows are stored under $SUBSTITUTE_PACKAGE, not under a real app"
    else
      echo "bridge off"
    fi
    ;;
  raw)
    # The whole CAP-21 drill in one run, in the order STACK_NOTES.md sets out.
    for s in raw-msg raw-social raw-email raw-reply raw-nocategory \
             title-empty title-absent ongoing summary summary-child \
             raw-otp raw-otp-control; do
      bash "$0" post "$s" >/dev/null
      sleep 1
    done
    bash "$0" repost 3 >/dev/null
    echo "posted 12 shapes plus one id re-posted 3 times"
    ;;
  db)
    # The command STACK_NOTES.md documents, with the failure it does not survive
    # made explicit. `run-as ... cat databases/replybox.db` answers "No such file or
    # directory" on a fresh install until Dart has opened the database once -- which
    # reads as a broken command rather than as an app that has not run yet.
    out=${2:-${TMP:-/tmp}/replybox.db}
    if ! adb shell "run-as $APP_ID ls databases/replybox.db" >/dev/null 2>&1; then
      echo "no databases/replybox.db yet. The file is created the first time Dart opens" >&2
      echo "the database, so on a fresh install you have to launch the app once:" >&2
      echo "  adb shell am start -S -n $APP_ID/.MainActivity" >&2
      exit 1
    fi
    # exec-out, not shell: shell translates newlines and corrupts the file. With the
    # app stopped, or a write-ahead log holds rows this copy will not have.
    adb exec-out run-as "$APP_ID" cat databases/replybox.db > "$out"
    echo "wrote $out ($(wc -c < "$out") bytes)"
    ;;
  pull)
    out=${2:-docs/research/spike-dump.jsonl}
    adb pull "$DUMP_ON_DEVICE" "$out"
    echo "wrote $out ($(wc -l < "$out") lines)"
    ;;
  summary)
    f=${2:-docs/research/spike-dump.jsonl}
    [ -f "$f" ] || { echo "no $f -- run: bash tool/spike.sh pull" >&2; exit 1; }
    # Deliberately grep-based: the point is to eyeball the dump, not to build a
    # parser the fixture tests will replace anyway.
    grep -o '"event":"[^"]*"' "$f" | sort | uniq -c
    echo "--- per notification ---"
    grep '"event":"posted"' "$f" | sed -E 's/.*"package":"([^"]*)".*"conversationTitle":(null|"([^"]*)").*"hasRemoteInput":(true|false).*/\1 | conv=\3 | remoteInput=\4/' | head -40
    ;;
  *)
    usage
    ;;
esac
