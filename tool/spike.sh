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
#   redact <on|off>    check 4: drive OTP redaction for untrusted listeners
#   otp                check 4: post a one-time-code message with redaction on
#   sms <from> <text>  check 1/5: a real SMS into Google Messages, which posts a
#                      genuine third-party MessagingStyle with a reply action
#   smsapp             make Google Messages the default SMS app (needed once)
#   dismiss            clear all notifications, for check 5's "after dismissal"
#   reply [key] [text] check 5: fire a held reply action, by default the last one
#                      seen, after its notification is gone
#   pull [file]        copy the dump off the device (default docs/research/spike-dump.jsonl)
#   summary            read the pulled dump and print one line per notification
#
# DEVICE picks a device other than the only attached one.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # stops Git Bash rewriting /sdcard into a Windows path

APP_ID=com.oasisforge.replybox
SERVICE="$APP_ID/$APP_ID.spike.SpikeListenerService"
DUMP_ON_DEVICE="/sdcard/Android/data/$APP_ID/files/spike-dump.jsonl"
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
    echo "dump cleared"
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
    case "${2:-}" in
      on)  adb shell cmd notification redact_otp_from_untrusted_listeners true;  echo "redaction ON" ;;
      off) adb shell cmd notification redact_otp_from_untrusted_listeners false; echo "redaction OFF" ;;
      *)   echo "usage: spike.sh redact <on|off>" >&2; exit 1 ;;
    esac
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
