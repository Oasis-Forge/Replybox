---
title: Privacy Policy – Replybox
---

<!-- Update this page whenever a feature changes how data is stored or shared. This draft is not legal advice.
     CAP-27 makes that a merge condition for a capture PR, which is why the wording here is held to what the
     code does and not to what the rules say it should do: where the two differ the page says so plainly
     (product principle 3) and docs/ROADMAP.md carries the bug. Claims traced this round, 21 September 2026 —
     dedup and its residual (CAP-5, CAP-8, CAP-9: lib/models/message.dart dedupHash, lib/db/repository.dart
     _claimStoredRow), redaction on the raw path (CAP-21, CAP-8: lib/capture/ingest.dart _isRawHidden), the
     queue's 30-day sweep (CAP-15: ReplyboxListenerService.onCreate), the apps file (CAP-1, INB-20:
     CaptureStore), and the reply action (CAP-14: NotificationProjection.hasReplyAction, ReplyActions).
     Re-checked 21 September 2026 after the device drill, against the tree and not against the rules.
     (a) The app's account of when capture was on (CAP-12, PERM-8). The drill found 30 session rows all
     open and installed_at never written. Both fixed in the same round and re-read here afterwards:
     Repository.openCaptureSession refuses a second row while one is open;
     Repository.closeOpenCaptureSessionsAtLastEvidence closes what the last run left behind at the newest
     sent_at captured inside the session, called from AndroidCaptureService.closeSessionAccessTookAway on
     the launch path; lib/main.dart calls Repository.installedAt once at launch. The page now says the
     end of a stretch is an estimate that can only under-state, which is what that code produces, and
     stops implying the app is told when access goes away — it is not.
     (b) Dedup (CAP-5). _claimStoredRow leaves sent_at out of the match for a time_source='post' row (the
     re-post duplicate the page used to name: fixed), and insertMessagesIfNew now takes a position pass
     for a time_source='entry' row below the newest line in its history, which is the moving entry clock
     the drill observed. insertMessageIfNew deliberately does not take that pass, so a one-message
     notification re-posted with only its own time changed still leaves a second row. That residual is
     the one exception the page states; it is a choice, not a bug, and the reasoning is on
     insertMessageIfNew.
     23 September 2026 — package visibility (Decision 13, INB-16, INB-20, INB-13). The manifest's <queries>
     gains a launcher intent filter, so every launchable app on the phone becomes visible to this build, and
     "Open in app" works for every app rather than only the shipped six. This page could previously imply
     that the app cannot see the device's app list, and the manifest was the proof; it no longer is. Three
     sentences changed and one bullet is new, all in "What Replybox can and cannot see", plus the second
     Permissions bullet and the Apps storage bullet. What the page now claims is narrower than what Android
     grants and is enforced by a test rather than by the platform: the app asks the package manager about one
     package at a time, only for a package with an `apps` row (one that has posted a notification) or one of
     the six in lib/data/shipped_apps.dart, and calls no API that returns a list. Nothing else on the page is
     affected: no new permission, no new stored field, and the apps file and `apps` table are still written
     only from packages that actually posted.
     Re-traced against the tree, 23 September 2026, before the PR — which is what this note previously said
     it had not done. It was written from the decision and the rules, which is the one thing CAP-27 says not
     to do, and it cited two gates that do not exist: "SourceAppInfo.lookup's gate on ShippedApps.PACKAGES"
     (shipped only) and "lib/services/android_package_service.dart's gate on isShippedMessagingApp" (a gate
     that file does not have, and deliberately does not have). What the code does is this page's claim, and
     neither citation was it. The gate is SourceAppInfo.mayAsk
     (android/app/src/main/kotlin/com/oasisforge/replybox/capture/SourceAppInfo.kt):
     `packageName in ShippedApps.PACKAGES || hasPosted(packageName)`, where hasPosted is
     CaptureStore.hasEverSeen, the record the listener writes before CAP-1's drop — shipped OR posted, not
     shipped alone. SourceAppInfo.lookup returns through mayAsk before PackageFacts.faceOf touches the
     package manager, and AppLaunch.openApp applies the same call to the same record, so both routes to the
     phone are one rule in one place. The Dart service holds no copy of that gate, on purpose: a second
     answer to "has this package posted?" would be a second authority and the one that drifts, so it asks
     the channel for one named package and caches only resolved answers. <queries> in AndroidManifest.xml
     carries the Flutter engine's PROCESS_TEXT intent, one MAIN + LAUNCHER intent and the six <package>
     entries, and nothing else. Enforcement is tests plus one build gate: SourceAppInfoTest and AppLaunchTest
     on mayAsk, QueriesDeclarationTest on the source manifest, test/package_visibility_test.dart on the two
     claims this page makes — no enumerating call anywhere in the source (getInstalledPackages,
     getInstalledApplications, getInstalledModules, queryIntentActivities), QUERY_ALL_PACKAGES named
     nowhere, and one channel method carrying one package name — and tool/check_queries.sh on the built
     manifest from release.yml. One residual is not on the page, because it is a wrong sentence on a row
     rather than a privacy claim: an app still installed that has posted and has no launcher activity is
     invisible to this build and is reported gone (INB-16, which states it, as does SourceAppInfo).
     Re-reading the whole page against the tree this round found what the visibility work had hidden: three
     "Not yet shipped" markers the inbox had made false. lib/main.dart now opens InboxScreen, with
     ThreadScreen and IncludedAppsScreen behind it, so the Summary's "a single placeholder screen", the
     included-apps half of the first see/cannot-see bullet, and the delete section's claim that uninstalling
     is the only way to remove what was captured were each describing the app as it stood two days ago. All
     three are corrected below. Replying, the disclosure screen, the first-screen capture notice, deleting a
     single message, scheduled retention, export, app lock and Plus are all still unshipped and still
     marked.
     23 September 2026, second pass — permissions and onboarding (PERM-1 … PERM-17), for which PERM-16 makes
     this page a merge condition the way CAP-27 does for capture. Two of the markers the note above left
     standing are now false, and both were false in the same way: they described an app in which this area
     does not exist. Three claims are corrected.
     (i) The Permissions section said twice that nothing inside the app explains capture or sends you to the
     system page, and that the screens doing so were still being built. They are built.
     lib/screens/disclosure_screen.dart is the only call site of PermissionsProvider.openAccessSettings in
     lib/; lib/main.dart pushes it on the first launch and routes PERM-8's banner action to it rather than to
     the system page; lib/screens/included_apps_screen.dart carries the rows that reach it, PERM-14's battery
     page and lib/screens/privacy_policy_screen.dart.
     (ii) "The end of a stretch is an estimate" was true of the code as it stood and is now one of two
     branches. PERM-9 writes the loss down at the moment it is observed and records which observation it was:
     a reported disconnection closes the row inside that callback with that callback's time and the banner
     says "since"; a loss found on a resume closes it at the last event the listener delivered, flags it as an
     estimate, and the banner says "since at least" (captureOffSince, captureOffSinceAtLeast,
     captureNeverOn in lib/l10n/app_en.arb). The page said only the second, so it under-stated what the app
     can honestly tell you.
     (iii) Decision 13's package-visibility change was on this page and nowhere on screen. It is on screen
     now, in the app's own copy of this policy, as privacyPolicyPackages, and this page says so rather than
     leaving a reader to assume the app is silent about it.
     Two claims were also weaker than the truth, which is what PERM-16 leaves implicit. The rule permits a
     control that opens the hosted copy "on the condition that it is labelled as opening a browser and
     leaving the phone"; there is no such control, and nothing in lib/ can open a URL at all.
     PrivacyPolicyScreen.onOpenHosted is null at every call site, lib/services/services.dart has no seam that
     could open one — AppLauncher opens a package and a notification's own chat, SystemSettings opens
     PERM-14's two system pages — and the hosted address is a SelectableText beside them. So the
     unconditional claim is available and is now made: nothing in the app leaves the phone. The Contact
     section's line that the GitHub link "is the only thing in the app that does" was the casualty of that;
     it is a link on this web page and the app has never carried it.
     What this pass does NOT claim. On 23 September 2026 a debug-signed release APK of 0.2.0, built from main
     at 185425a — the Inbox merge, with none of this area in it — was installed on a physical Android phone,
     the first time any of this has run off an emulator. Notification access was granted by hand on the
     system's own page, a real WhatsApp notification was captured, and it was drawn as a row in the inbox.
     Before the grant the app captured nothing and said nothing whatsoever about why; the user reached the
     right system page only because they were told which one it was. That is this area's justification,
     observed rather than argued, and it is the one thing on this page that has been seen on hardware.
     Nothing else was: not the thread, the swipe or its Undo, the filter chips, the chooser, right-to-left,
     1.3x text, a reply — and not one of the screens this pass describes. Everything written below about the
     disclosure, the banner's two branches, the not-running line, the quiet line, the battery page and the
     in-app policy is read off the tree and the tests, and the Permissions section says so in those words
     rather than letting a reader assume a phone confirmed it.
     PERM-16's script is scripts/check_policy_claims.sh, wired into ci.yml beside scripts/check_public_docs.sh.
     It fails when the three sentences quoted under "The same words, in the app" stop matching
     permissionsDisclosureReads, permissionsDisclosureAppsExplainer and permissionsDisclosureStaysHere in
     lib/l10n/app_en.arb, in either direction. Quote them exactly; paraphrasing them here is the drift the
     rule exists to stop, and a second wording of a claim is a second thing to keep true. -->


# Privacy Policy

_Last updated: 23 September 2026_

This policy explains how the **Replybox** app ("the app") handles your information. It covers the app on Android, which is the only platform it runs on.

Replybox is in development, and this page is dated. A section describing something the app does not do yet says so.

## Summary

**Almost nothing leaves your device.** Replybox reads the notifications your other apps post and keeps them on your phone. One inbox to see them in, and answering from there, are what it is being built for — **the inbox is here, and answering is not shipped yet**, so today the app captures in the background and shows you what it captured, and there is no reply box in it anywhere. Everything it stores stays on your phone: there is no account, no sign-in, no server of ours, no analytics and no crash reporting, and **the release build does not request the internet permission at all**. Nothing in the app opens a browser either: it carries a privacy policy of its own that needs no connection to read, and the address this page is published at is shown there as text you can copy rather than as a link that would take you out. The one thing that ever leaves is a reply you send, and Replybox does not send it — it hands the text to the app the message came from, and that app sends it, exactly as if you had typed it there. **Replying** below says what that means.

**There are no ads.** Not in any build, not anywhere in the app, and there never will be.

**Most of what Replybox holds was written by other people.** That is unusual, and it is the reason this page is longer than it would otherwise be. Messages your friends sent you are their words, not only your data, and the app is built so that they never reach anyone but you.

Your phone's own automatic app backup is **switched off for this app**, so Android never copies your messages to Google Drive on its own.

## What Replybox can and cannot see

This matters more than the usual promises, so it is near the top.

- **Six apps are included from the start.** WhatsApp, Messenger, Instagram, Telegram, Signal and Google Messages begin capturing the first time each of them posts a notification, without you naming them, so the inbox is not empty when you first open it. Every other app on your phone stays off until you switch it on. Replybox is not connected to any of these apps and has no access to their own storage — it only sees what they put on your screen. The list where you switch an app on or off is here, and it also removes everything already captured from one app. All six are also named on a screen of the app's own, shown before it sends you to Android's notification-access page and never after it, with any you do not have installed marked as missing — so nothing is captured from an app you were not told about first. Withdrawing notification access is what stops capture altogether — see **Permissions**.
- **It can see which apps on your phone have an icon you could tap.** That is what makes *Open in app* work for every app you can open from your home screen, and not only the six above: to open an app, Android has to let this one see it first. It is not a permission — there is nothing here for you to grant or refuse, and it appears in no permission list — so what matters is what the app does with it, and that is narrower than what it is allowed to do. **Replybox only ever asks Android about an app that has already sent you a notification**, one app at a time and by name, and it never asks for a list of what is on your phone. The six apps above are the one exception: they are named on this page and on screen before anything is captured, and the only thing the app learns by asking about them is whether you have them, which is what lets it tell you which of the six it can capture from. Nothing is looked up, stored or shown about an app that has never written to you — the list of apps you can switch on is built from the ones that have posted, never from what is installed. The app now says this in its own words too, on the copy of this policy it carries inside it, rather than leaving it to this page: that it can see which apps here can be opened, that it only ever asks about one that has already sent you a notification or one of the six, and that it never asks for a list of what you have installed.
- It sees a notification only **while the phone is showing it to you**. It has **no history from before you installed it**, none from any time notification access was switched off, and none from an app whose switch is off.
- When Android decides a message's contents are sensitive, it replaces the text before any app like this one is shown the notification — one-time passcodes are the case we have seen. Replybox is handed a placeholder instead of the text. Where the notification arrives with its title emptied — which is how every redaction we have tested arrives — the placeholder is not stored: the app records only that a message arrived, which app it came from and when, and offers to open that app. It never guesses what was hidden. A redaction that arrives with no title at all is indistinguishable from an ordinary untitled notification, and is stored as one, placeholder text included, where search would find it. On the Android versions we have tested, no setting in this app and no setting on your phone can turn that off. What Android hides has changed from one Android version to the next, so on an older phone more may reach Replybox than on a new one.
- If someone edits, unsends or deletes a message in the app that sent it, Replybox is never told. What it stored can therefore **differ** from what that conversation now shows: an edited message still reads here as it first arrived, and an unsent or deleted one is still here.
- It cannot speak for a **work profile** or a second user on the phone. Nobody has yet tested whether notifications from a work profile reach an app like this one at all, so the app makes no claim either way.
- It cannot start a new conversation, and apart from which of your apps have an icon — the second bullet above — it can see nothing about your phone that you were not notified about.

## Replying

When you answer from Replybox, the app does not send your message and could not: it has no internet access. It hands the text you typed back to the app the notification came from — WhatsApp, Messenger, Instagram, Telegram, Signal or Google Messages — through the reply button that app attached to its own notification. That app then sends it to the person you are answering, over its own connection and under its own privacy policy, exactly as if you had typed it there. What happens to it after that is between you and them.

Replybox is never told whether it arrived, and it never shows you a delivered or read mark, because it holds no receipt from the other app.

It keeps a copy of what you typed, on your phone, in the same inbox, so the thread reads as a conversation.

Answering in place only works while your phone is still holding that notification. After a restart, or once the notification is long gone, there is no reply box at all: the app offers to open the original app instead, and nothing you typed is passed to it. That offer now works for every app you can open from your home screen, not only the six above. For the rare app with no icon of its own there is nothing to open, and the app says so in place of the button rather than giving you one that cannot work.

**Not yet shipped.** Replying is the next thing being built.

## What Replybox never does to your notifications

Notification access is a powerful thing to grant, so here is what Replybox does not do with it.

It reads your notifications; it does not touch them. Reading a message in Replybox leaves that notification sitting in your shade exactly where it was. The app never dismisses, hides, alters or posts another app's notification unless you asked for that action on that conversation — and the only two actions it ever takes are the ones you tap: opening the other app, and sending a reply through it.

## Information stored on your device

The app stores, in a database on your phone:

- **Messages**: the sender's name, the text, the time the sending app gave it, the time it reached Replybox, which conversation it belongs to, where the message sat in the list of messages that notification carried, and what kind of thing arrived — ordinary text, a message your phone hid, a photo, a voice note, a video, something the app cannot name, or a notification it could not read as a conversation. **Replies you send from Replybox will be stored the same way, marked as yours,** so the thread reads as a conversation (**not yet shipped** — see **Replying**). It also stores the identifier Android gave the notification the message arrived in, and a one-way fingerprint of the text, so a message that reaches the app twice — the same notification posted again, or re-read when the app reconnects — is recognised and not stored a second time. That recognition uses the time the sending app gave the message, alongside the sender and the fingerprint; where the sending app gave no time at all — a message your phone hid, or a notification the app could not read as a conversation — the app matches on the notification and the message's position in it instead, and leaves time out of it entirely, so those are no longer stored again each time the notification is refreshed. A sending app that **changes** the time it gave a message between two postings of the same notification is handled too — we have seen one do exactly that, posting the same notification twice half a second apart and moving the time on the reply the phone's owner had just written — by matching on where the message sat in that notification instead. That last match is not applied to the newest message a notification carries, because there the app cannot tell a message whose time moved from the next message arriving in its place, and storing a real message twice is a smaller harm than losing one. So the honest form of this is: **the same message is not stored twice, with one exception we would rather have than its alternative** — a notification carrying a single message, re-posted with nothing in it changed but its own time, can leave a second copy. For a message Android hid, no text is stored at all — only that it was hidden, which app it came from, and when it arrived.
- **Conversations**: the app they came from, the identifiers that app used to tell one thread from another, the thread's title, and when you last read it.
- **Apps**: the name and package of each app that has posted a notification the app saw, and whether it is switched on. An app you have *not* switched on gets a row holding its name, its package and when it last posted — and nothing else, so it can be offered to you in the list. Nothing it posted is kept: no title, no sender, no text. This list is built only from apps that have actually posted a notification, plus the six named above — never from what is installed on your phone.
- **Items you delete**, which stay in the app's trash so you can restore them. Nothing is removed on a schedule today, so they stay there until you uninstall the app. The fingerprint of a deleted message stays with it, so a message you deleted is not brought back by the notification that carried it arriving again — with the same exception as above.
- **A search copy**: a simplified version of each message's text, its sender and the conversation's title, so search can ignore capital letters and accents.
- **When the app could see anything**: the date you installed Replybox, a row for each stretch during which the part of the app that reads notifications was running, and a row each time one of your apps is switched on or off. It keeps these so a thread can tell you honestly that it has a gap, instead of looking as though the conversation simply went quiet. **How a stretch ends is one of two different facts, and the app tells you which of them it has.** Where Android tells the app that its listener has been disconnected, that is recorded as it happens, and the app says capture has been off *since* that time — an exact one. Where it is not told — and on the version we have tested, withdrawing notification access simply shuts the app down with no notice — there is nothing to record at the moment it happens. The loss is then found the next time you open Replybox, which cannot know when it actually happened, so it closes the stretch at **the time of the last message it actually received**, never at the time it noticed, and marks it as an estimate: the app says capture has been off *since at least* that time. The wording is the difference, and it is there so you can tell one from the other. Where it is estimating, it can only under-state how long it was working and never over-state it, and it will never claim it was on during a period it cannot show you a message for. Where access has never been granted at all since you installed the app, there is no closed stretch to date the gap from, and it says that instead, naming the day you installed it.
- **Your settings**, such as which apps are included and whether app lock is on. Three of them are marks about what the app has already said to *you*, so that it does not say it again: that the permission screen has been displayed, that the battery page has been shown its one time, and when it last showed the line about nothing having arrived. Each records only that something was shown, and never what you answered — declining on the permission screen writes nothing at all.

Beside the database, the part of the app that reads notifications writes two files, both in the app's own private storage:

- **A hand-over queue.** Every notification it captures is written here first, as one line holding the same fields the database keeps — sender, text, time and the rest — because a notification can arrive while the rest of the app is not running. The line is deleted as soon as the app has stored the message. A line the app never came back for is dropped once it is more than 30 days old — but that sweep runs when Android starts the part of the app that reads notifications, not on a clock, so where that part keeps running for months an older line stays until the next start.
- **A list of apps that have posted.** The package name of every app that has posted a notification while Replybox was watching, and which of them capture is on for. An app the database has not been told about yet also keeps its name and when it last posted here, until it is handed over; after that the package name is all that is left of it. Nothing any of them posted is kept here: no title, no sender, no text.

It deliberately does **not** store the notification itself, its icons, the sender's profile picture, the app's own notification settings, or the buttons the notification carried. Of those buttons one fact is kept, in the hand-over line above: whether the notification carried a reply button at all. The button itself is held in memory for as long as the part of the app that reads notifications keeps running, and is never written down — which is why answering in place stops working after a restart.

Beyond what is listed above, the only extra things it keeps are the bookkeeping it needs to recognise a message it has already stored: the identifier Android gave the notification, where the message sat in it, and a one-way fingerprint of the text. Where there is no text to fingerprint, the fingerprint is made from whatever the app was told instead — for a photo, a voice note, a video or something it cannot name, the kind of thing that arrived, which is all it was told; for a message your phone hid, which carries nothing at all, the notification's identifier and the message's position in it. A fingerprint cannot be turned back into the message.

The developer has no access to any of it.

## Information we collect

**The app collects nothing.** There is no account, no sign-in, no analytics, no crash reporting and no advertising, and there is no server of ours for anything to be sent to. The developer cannot see your messages or your usage. Because the release build has no internet permission, the app cannot reach the internet by itself at all — the only text that ever goes anywhere is a reply you choose to send, and it goes to the app that message came from, not to us.

## How long messages are kept

Messages are not kept forever. The free app is planned to hold 30 days of history, after which a message is removed from your phone automatically — and where that happens the thread says so, rather than simply appearing to start late. Plus will remove that limit and keep them until you delete them.

**Not yet shipped.** Nothing is deleted on a schedule today. This section will say exactly what the window is, and when it starts counting, in the release that first applies one.

## How your messages are kept safe on your phone

The database, the hand-over queue and the list of apps all sit in Replybox's own private storage, which Android keeps other apps out of, and they are protected by whatever screen lock and disk encryption your phone already uses. The app adds no encryption of its own, so anyone who can unlock your phone can read the inbox — turning app lock on is what stops that.

## Permissions

- **Notification access** is what the app is for, and it is the one thing it asks of you. It is not an ordinary permission: Android grants it on its own screen, under **Settings → Apps → Special app access → Notification access**, so it never appears in the app's permission list on the store page. With it, Replybox can read the notifications your other apps post — which, for messaging apps, means the messages themselves.

  **Before it sends you to that screen, the app says in its own words what it is asking for.** What it reads, what it does with it, that it stays on this phone, what it still cannot see, and that you can withdraw the grant at any time — and it names all six apps it captures without being asked, in full, marking any you do not have installed. That screen is the only route inside the app to Android's own notification-access page: nothing else in the app opens it, and the banner below sends you to that explanation rather than straight to the system. It is not a gate. Declining is one tap, it leaves you in an app that works, and nothing is written down when you do.

  **Without access, nothing new can arrive, and the app says so on its first screen. Everything else still works:** the inbox, search, the app chooser and the app's own policy page stay open, nothing is greyed out, no screen is replaced by a permission wall, and anything already captured stays readable, searchable and deletable. You can withdraw access at any time on that same Android screen; the app then says on its first screen that capture is off, and since when — *off since* a time where Android told it, *off since at least* a time where it had to work it out afterwards, and where access has never been granted at all, that capture has never been on, naming the day you installed the app rather than a time it does not hold (see **When the app could see anything** above).

  Two further lines can appear in that same place, and each is worded as exactly what it is. Where access is granted but the app's own listener is not connected, it says capture is not running right now. Where the listener is connected and nothing whatsoever has arrived for a day, it says when something last did, and that this may be perfectly normal — an observation you can dismiss, not an error, because a listener that quietly died and a phone nobody has messaged look identical from in here and the app will not guess between them. **It never tells you the reverse: it will not claim capture is working, only when it last received something.**

  Once, after the first screen has been drawn and never in place of it, the app also offers a page about the battery settings that stop background apps. It names settings pages to look at and prints the manufacturer your phone reports, and it says plainly that nobody has yet measured whether any of those settings keeps this app's listener alive on any phone. It states nothing about what any named make of phone does to this app, changes no setting itself, and asks for no battery exemption. The manufacturer is read while the page is on screen and is not stored.
- **Nothing else — today.** The release build asks for no permissions of its own: in particular **no internet**, no contacts, no SMS, no storage, no location, no camera and no microphone. (Android's build tools add one internal marker permission scoped to the app itself; it grants access to nothing.) A build of the app is checked automatically on every change to main, and the build fails if a permission appears that is not listed here. A permission will be listed here, with what it is for and what still works without it, in the same release that first requests it.

  Seeing which of your apps have an icon is not a permission either — it is a declaration in the app's manifest, it needs nothing from you and appears in no permission list — so this is the place to say that the app does not ask for `QUERY_ALL_PACKAGES`, the permission an app needs before it can read the whole list of what you have installed. The build is checked for that one by name, and fails if it ever appears. What the app does with the visibility it does have is the second bullet of **What Replybox can and cannot see** above, and that limit is one the app keeps for itself rather than one your phone enforces.

**Shipped, and not yet seen on a phone.** The screens the first bullet describes are in the app and are covered by tests. What has been observed on real hardware is one thing and it is worth stating exactly: on 23 September 2026 a build of the app was installed on a physical Android phone for the first time, notification access was granted by hand on Android's own screen, and a WhatsApp message was captured and appeared in the inbox. That build was made before any of these screens existed — with access off it captured nothing and explained nothing, which is why they were built — so everything described above has been read off the code and the tests and not yet watched on a phone. This paragraph will say otherwise on the day it is.

## The same words, in the app

The app carries a privacy policy of its own, reachable from the included-apps list. It is shorter than this page — what is stored, what the app asks your phone about, what leaves it, and what deleting does — and every sentence of it is translated with the rest of the app, so opening it makes no network request. That is the only way it could work at all, since the release build cannot make one. This page is the fuller published version of the same account, and the app prints its address so you can find it; the two are kept in step by hand, except for the three sentences below, which are kept in step by a check.

**Nothing in the app opens a browser, and nothing in the app leaves your phone.** There is no link anywhere in it. The address this page is published at is shown there as text you can select and copy, and that is a decision rather than an omission: a control that opened it would be the one thing in the app that left the device, and there is not one. The GitHub link at the foot of this page is on this web page, not in the app.

Three of the claims above are not a second wording of what the app says — they *are* what the app says. These are its own sentences, from the screen it shows before asking you for notification access, quoted here exactly as they appear there:

<!-- claim: permissionsDisclosureReads -->

> Replybox reads the notifications the apps below post: who sent a message, what it says, when it arrived, and which conversation it belongs to.

<!-- claim: permissionsDisclosureAppsExplainer -->

> These apps are captured as soon as they post a notification, without you naming them. Included apps turns any of them off.

<!-- claim: permissionsDisclosureStaysHere -->

> Everything stays on this phone. There is no account, no server and no analytics, and this build has no internet permission at all.

"The apps below" and "these apps" are the six named in **What Replybox can and cannot see** above; on that screen they are the list printed underneath. If any of these three sentences ever changes in the app and not here, or here and not in the app, a check on every pull request fails and names which of them drifted, and in which direction. That is the whole reason they are quoted rather than retold: a claim written twice is a claim that only has to be kept true once.

## Backups

Android's automatic cloud backup is **switched off for this app**, and your messages — the database that holds them, and the two files described above — are excluded from device-to-device transfer as well. Your messages are not copied to Google Drive, and a new phone does not receive them. Reinstalling therefore starts you with nothing.

**Not yet shipped.** There is no export and no backup you can ask for: apart from the database and the two files above, the app writes nothing.

## App lock

App lock is optional and off by default. When it is on, the app asks your device's operating system to check your fingerprint, face or screen lock. The app never receives or stores your biometric data or your screen lock code; it only learns whether the check succeeded. With app lock on, message contents are not shown in the app's own notifications, in a home-screen widget if the app ever offers one, or in the preview Android shows in the recent-apps switcher.

**Not yet shipped.**

## Paying

A one-time **Plus** purchase will unlock extra capabilities. It is not a subscription.

- The payment is handled entirely by **Google Play**. The app never sees or stores your card, your address or your name; it asks the store only whether this purchase is owned by the account signed in on the device.
- There is no server of ours involved and no account to create. Because the store keeps the receipt, "Restore purchases" brings it back on a new phone or after a reinstall.
- Nothing that already works will move behind a payment. The inbox, replying, the waiting list and search stay free.

**Not yet shipped.**

## Deleting your information

We hold nothing of yours to delete: none of it ever reaches us. The only thing the developer ever receives from you is what you choose to put in an email or a GitHub issue, and that is kept only as long as it takes to answer you.

On your phone: deleting a conversation takes it and its messages out of the inbox at once, with about five seconds to undo. They sit in the app's trash — still on your phone, but out of the inbox, out of search and out of every count. Nothing is removed on a schedule today, so what is in the trash stays there. Uninstalling the app removes everything it stored, trash included. Because automatic backup is off, nothing of it is left in your Google account.

Deleting a message in Replybox does not delete it from the app it came from, and deleting it there does not remove it here.

**Partly shipped.** Deleting a conversation is here — swipe its row in the inbox — and so is removing everything captured from one app, in the included-apps list. Deleting a single message is not built yet, and neither is a "delete everything"; for those, uninstalling is still the only way.

## Other people's messages

The people who wrote to you did not install this app, so a word about them.

Their messages are stored only on your phone, are never uploaded, and are never shown to anyone but you. The app does not build a profile of them, does not store their profile picture, and does not link what they sent across different apps. If you delete a conversation or uninstall Replybox, what they sent goes with it.

## Children

The app is a general-purpose tool, is not directed at children, and we do not knowingly collect anything from them. We collect nothing from anyone.

## Changes to this policy

Any changes will be posted on this page with a new "Last updated" date. A change to what the app stores is meant to update this page in the same pull request that makes it.

## Who publishes the app

Oasis Forge publishes the app. That is the name on the store listing.

## Contact

Email [oasisforge.support@gmail.com](mailto:oasisforge.support@gmail.com) for support or privacy questions.

You can also [open an issue on GitHub](https://github.com/Oasis-Forge/Replybox/issues). That link is on this web page and nowhere in the app: nothing in the app opens a browser, and the app's own policy page carries no link of any kind. Issues are public and stay public, so please don't paste a message, a sender's name, or a screenshot of your inbox into one: those are other people's words, and they never agreed to be there. Email instead if you need to show me what you saw.
