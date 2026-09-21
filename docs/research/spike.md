# Capture spike

_Run 21 September 2026. Emulator only. Go/no-go is **provisional**: the two checks that can stop the product are not answered yet._

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

Three separate conversations posted at once arrived as three distinct notifications under one package, distinguished by `tag` and `conversationTitle`, each with its own `groupKey`. A per-package assumption would merge them; a per-`groupKey` one does not.

### 3. Survival — not run

Needs a physical OEM device (Samsung, Xiaomi, Oppo) and 24 hours of elapsed time with the app unopened. The emulator reports manufacturer `Google` and has no battery-management layer to survive, so running this here would produce a pass that means nothing.

This is a stop condition. It stays open.

### 4. Redaction — pass, and stricter than assumed

A one-time-code SMS reached the listener with its content replaced by `"Sensitive notification content hidden"` — in `text`, in `bigText`, **and inside `EXTRA_MESSAGES`** — with `title` and the message `sender` emptied to `""`. An ordinary message sent seconds later from another number arrived completely intact. Nothing crashed, and the notification was otherwise well-formed: `category` `msg`, `channelId` `bugle_default_channel`, `flags` 16.

Two findings worth more than the pass itself:

- **It could not be turned off.** `cmd notification redact_otp_from_untrusted_listeners false`, then revoking and re-granting notification access so the listener rebound, still produced a redacted message. Treat redaction as a permanent condition of being a third-party listener on this API level, not a setting a user can waive.
- **It does not reproduce with `cmd notification post`.** Shell-posted notifications came through unredacted with the toggle on, with a device PIN set, every time. The redaction is applied by the system's classifier to real app notifications, and the shell is exempt. **A redaction fixture cannot be manufactured from the shell — it needs a real app.**

### 5. Reply after dismissal — pass

The listener held the `Reply` action from an incoming SMS, then cancelled every notification through `cancelAllNotifications()` (19 removals recorded, all `LISTENER_CANCEL_ALL`, confirmed by the shade going from 6 messaging notifications to 0). Firing the held `PendingIntent` afterwards returned `sent`, with no `CanceledException`.

So a reply survives the notification being dismissed. What it does not survive is process death: the action map is in memory because a `PendingIntent` cannot be serialised. That is the real boundary for the REP rules — "reply available" means "held in this process", and after a restart the answer is "open in app".

Removal reasons came through correctly and are now mapped to names in the dump: `LISTENER_CANCEL_ALL` and `APP_CANCEL` were both observed.

## Go / no-go

**Provisional go, on the framework.** Everything the Android APIs are responsible for behaved as the product needs: `MessagingStyle` history survives bursts, `RemoteInput` round-trips, held actions outlive their notifications, redaction degrades to a marker rather than a crash.

**Not a go on the product question**, which is whether the six messaging apps people actually use post repliable notifications, and whether a listener stays alive for a day on a phone that is trying to kill it. Checks 1 and 3 are the two stop conditions in the plan and both need hardware that does not exist here yet.

Nothing in Phase 2 should be treated as unblocked on the strength of this file alone. What it does unblock is the *shape* of the code: the dump format below is stable enough for PR 2's normaliser to be written against.

## What the fixtures look like

One JSON object per line, appended (never rewritten — a burst is exactly when a rewrite would drop events). Every record carries `sdkInt` and `release`, because a redaction fixture captured at one API level says nothing about another: redaction widened in Android 15 and again in 16.

Fields chosen for what the normaliser needs, not for readability: `key`, `package`, `tag`, `postTime`, `groupKey`, `isGroupSummary`, `flags`, `channelId`, `category`, `shortcutId`, `template`, `title`, `text`, `bigText`, `conversationTitle`, `isGroupConversation`, `selfDisplayName`, `messages[]` (sender, text, time, type), `actions[]` (title, semanticAction, isContextual, remoteInputs with resultKey and allowFreeFormInput), `hasRemoteInput`, and on removal `removalReason` with its name.

## When hardware arrives

In one sitting, on a real phone with real accounts:

1. Register WhatsApp, Signal, Messenger, Instagram and Telegram. Post one message to each, dump it, and record whether a reply sent through the notification actually lands in the chat. That is check 1, properly.
2. Record each app's conversation key — shortcut ID, conversation title, tag — since the plan flags this as the thing that decides how threads are identified.
3. Capture a photo message and a voice note per app, which no check covers but which the normaliser has to survive.
4. Leave the listener bound on an OEM device for 24 hours with the app unopened, then check delivery. That is check 3.
5. Note whether work-profile notifications reach the listener at all.

Until then, treat every rule written from this file as provisional on checks 1 and 3.
