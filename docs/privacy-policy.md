---
title: Privacy Policy – Replybox
---

<!-- Update this page whenever a feature changes how data is stored or shared. This draft is not legal advice. -->

# Privacy Policy

_Last updated: 21 September 2026_

This policy explains how the **Replybox** app ("the app") handles your information. It covers the app on Android, which is the only platform it runs on.

Replybox is in development, and this page is dated. A section describing something the app does not do yet says so.

## Summary

**Almost nothing leaves your device.** Replybox reads the notifications your other apps post, shows them in one inbox, and lets you answer from there. Everything it stores stays on your phone: there is no account, no sign-in, no server of ours, no analytics and no crash reporting, and **the release build does not request the internet permission at all**. The one thing that ever leaves is a reply you send, and Replybox does not send it — it hands the text to the app the message came from, and that app sends it, exactly as if you had typed it there. **Replying** below says what that means.

**There are no ads.** Not in any build, not anywhere in the app, and there never will be.

**Most of what Replybox holds was written by other people.** That is unusual, and it is the reason this page is longer than it would otherwise be. Messages your friends sent you are their words, not only your data, and the app is built so that they never reach anyone but you.

Your phone's own automatic app backup is **switched off for this app**, so Android never copies your messages to Google Drive on its own.

## What Replybox can and cannot see

This matters more than the usual promises, so it is near the top.

- **Six apps are included from the start.** WhatsApp, Messenger, Instagram, Telegram, Signal and Google Messages begin capturing the first time each of them posts a notification, without you naming them, so the inbox is not empty when you first open it. The app tells you this on the same screen where it asks for notification access, before you grant it, and lists all six there. You can switch any of them off in Settings. Every other app on your phone stays off until you switch it on. Replybox is not connected to any of these apps and has no access to their own storage — it only sees what they put on your screen.
- It sees a notification only **while the phone is showing it to you**. It has **no history from before you installed it**, none from any time notification access was switched off, and none from an app whose switch is off.
- When Android decides a message's contents are sensitive, it replaces the text before any app like this one is shown the notification — one-time passcodes are the case we have seen. Replybox is handed a placeholder instead of the text, and it does not store the placeholder. It records only that a message arrived, which app it came from and when, and offers to open that app. It never guesses what was hidden. On the Android versions we have tested, no setting in this app and no setting on your phone can turn that off. What Android hides has changed from one Android version to the next, so on an older phone more may reach Replybox than on a new one.
- If someone edits, unsends or deletes a message in the app that sent it, Replybox is never told. What it stored can therefore **differ** from what that conversation now shows: an edited message still reads here as it first arrived, and an unsent or deleted one is still here.
- It cannot speak for a **work profile** or a second user on the phone. Nobody has yet tested whether notifications from a work profile reach an app like this one at all, so the app makes no claim either way.
- It cannot start a new conversation, and it cannot see anything you were not notified about.

## Replying

When you answer from Replybox, the app does not send your message and could not: it has no internet access. It hands the text you typed back to the app the notification came from — WhatsApp, Messenger, Instagram, Telegram, Signal or Google Messages — through the reply button that app attached to its own notification. That app then sends it to the person you are answering, over its own connection and under its own privacy policy, exactly as if you had typed it there. What happens to it after that is between you and them.

Replybox is never told whether it arrived, and it never shows you a delivered or read mark, because it holds no receipt from the other app.

It keeps a copy of what you typed, on your phone, in the same inbox, so the thread reads as a conversation.

Answering in place only works while your phone is still holding that notification. After a restart, or once the notification is long gone, there is no reply box at all: the app offers to open the original app instead, and nothing you typed is passed to it.

**Not yet shipped.** Replying is the next thing being built.

## What Replybox never does to your notifications

Notification access is a powerful thing to grant, so here is what Replybox does not do with it.

It reads your notifications; it does not touch them. Reading a message in Replybox leaves that notification sitting in your shade exactly where it was. The app never dismisses, hides, alters or posts another app's notification unless you asked for that action on that conversation — and the only two actions it ever takes are the ones you tap: opening the other app, and sending a reply through it.

## Information stored on your device

Once capture ships, the app stores, in a database on your phone:

- **Messages**: the sender's name, the text, the time the sending app gave it, the time it reached Replybox, which conversation it belongs to, and what kind of thing arrived — ordinary text, a message your phone hid, a photo, a voice note, a video, a file, or a notification the app could not read as a conversation. **Replies you send from Replybox are stored the same way, marked as yours,** so the thread reads as a conversation. It also stores the identifier Android gave the notification the message arrived in, and a one-way fingerprint of the text, so the same message is never stored twice. For a message Android hid, no text is stored at all — only that it was hidden, which app it came from, and when it arrived.
- **Conversations**: the app they came from, the identifiers that app used to tell one thread from another, the thread's title, and when you last read it.
- **Apps**: the name and package of each app that has posted a notification the app saw, and whether it is switched on. An app you have *not* switched on gets a row holding its name, its package and when it last posted — and nothing else, so it can be offered to you in the list. Nothing it posted is kept: no title, no sender, no text.
- **Items you delete**, which stay in the app's trash for 30 days so you can restore them, and are then removed for good. The fingerprint of a deleted message stays with it until then, so the same message is never captured a second time.
- **A search copy**: a simplified version of each message's text, its sender and the conversation's title, so search can ignore capital letters and accents.
- **When the app could see anything**: the date you installed Replybox, and the times notification access was switched on and off, and each app switched on and off. It keeps these so a thread can tell you honestly that it has a gap, instead of looking as though the conversation simply went quiet.
- **Your settings**, such as which apps are included and whether app lock is on.

It deliberately does **not** store the notification itself, its icons, the sender's profile picture, the app's own notification settings, or the buttons the notification carried. Beyond what is listed above, the only extra things it keeps are the bookkeeping it needs to recognise a message it has already stored: the identifier Android gave the notification, and a one-way fingerprint of the text. A fingerprint cannot be turned back into the message.

The developer has no access to any of it.

**Not yet shipped.** The app creates its (empty) database on your phone and stores no messages at all: the inbox exists as groundwork and there is no capture yet.

## Information we collect

**The app collects nothing.** There is no account, no sign-in, no analytics, no crash reporting and no advertising, and there is no server of ours for anything to be sent to. The developer cannot see your messages or your usage. Because the release build has no internet permission, the app cannot reach the internet by itself at all — the only text that ever goes anywhere is a reply you choose to send, and it goes to the app that message came from, not to us.

## How long messages are kept

Messages are not kept forever. The free app is planned to hold 30 days of history, after which a message is removed from your phone automatically — and where that happens the thread says so, rather than simply appearing to start late. Plus will remove that limit and keep them until you delete them.

**Not yet shipped.** Nothing is deleted on a schedule today. This section will say exactly what the window is, and when it starts counting, in the release that first applies one.

## How your messages are kept safe on your phone

The database sits in Replybox's own private storage, which Android keeps other apps out of, and it is protected by whatever screen lock and disk encryption your phone already uses. The app adds no encryption of its own, so anyone who can unlock your phone can read the inbox — turning app lock on is what stops that.

## Permissions

- **Notification access** is what the app is for, and it is the one thing it asks of you. It is not an ordinary permission: Android grants it on its own screen, under **Settings → Apps → Special app access → Notification access**, so it never appears in the app's permission list on the store page. Before sending you there, the app explains what it will read and names the apps it captures from. With it, Replybox can read the notifications your other apps post — which, for messaging apps, means the messages themselves. **Without it, nothing new can arrive, and the app says so on its first screen. Everything else still works:** the inbox, search, Settings and the app chooser stay open, nothing is greyed out, no screen is replaced by a permission wall, and anything already captured stays readable, searchable and deletable. You can withdraw access at any time on that same Android screen; the app then says on its first screen that capture is off and since when — or, where it only noticed later, that capture has been off since at least a stated time. It never tells you the reverse: the app will not claim capture is working, only when it last received something.
- **Nothing else — today.** The release build asks for no permissions of its own: in particular **no internet**, no contacts, no SMS, no storage, no location, no camera and no microphone. (Android's build tools add one internal marker permission scoped to the app itself; it grants access to nothing.) A build of the app is checked automatically on every change to main, and the build fails if a permission appears that is not listed here. A permission will be listed here, with what it is for and what still works without it, in the same release that first requests it.

**Not yet shipped.** Today the app does not ask for notification access and contains no code that could read a notification — the release build has no notification listener in it at all. The screen described above arrives with capture.

## Backups

Android's automatic cloud backup is **switched off for this app**, and your messages — the database that holds them, and the small queue behind it — are excluded from device-to-device transfer as well. Your messages are not copied to Google Drive, and a new phone does not receive them. Reinstalling therefore starts you with nothing.

**Not yet shipped.** The app writes no exports, no backups and no files you can open — only the database above.

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

On your phone: deleting a conversation takes it and its messages out of the inbox at once, with about five seconds to undo. They sit in the app's trash for 30 days — still on your phone, but out of the inbox, out of search and out of every count — and are then deleted for good. Uninstalling the app removes everything it stored, trash included. Because automatic backup is off, nothing of it is left in your Google account.

Deleting a message in Replybox does not delete it from the app it came from, and deleting it there does not remove it here.

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

You can also [open an issue on GitHub](https://github.com/Oasis-Forge/Replybox/issues). That link opens your browser and leaves the phone — it is the only thing in the app that does. Issues are public and stay public, so please don't paste a message, a sender's name, or a screenshot of your inbox into one: those are other people's words, and they never agreed to be there. Email instead if you need to show me what you saw.
