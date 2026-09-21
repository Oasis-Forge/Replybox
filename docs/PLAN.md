# Plan: the notification inbox

_2026-09-21. Status: plan, nothing built. Companion to the feasibility analysis of the same date. Written to be dropped into the new repo as `docs/PLAN.md` and applied PR by PR._

Assumptions: a consumer app, free with paid upgrades, Android only (iOS cannot do this), one developer, Flutter from the app starter kit.

## 1. What we are building

One inbox of every message that reached the phone as a notification, from every app, answerable in place. WhatsApp, Messenger, Instagram, Telegram, Signal, SMS, Slack, Discord, Teams, LinkedIn, email: anything that notifies, with nothing to integrate per app. The user grants notification access once. The app shows conversations grouped across apps, replies through each notification's own reply action, keeps a list of who is waiting on a reply, snoozes, searches, and never sends a byte anywhere.

The promise, in the words the store listing should use: **everything that pinged you, in one place, answerable. Nothing leaves your phone.**

What it honestly is not: it cannot show chats from before it was installed, cannot see a conversation that never notified, and cannot start a new chat (it opens the source app instead). The listing says so.

Why it can exist: the same mechanism runs Microsoft Phone Link, Wear OS, Android Auto and Pushbullet, and Google's Play Protect guidance names "apps that aggregate notifications to help users focus" as a permitted use. Play Store apps already reply to WhatsApp, Instagram, Messenger and Telegram this way.

## 2. Decisions to make before `/new-app`

Each has a recommendation. They shape the store ID, the rules file and the first commit, so settle them first.

| Decision | Recommendation | Why |
|---|---|---|
| Name | Pick one before `/new-app`; it becomes the folder, repo, slug and store ID. Candidates: Pinged, Allbox, Replybox. Check the Play Store for clashes | The kit makes the name awkward to change afterwards |
| Store ID | `com.<name>.app` | Kit rule: permanent after first upload, no personal names |
| Ads | **None.** Free tier plus a paid "Plus" upgrade instead | An ad SDK collects device identifiers, which turns "nothing leaves your phone" into a lie on the Data safety form, and it costs the app its best trust argument: a release build with no internet permission. This is a deliberate departure from the kit's default; `/kickoff` will propose ads, answer with the principles below and rewrite rules section 6 for Plus |
| How Plus is paid | One-time purchase first. A yearly subscription is a dated decision for after launch, not v1 | Notification-tool buyers expect one-time (BuzzKill, FilterBox, Notisave premium). Plus features cost nothing per use, so there is no running cost to recover. It also reuses the kit's tested one-time-purchase flow and `in_app_purchase` traps |
| Billing library | `in_app_purchase` straight to Play Billing, no RevenueCat | No third party sees anything, and the kit's PAY rules already describe this exact flow |
| Repo visibility | Public | "Nothing leaves your phone" is verifiable when anyone can read the listener. It also gives the privacy policy a free GitHub Pages home. If you prefer private, the plan does not change |
| Competitor to study | Notisave (`com.tenqube.notisave`, 10M+ installs): same mechanism, installable on the emulator with no account. Read Beeper's listing and screenshots for inbox layout only, marked "not verified" | The kit's `/spec` needs observed behaviour, and Beeper cannot be studied without linking real accounts |
| Product principles for `/kickoff` | 1. Nothing leaves the phone: no account, no server, no analytics, no internet permission in the release build. 2. Free is complete: inbox, reply, waiting list and search never move behind a payment. 3. Honest about limits: the app says what it cannot see. 4. Never hides or answers another app's notification unless the user asked. 5. Two taps to reply or clear | Five promises every rule has to keep |
| Play account | Check whether yours predates November 2023 or is an organisation account. If it is a newer personal account, a closed test with 12 testers for 14 continuous days is required before production. Write the start date into the roadmap | The kit's Phase 0 warning: this is the one thing measured in weeks |

## 3. Free versus Plus

Defined now so nothing that ships free ever moves behind a payment (kit rule PAY-4).

| Capability | Free | Plus (one-time) |
|---|---|---|
| Unified inbox across every app that notifies | Yes | Yes |
| Inline reply, open in source app, mark done, undo | Yes | Yes |
| "Waiting on me" list | Yes | Yes |
| Snooze | Presets (1 hour, tonight, tomorrow) | Custom times, and nudges when a thread sits unanswered for a chosen period |
| History and search | Last 30 days | Unlimited |
| Choose which apps are included | Yes | Yes |
| App lock with device biometrics | Yes (a trust feature is never paid) | Yes |
| Rules: VIP senders, keyword alerts, mute a sender or chat, quiet hours per app | No | Yes |
| Home-screen widget with the waiting count | No | Yes |
| Export and backup (on device, user-initiated) | Delete everything only | Yes |
| On-device summaries and reply drafts on devices with Gemini Nano | No | Yes, opt-in |
| Themes and icons | One | All |

Price is set in Play Console, never in code (PAY-2). A starting point to decide against comparables:

| Product | Model | Price seen |
|---|---|---|
| BuzzKill (notification rules) | One-time | About $4 |
| Pushbullet Pro | Subscription | About $5 a month, $40 a year |
| Beeper Plus | Subscription | $9.99 a month |
| This app, proposal | One-time Plus | $5 to $8, with Play's local pricing |

## 4. Architecture

The one rule that shapes everything: the listener runs whether or not the Flutter app is alive, so capture cannot depend on Dart being up. Everything else follows the kit's Flutter architecture (models, `db/` with migration steps, `providers/`, `services/` behind interfaces, presentational `screens/`, `l10n/`).

**Data flow.**
1. A Kotlin `NotificationListenerService` (our own, about 300 lines; the kit's stack notes prefer platform-channel glue over packages that drag in WorkManager and boot receivers) receives each notification. It skips group summaries, extracts the MessagingStyle payload (sender, text, time, conversation title, shortcut ID, group flag, avatar), and appends one JSON row to a small native SQLite queue. The queue's schema is one JSON column and a timestamp, so it never needs a migration. It keeps the reply `PendingIntent` and `RemoteInput` in memory keyed by notification key, and rebuilds that map from `getActiveNotifications()` whenever the service reconnects.
2. Removal events (`onNotificationRemoved` with its reason) go into the same queue: a click or an app cancel means the user read it in the source app.
3. Dart drains the queue on launch, on resume, and on each event from an `EventChannel` while the app is open. The normaliser turns raw rows into conversations and messages in the app database (dedup by app, conversation key, sender, text and time), owned by the kit's `DBHelper` with ordered migration steps.
4. Screens read providers. Reply, open-in-app, and reminder alarms go back over a `MethodChannel`. A tiny native `AlarmManager` receiver posts snooze and nudge notifications with text Dart handed it at scheduling time, and reschedules after reboot.
5. Plus rules that need an instant reaction (VIP or keyword alert while the app is closed) are exported by Dart as a small JSON rule set the listener evaluates at capture. Everything else is evaluated in Dart.

**Services behind interfaces** (tests get no-op fakes; only `main.dart` builds the real ones): `NotificationSource`, `ReplyService`, `AppLauncher`, `ReminderScheduler`, `Entitlements`, `AppLock`.

**Schema, first version.** `apps` (package, label, enabled, last_seen_at). `conversations` (id, package, conversation_key, title, is_group, avatar, last_message_at, last_inbound_at, done_at, snoozed_until, muted, plus REC and DEL columns). `messages` (id, conversation_id, sender, text, sent_at, inbound, redacted, notification_key, plus REC and DEL columns). A normalised text column for accent-insensitive search (LANG-4) and an FTS table over it.

**Permissions in the release build**, checked both ways by the kit's release workflow (RUN-2): `POST_NOTIFICATIONS` (own reminders), `RECEIVE_BOOT_COMPLETED` (reschedule reminders), `com.android.vending.BILLING` (Plus). The listener is a service permission, not a runtime one. No `INTERNET`, no SMS permissions (Google Messages notifies like any other app), no accessibility service. The spike confirms billing works without `INTERNET`; if it does not, that permission is added with a dated decision and the listing wording changes.

**What the listener must handle from day one.** Grouped notifications (take the child, drop the summary). Re-posted notifications that carry the whole thread again (dedup). Android 15 and 16 redaction of one-time codes (store as redacted, show a placeholder). A reply action that is gone because the notification was dismissed (show "open in app" instead of a broken send). OEMs that kill background services (detect the manufacturer and show the exact settings path).

## 5. Week 1: the spike, before any repo exists

A throwaway project on a real phone running Android 15 or 16, plus one Samsung or Xiaomi device if you can borrow one. It exists to answer five questions and produce fixtures. Keep the Kotlin; throw away the rest.

| Check | Pass condition | If it fails |
|---|---|---|
| 1. Reply actions | WhatsApp, Messenger, Instagram, Telegram, Signal and Google Messages each post MessagingStyle notifications with a RemoteInput action, and a reply sent through it arrives in the chat | Any of the first three failing is a stop: the product is the reply |
| 2. Burst behaviour | Five messages in one chat and across three chats: every message text is recoverable from the children or the MessagingStyle history, not just "5 new messages" | Losing messages in bursts means the inbox lies; stop |
| 3. Survival | The listener still delivers after 24 hours on the OEM device with the app not opened | If it needs a settings change, that becomes an onboarding step; if it cannot be made reliable, stop |
| 4. Redaction | With a one-time code arriving, the listener receives redacted text and nothing crashes; ordinary messages are intact on the lock screen | Handle in code; not a stop |
| 5. Reply after dismissal | A reply through a `PendingIntent` held after the user dismissed the notification: does it still deliver, and for how long | Decides the "reply available" rule (REP), not a stop |

Also record: the conversation key each app provides (shortcut ID, conversation title, tag), whether work-profile notifications reach the listener, and what a photo or voice note looks like in the payload. Save one raw JSON dump per app per case; they become the fixture tests in PR 2. Write the results, dated, into what will be `docs/research/spike.md`.

Go/no-go is the end of week 1. Everything below assumes go.

## 6. PR by PR

Mapped to the kit's roadmap phases. Each PR is one theme, branches from a freshly pulled `main`, runs `/spec` for its area before code, cites the rule IDs it implements, ends with `/ship` and a `/release`, and waits open for review. Rule sketches below are drafts for `/spec` to make testable; the IDs are proposals, `/spec` assigns the real ones.

### PR 0: start the repo (kit Phase 0)

`/new-app` with the name, "Android first, nothing else", then `/kickoff` with the answers from section 2. In the same first commit: the CI `ios` and `desktop` jobs deleted, `ALLOWED` in `release.yml` set to exactly what the scaffolded release build declares, read off a real `aapt2 dump permissions` rather than from this plan (it is empty: the scaffold declares none), and grown one permission at a time by the feature PR that needs it, the privacy policy's ads and purchase sections rewritten for Plus, `docs/research/spike.md` from week 1, and Notisave's row started in the competitor analysis. Tick Phase 0 and put the closed-test start date in the roadmap. Store paperwork begins the same day: developer account verified, store ID reserved, app record created.

Done when CI is green on a first PR and the store ID is reserved.

### PR 1: foundations (kit Phase 1)

Strict lints, the database with the version-1 schema above and the migration scaffold with its upgrade test, the six service interfaces with no-op fakes, localisation scaffolding with English only, and the write-first-then-notify provider pattern. No screens beyond a placeholder. Tests: model round trips, the first migration, provider write and rollback.

Done when a fake `NotificationSource` can feed a message through to the database in a test.

### PR 2: capture (Phase 2, first feature)

Rules to `/spec` first, area "Capture" (CAP): a message is stored once even if its notification is re-posted; a group summary is never stored; a conversation is keyed by app plus shortcut ID, falling back to conversation title; a removal by click or by the app marks the conversation read; redacted text is stored as redacted and never guessed; nothing is stored from apps the user excluded; a message the app cannot parse is kept as raw text under the app name rather than dropped.

The Kotlin listener from the spike, hardened: queue, reconnection, removal reasons, the `EventChannel`. The Dart normaliser and the fixture tests, one per app per case from the spike dumps, asserting what the user would see. A developer-only raw-notifications screen behind a long press in Settings, for field debugging.

Done when every fixture produces the expected conversations and messages, and a fresh install on the phone shows real messages arriving in the placeholder screen.

### PR 3: the inbox

`/spec` area "Inbox" (INB): conversations sorted by last message; unread count per conversation; the source app's icon on every row; a thread shows messages oldest first with the sender's name in group chats; tapping the app icon opens the source app on that chat; the empty state explains what will appear and why nothing has yet (RUN-1); a photo or voice note shows as a labelled placeholder that opens the source app.

Conversation list, thread view, per-app filter chips, Settings with the included-apps list. Widget tests for the three screens at phone size and 1.3× text.

Done when a day of real use is readable end to end without opening another app to understand it.

### PR 4: onboarding and permission

`/spec` area "Permissions" (PERM): the disclosure page appears before the system settings page every time the permission is missing, says what is read and that nothing leaves the phone, and has one button; refusing leaves an app that explains itself rather than a blank one; known messaging apps are pre-selected and everything else is off until chosen; the manufacturer-specific battery guidance appears once, from a detected list, with the exact settings path; `POST_NOTIFICATIONS` is asked only when the first snooze is set (RUN-3).

Prominent disclosure and consent, deep link to notification access, the return-from-settings check, the OEM page, the included-apps chooser.

Done when a new user reaches a populated inbox in under a minute on a Pixel and on the OEM device.

### PR 5: reply

`/spec` area "Reply" (REP): the reply field appears only when a reply action exists; a sent reply shows immediately as outbound and the conversation leaves the waiting list; a failed send restores the text and offers "open in app"; a reply action older than the period the spike measured is treated as gone; a thread without a reply action shows "open in app" in the same place, so the gesture is the same.

Native reply through `RemoteInput`, the in-memory action map with reconnection, optimistic outbound message, the failure path. Drive every path by hand on WhatsApp, Messenger and Instagram before the PR.

Done when a reply from the app lands in the real chat on all three, and the failure path never loses typed text.

### PR 6: triage: waiting on me, done, snooze

`/spec` areas "Waiting" (WAIT) and "Snooze" (SNZ): a conversation is waiting when its last message is inbound and it is neither done nor snoozed; done is one tap with a five-second undo and is undone automatically by the next inbound message; the three free presets and their exact times; a snoozed conversation returns to the top with a reminder notification from the app's own channel; reminders survive reboot; muted conversations never remind.

The waiting screen as the default tab, done and undo, snooze presets, the native alarm receiver and boot rescheduling.

Done when a snoozed thread comes back at the right time after a reboot with the app closed.

### PR 7: search and retention

`/spec` areas "Search" (SRCH) and "Retention" (RET): search covers sender, text and conversation title, ignores case and accents (LANG-4), and shows results grouped by conversation; free keeps 30 days and purges on launch; the purge never removes a conversation that is snoozed or waiting; "delete everything" wipes the database and the native queue and asks once; storage used is shown in Settings.

FTS table and normalised column, the search screen, the purge, delete-all, storage stats.

Done when a search for an accented name finds it typed without accents, and the purge test proves the exceptions.

### PR 8: app lock and first run

The kit's LOCK-1 to LOCK-3 as they stand; the walkthrough last (RUN-4), four pages at most, showing finished features. Lock hides content and the widget shows no private data (LOCK-2 already says so).

Done when lock, background timeout and the no-biometrics fallback each have a test and were driven by hand.

### PR 9: store readiness (Phase 3) and the closed test

Display name everywhere, icons and splash from one committed source, the full privacy policy (permissions listed with what still works if refused, no ads section, Plus described as coming), `LICENSE`, the listing text and screenshots under `store/play/`, Data safety answers (no collection, no sharing), and the release workflow's permission check passing against a real build.

Then internal testing from a release, and the closed test starts. Recruit the 12 testers now if the account needs them; the clock is 14 continuous days.

Done when the closed test is running and the first week of tester feedback is in the roadmap's known bugs.

### PR 10: languages (Phase 4)

The kit's LANG-1 to LANG-6. Ship the languages your other apps ship; right-to-left is already handled in the stack notes. Every later PR adds all languages as it goes.

### PR 11: the Plus purchase

`/spec` area "Plus and paying" (PAY, replacing the kit's ads rules): one non-consumable product; the store is asked what is owned at every launch (PAY-1 as written); prices from the store (PAY-2); nothing sold before it exists (PAY-3), so this PR ships with at least unlimited history working; nothing free moves behind it (PAY-4); selling is quiet: one row in Settings and a small "Plus" tag on locked features, no interstitial, no countdown (PAY-5); every purchase outcome, including the sheet closing, leaves the app consistent (PAY-6 and the stack notes' `in_app_purchase` traps).

`Entitlements` service over `in_app_purchase`, the Plus screen, restore, gating helpers, and unlimited history as the first Plus feature. Licence testers on the internal track buy it for real.

Done when a licence tester's purchase, refund and restore each land without a reinstall.

### PR 12: Plus: rules and quiet hours

`/spec` area "Rules" (RUL): VIP senders always notify and float to the top; keyword alerts fire once per message; mute by sender or conversation stops reminders and the waiting list but keeps capture; quiet hours per app hold reminders until they end; rules that need an instant reaction are evaluated in the listener from the exported set, everything else in Dart.

Done when a VIP message alerts with the app closed and a muted chat never does.

### PR 13: Plus: widget, nudges, export

Home-screen widget with the waiting count and the top three names, updated by Dart and bumped by the listener; nudges ("unanswered for 24 hours", chosen per user); export and backup to a file the user picks (BAK-1 to BAK-5 as written, including the automatic backup before restore).

Done when the widget survives a force stop and an export restores onto a clean install.

### PR 14: Plus: on-device intelligence, optional

Summaries of a long thread and reply drafts through ML Kit's GenAI APIs on devices that have Gemini Nano, over a platform channel, opt-in, and absent without a trace on devices that lack it. The older on-device Smart Reply API can give three suggested replies on any device in English. Nothing here touches the network, so the permission list does not change; verify that against the built artifact.

Done when the feature is invisible on an unsupported device and useful on a supported one.

### Production (Phase 5)

Closed test finished and production access applied for, EU trader status if it applies, release notes in every language, then promote. Then the kit's Phase 8: read the crash figures and reviews before starting the next item, and put the target API deadline in the roadmap.

## 7. Timeline

One developer, full weeks. Estimates, not commitments.

| Weeks | Work | Milestone |
|---|---|---|
| 1 | Spike | Go/no-go |
| 2 | PR 0, PR 1 | Repo, CI green, store ID reserved, paperwork started |
| 3 to 4 | PR 2, PR 3 | Real messages in a readable inbox |
| 5 | PR 4, PR 5 | A stranger can install it and reply |
| 6 to 7 | PR 6, PR 7 | Triage and search complete: the free product |
| 8 | PR 8, PR 9 | Closed test starts |
| 9 to 10 | PR 10, PR 11 | Languages, Plus purchasable with unlimited history |
| 11 to 12 | PR 12, PR 13 | Plus worth its price |
| 13 | PR 14 if wanted, launch prep | Production application after the 14-day test |
| 14 | Launch | Public on Play |

About a quarter to a paid launch. The closed-test clock is the item that cannot be compressed, which is why store paperwork starts in week 2.

## 8. What success looks like, and when to stop

Targets are guesses to be replaced by the first month's numbers, not promises.

| Measure | Target | Read it from |
|---|---|---|
| Notification access granted after install | 70% | The app's own first-run counter, on device, shown in Settings for debugging only |
| Users who send a reply from the app in the first day | 40% | Same |
| Retained after 7 days | 30% | Play Console |
| Retained after 30 days | 15% | Play Console |
| Crash-free sessions | 99.5% | Play Console |
| Plus conversion among 30-day actives | 2% to 5% | Play Console |
| Capture complaints per app per week | Trending to zero | Reviews and the support address |

Stop signals after launch: retention after 7 days under 15% after the second release, or a Play policy action that cannot be answered with disclosure changes.

## 9. Risks

| Risk | Mitigation |
|---|---|
| A messaging app changes its notification shape and capture breaks | Fixture tests per app from real dumps; the raw fallback keeps text visible under the app name; a same-week patch release is the kit's normal cadence |
| Android restricts listeners further | Redaction is already handled as a state; watch each Android beta's behaviour-changes page; the product degrades to "open in app" rather than failing |
| OEM battery management kills the listener | The detected-manufacturer guidance in PR 4; the spike's 24-hour survival test on a real OEM device before anything else is built |
| Reply actions go stale | The measured validity period drives the REP rule; the fallback is always "open in app" in the same spot |
| Play review questions the permission | Prominent disclosure, consent, on-device-only processing, a public repo, and the Play Protect guidance's own wording in the listing |
| Users expect full chat history and one-star it | The listing and the empty state say what the app cannot see before they find out |
| Beeper or Google ship the same thing | Speed, and a story neither can tell: no account and no internet permission |
| Captured text outlives a message the sender deleted | A known consequence of the design, not a feature to market; decide the retention rule with that in mind and say so in the privacy policy |

## 10. After v1

- A real Telegram client over TDLib inside the same inbox, since Telegram sanctions third-party clients: full history and search for the one network that allows it.
- A yearly subscription beside the one-time purchase, decided from the first quarter's numbers.
- Tablet and foldable layouts.
- Never iOS: say it in the FAQ so nobody waits for it.

## 11. How to start

_Decision, 2026-09-21: the repo was created first, before the spike. `/new-app` and `/kickoff` ran on 21 September 2026 (step 2 below), so the week-1 spike of section 5 runs as the first PR inside this repo and writes its results to `docs/research/spike.md` here. Go/no-go is unchanged and still gates everything after it: nothing in section 6 beyond PR 0 starts until the spike passes._

1. Run the week-1 spike and write `spike.md`.
2. On go, from the kit's folder: `/new-app` with the chosen name, "Android first, nothing else". It creates `D:\Desktop\projects\<name>` and runs `/kickoff` there. Answer with section 2: the principles, no ads, the store ID, public or private, Notisave as the competitor.
3. Put this file at `docs/PLAN.md`, the analysis at `docs/research/feasibility.md`, and the spike results at `docs/research/spike.md` in the first commit.
4. `/spec Capture`, then PR 1.
