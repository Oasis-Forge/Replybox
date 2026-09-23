# Capture spike

_Run 21 September 2026. Emulator only. Go/no-go is **provisional**: the two checks that can stop the product are not answered yet._

_Added 23 September 2026: "Emulator only" describes the run above and no longer describes the whole file. One later section, **What the phone of 23 September 2026 settled**, records a physical phone. Nothing above that heading was observed on hardware, and no result is promoted into it._

The five checks are defined in `docs/PLAN.md` section 5. This file records what was run, on what, and what came back. The raw captures are in `docs/research/spike-dumps/`, one file per case and one JSON object per notification event, and `tool/spike.sh` reruns every step.

| Dump | Case |
|---|---|
| `shell-burst.jsonl` | five messages in one conversation, then three conversations at once |
| `messages-redaction.jsonl` | a one-time-code SMS and an ordinary one beside it, both from a real app |
| `messages-reply-after-dismissal.jsonl` | an SMS, the shade cleared, then the held reply fired |

## What it ran on

| | |
|---|---|
| Device | `emulator-5554`, no physical phone available |
| Android | 17 (`ro.build.version.release`), API 37 (`sdkInt` on every dump record) |
| Manufacturer | `Google` — so no OEM battery management of any kind |
| Play Store | present (`com.android.vending`) |
| Real messaging apps | none. WhatsApp, Signal, Messenger, Instagram and Telegram all need a phone number to register, and the emulator has none |
| Stand-in | Google Messages (`com.google.android.apps.messaging`) driven by `adb emu sms send`, which is a genuine third-party app posting genuine `MessagingStyle` notifications |

The code is a throwaway `NotificationListenerService` in `android/app/src/debug/`, deliberately outside the release source set. It is scaffolding for deciding the capture rules, not a shipped feature.

## Results

| Check | Result | What was actually observed |
|---|---|---|
| 1. Reply actions | **Partial** | One real app confirmed, five not tested |
| 2. Burst behaviour | **Pass** | Every message recoverable from `EXTRA_MESSAGES` |
| 3. Survival (24h, OEM) | **Not run** | No OEM device, and no 24 hours elapsed |
| 4. Redaction | **Pass, and stricter than assumed** | Redaction fired and could not be switched off |
| 5. Reply after dismissal | **Pass** | A held `PendingIntent` still delivered after the notification was cancelled |

### 1. Reply actions — partial

Google Messages posts `android.app.Notification$MessagingStyle` with two actions: `Reply` (`semanticAction` 1) carrying a `RemoteInput` with `resultKey` `android.intent.extra.TEXT` and `allowFreeFormInput` true, and `Mark as read` (`semanticAction` 2) with no `RemoteInput`. So the mechanism the whole product rests on works against a real third-party app on this API level.

That is one app out of six. **WhatsApp, Messenger and Instagram are the three whose failure is a stop condition, and none of them was tested.** Nothing here should be read as evidence about them; they are separate codebases with their own notification styles, and the plan names them individually for that reason.

### 2. Burst behaviour — pass

A single notification carrying five messages arrived with `text` collapsed to `"fifth message"` — the newest line only — while `EXTRA_MESSAGES` still held all five in order, each with its sender and timestamp. That is exactly the case that decides whether the inbox can tell the truth during a burst: the visible summary loses messages and the structured history does not.

Three separate conversations posted at once arrived as three distinct notifications under one package, distinguished by `tag` and `conversationTitle`.

**Correction, 21 September 2026.** An earlier version of this paragraph said the three conversations each carried their own `groupKey`, and that keying on `groupKey` would keep them apart. The dumps committed beside this file say the opposite, and the rule written from it would have been wrong. The three shell conversations all carry `0|com.android.shell|g:Aggregate_AlertingSection`, and the three Google Messages threads all carry `0|com.google.android.apps.messaging|g:incoming_message_group_key` — Android reassigns `groupKey` when it auto-groups an app's notifications. One notification's `groupKey` also changed between its post and its removal. So a per-`groupKey` assumption merges every thread in an app into one, exactly as a per-package assumption does.

What actually separates them is `shortcutId`, which Google Messages supplied per conversation (`"1"`, `"2"`, `"4"`), and failing that `conversationTitle`, and failing that `tag`. That is the order CAP-3 takes, with `groupKey` excluded outright.

### 3. Survival — not run

Needs a physical OEM device (Samsung, Xiaomi, Oppo) and 24 hours of elapsed time with the app unopened. The emulator reports manufacturer `Google` and has no battery-management layer to survive, so running this here would produce a pass that means nothing.

This is a stop condition. It stays open.

### 4. Redaction — pass, and stricter than assumed

A one-time-code SMS reached the listener with its content replaced by `"Sensitive notification content hidden"` — in `text`, in `bigText`, **and inside `EXTRA_MESSAGES`** — with `title` and the message `sender` emptied to `""`. An ordinary message sent seconds later from another number arrived completely intact. Nothing crashed, and the notification was otherwise well-formed: `category` `msg`, `channelId` `bugle_default_channel`, `flags` 16.

Two findings worth more than the pass itself:

- **It could not be turned off.** Redaction fired on every attempt to be rid of it, including after revoking and re-granting notification access so the listener rebound. Treat redaction as a permanent condition of being a third-party listener on this API level, not a setting a user can waive.

  **Correction, 21 September 2026.** An earlier version of this bullet said the toggle was set to `false` first — `cmd notification redact_otp_from_untrusted_listeners false` — and that a redacted message came through anyway. The device drill of the same date found that command now fails from the shell with `Package android does not belong to 2000`, so it sets nothing and almost certainly set nothing then either. What is actually true is smaller and enough: OTP redaction is **on by default** at API 37 and was never observed off. The bullet's conclusion is unchanged; only its evidence is. `tool/spike.sh` still runs the dead `redact` step, and it is listed under Known bugs in `docs/ROADMAP.md`.
- **It does not reproduce with `cmd notification post`.** Shell-posted notifications came through unredacted with the toggle on, with a device PIN set, every time. The redaction is applied by the system's classifier to real app notifications, and the shell is exempt. **A redaction fixture cannot be manufactured from the shell — it needs a real app.**

### 5. Reply after dismissal — pass

The listener held the `Reply` action from an incoming SMS, then cancelled every notification through `cancelAllNotifications()` (19 removals recorded, all `LISTENER_CANCEL_ALL`, confirmed by the shade going from 6 messaging notifications to 0). Firing the held `PendingIntent` afterwards returned `sent`, with no `CanceledException`.

So a reply survives the notification being dismissed. What it does not survive is process death: the action map is in memory because a `PendingIntent` cannot be serialised. That is the real boundary for the REP rules — "reply available" means "held in this process", and after a restart the answer is "open in app".

Removal reasons came through correctly and are now mapped to names in the dump: `LISTENER_CANCEL_ALL` and `APP_CANCEL` were both observed. `LISTENER_CANCEL_ALL` here is the listener cancelling notifications itself — not the shade's **Clear all**, which the device drill below recorded as `CANCEL_ALL`.

## What the device drill of 21 September 2026 settled

The spike above was a throwaway listener in the debug source set. On the same date, after the capture code was written, the **shipped** listener was driven by hand on `emulator-5554` (Android 17, API 37) and its hand-over queue pulled off the device — the dump is `spike-dumps/2026-09-21-shipped-projection.jsonl`, and its README says which projection wrote which file. Four things the spike left open now have evidence, and one of them is new.

- **The phone owner's own line, from a real app.** Replying inline from the shade made Google Messages append a history entry with a null `Person`, and the shipped projection emitted `{"senderAbsent":true,"text":…}` with **no `sender` key at all** — neither an empty sender nor a `sender_person`. The spike never captured a line the posting user wrote, so this is the first observation of it, and it is what the direction rule rests on.
- **The shade's Clear all arrives as `CANCEL_ALL`.** All six removals in the drill carried `removalReasonName` `CANCEL_ALL`. The `LISTENER_CANCEL_ALL` recorded in check 5 above is a different thing: that was the listener cancelling notifications itself through `cancelAllNotifications()`. Both reasons exist; the shade button is not the one check 5 measured.
- **A shell-posted `MessagingStyle` carries no `category` at all.** `cmd notification post` has no flag for a notification category, so the shell cannot build one. That is a limit of the tool, not a finding about apps — but it means the raw non-`MessagingStyle` path has no device evidence and no fixture, and nothing about it should be read as tested.
- **A history entry's own time moved.** Google Messages posted one notification twice, 501 ms apart, and the entry's own `time` was different in the two posts. This is new. It matters because the entry time was being treated as a fixed property of the message; it is not always one, and a defect lived in that assumption.

**What this drill does not do.** It ran on an emulator reporting manufacturer `Google`, with one real messaging app and one shell stand-in.

- Check 1 stays **partial**. One app of six is still one app of six.
- Check 3 stays **not run**, and stays a stop condition. There is still no OEM device and still no 24 hours of an unopened app.
- **No provisional mark comes off.** Every rule marked provisional under CAP-25 stays marked. CAP-25 says a mark comes off with a dated result on hardware; this is a dated result on an emulator, which is the thing CAP-25 was written to distinguish.

## What the phone of 23 September 2026 settled

Everything above this line ran on an emulator. This section is the first time any of it ran on a physical Android phone, and it is deliberately short, because very little was driven.

A debug-signed release APK of 0.2.0, built from `main` at commit 185425a — the Inbox merge, with no Permissions work in it — was installed on a phone. Notification access was granted **by hand, on the system's own notification-access page**. A real WhatsApp notification then arrived and was drawn as a row in the inbox list.

| | |
|---|---|
| Device | a physical Android phone. Manufacturer, model and Android version were not recorded — which is why this run says nothing about check 3, where the manufacturer is the whole question |
| Build | `0.2.0`, release APK, debug-signed, from `main` at 185425a |
| Real messaging app | WhatsApp, registered on this phone. The first of the six the plan names to post a notification at this listener anywhere |
| How access was granted | by hand in system settings. That build has no route to that page, and the user reached it only because they were told which page to open |
| Dump pulled | none. Nothing was written to `spike-dumps/`, so there is no fixture and no field-level record of what WhatsApp's notification contained |

**What is answered.** A notification from a real, unmodified WhatsApp reaches the **shipped** listener, survives CAP-1's filter as a shipped default, passes through the hand-over queue and the Dart normaliser, and is drawn as an inbox row. Until today every app in the shipped six was a guess made from Google Messages, and the emulator could not register any of them (see *What it ran on*, above). That is now one observed app, on hardware.

**What is not answered, and the list has barely moved.**

- Whether a reply sent from the app lands in the WhatsApp chat. Nothing was replied to. **Check 1 stays partial** — it is a check about reply actions round-tripping, and the round trip was not run.
- Signal, Messenger and Instagram. Two of those three are stop conditions and neither was installed. Telegram likewise.
- **Check 3 stays not run**, and stays a stop condition. No 24 hours elapsed with the app unopened, and the manufacturer was not even written down.
- Work-profile notifications (PERM-17). Not tested, not set up.

**What no mark may be taken off for.** No dump was pulled, so what this notification actually held — its `shortcutId`, its `EXTRA_MESSAGES`, its actions — was never recorded. The evidence is a row on a screen, not a field in a file. Any CAP-25 mark that rests on a *field* still rests on the emulator.

**One observation that is not about capture at all.** Before access was granted, the app captured nothing and said nothing whatsoever about why: an empty screen, no explanation, no route to the page that would fix it. The user got there because they were told. That is the Permissions area's justification, observed rather than argued, and it is recorded here because this is the only place it was seen.

## Go / no-go

**Provisional go, on the framework.** Everything the Android APIs are responsible for behaved as the product needs: `MessagingStyle` history survives bursts, `RemoteInput` round-trips, held actions outlive their notifications, redaction degrades to a marker rather than a crash.

**Not a go on the product question**, which is whether the six messaging apps people actually use post repliable notifications, and whether a listener stays alive for a day on a phone that is trying to kill it. Checks 1 and 3 are the two stop conditions in the plan and both need hardware that does not exist here yet.

Nothing in Phase 2 should be treated as unblocked on the strength of this file alone. What it does unblock is the *shape* of the code: the dump format below is stable enough for PR 2's normaliser to be written against.

**Correction, 23 September 2026.** The paragraph above says both stop conditions "need hardware that does not exist here yet". Hardware now exists — the phone run of 23 September is recorded above. The verdict is unchanged anyway, and it is worth being exact about why: check 1 needed a reply to land in a real chat and no reply was sent, and check 3 needed a day of elapsed time on a named OEM and got neither. What did change is the one sentence about the six apps: one of them has now posted a notification that became a row. That is a go on nothing; it is the first hardware evidence this file has ever carried.

## What the fixtures look like

One JSON object per line, appended (never rewritten — a burst is exactly when a rewrite would drop events). Every record carries `sdkInt` and `release`, because a redaction fixture captured at one API level says nothing about another: redaction widened in Android 15 and again in 16.

Fields chosen for what the normaliser needs, not for readability: `key`, `package`, `tag`, `postTime`, `groupKey`, `isGroupSummary`, `flags`, `channelId`, `category`, `shortcutId`, `template`, `title`, `text`, `bigText`, `conversationTitle`, `isGroupConversation`, `selfDisplayName`, `messages[]` (sender, text, time, type), `actions[]` (title, semanticAction, isContextual, remoteInputs with resultKey and allowFreeFormInput), `hasRemoteInput`, and on removal `removalReason` with its name.

## When hardware arrives

In one sitting, on a real phone with real accounts:

1. Register WhatsApp, Signal, Messenger, Instagram and Telegram. Post one message to each, dump it, and record whether a reply sent through the notification actually lands in the chat. That is check 1, properly. — **partly done, 23 September 2026, and only the first clause of it**: WhatsApp was registered and one of its notifications became an inbox row. No dump was taken, no reply was sent, and the other four apps were not installed. The item stays open.
2. Record each app's conversation key — shortcut ID, conversation title, tag — since the plan flags this as the thing that decides how threads are identified. — open. The 23 September run pulled no dump, so WhatsApp's key was never read.
3. Capture a photo message and a voice note per app, which no check covers but which the normaliser has to survive. — open.
4. Leave the listener bound on an OEM device for 24 hours with the app unopened, then check delivery. That is check 3. — open, and the 23 September run did not even record the manufacturer.
5. Note whether work-profile notifications reach the listener at all. — open (PERM-17).

Hardware arrived on 23 September 2026 and four and a half of these five are still untouched, so the sentence below is unchanged: treat every rule written from this file as provisional on checks 1 and 3.
