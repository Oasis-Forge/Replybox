# One inbox for every messenger: feasibility analysis

Date: 2026-09-21. Status: analysis only, nothing built. Assumes one developer, Flutter, the app starter kit, no backend team.

The idea: one app that shows and answers a person's WhatsApp, Facebook Messenger, Instagram DMs, Telegram, SMS and the rest, so they stop hopping between apps.

## 1. Verdict

**The obvious version cannot be built legitimately, and where it can be built it already exists.** Meta offers no way for a third-party app to read a person's own WhatsApp, Messenger or Instagram chats. The EU's interoperability rule does not change that. The only route that works is reverse-engineering the protocols, which Meta detects, warns about and bans for. And that route is already taken by Beeper, owned by Automattic, free for five accounts, with open-source bridges. A solo developer competing there takes all the risk for none of the upside.

**There is one legitimate, underserved version worth building.** On Android, an app with "notification access" receives every message notification from every messaging app and can reply through the notification's own reply action. That is exactly how Microsoft Phone Link, Wear OS watches, Android Auto and Pushbullet work, and Google's own policy names "apps that aggregate notifications to help users focus" as a permitted use. It gives a real unified inbox: everything that pinged you, from any app, in one place, answerable, searchable, snoozable. Its limits are honest ones: inbound-triggered threads only, no history from before install, Android only. Nobody mainstream ships this as a two-way inbox today.

**If revenue matters more than the consumer idea**, the other legitimate route is a business inbox on Meta's official business APIs. It is a crowded SaaS market with per-message fees, and it is a different product from "make life easier for people".

Recommendation: build the Android notification inbox, and validate five specific things on a real device in week one before committing (section 8).

## 2. What the idea actually requires: access to each network

| Network | Personal-account API for third parties | Third-party clients | How aggregators get in today | Risk |
|---|---|---|---|---|
| WhatsApp | None. The Business Platform requires a business number that is de-registered from personal WhatsApp | Prohibited by terms of service; accounts get warnings, then bans | Reverse-engineered multi-device protocol (whatsmeow), linked as a "companion device" | High and rising: May 2025 ban wave hit reply-only clients; Sept 2026 WhatsApp is detecting unofficial web clients |
| Messenger | None for personal accounts. Messenger Platform is for Pages | Prohibited | Reverse-engineered (mautrix-meta) | High; breaks whenever Meta changes things |
| Instagram DMs | Only for professional accounts via the Messaging API, with Meta app review | Prohibited; Apple pulled an unofficial Instagram client in 2022 at Meta's request | Reverse-engineered (mautrix-meta) | High |
| Telegram | Yes. TDLib and MTProto are published for exactly this | Explicitly allowed | Official library | Low |
| Signal | No public API; signal-cli is unofficial and breaks roughly quarterly | Not supported | Reverse-engineered | Medium |
| SMS | Yes on Android (default SMS app role) | Allowed | Standard Android APIs | Low |
| RCS | No third-party API; Google Messages only | Not possible | Nothing | Blocked |
| iMessage | Nothing. Not designated under the DMA (Commission decision, Feb 2024) | Apple blocked Beeper Mini within days in Dec 2023 | Mac relay only | Blocked on Android |
| Slack | User tokens allowed, but 2025 terms bar storing or indexing messages pulled through the API | Allowed within terms | Official API | Medium |
| Discord | Bot API only; automating a user account ("self-bot") gets the account terminated | Prohibited | Nothing safe | High |
| Teams | Graph API chat access, work and school accounts only | Allowed with admin consent | Official API | Low, but not consumers |

Two networks the user cares about most, WhatsApp and Messenger, plus Instagram, are the three with no sanctioned door. That is the whole problem.

## 3. The five ways in, compared

**A. Reverse-engineered protocols (Beeper's way).** Go libraries like whatsmeow and mautrix-meta log in as a linked device and speak the real protocol. Full read and write, history backfill, any platform. Beeper moved these bridges on-device in July 2025 so end-to-end encryption is preserved. Cost: Meta breaks them regularly, the maintainers fix them, and users' accounts carry the ban risk. In May 2025 WhatsApp pushed "your account may be at risk" warnings and bans to whatsmeow and Baileys users, including low-volume accounts that only replied to incoming messages. On 1 September 2026 WABetaInfo reported WhatsApp testing a warning on the Linked Devices screen for unofficial web clients and noted it is already detecting them in the background. The warning is dismissible today. The direction is clear.

**B. Webview wrapper (Franz, Rambox, Ferdium).** A desktop shell that embeds web.whatsapp.com, messenger.com and instagram.com. Cheap to build, no protocol work, but desktop only, three free and open-source competitors already exist, and the same September 2026 detection of unofficial web clients applies.

**C. Notification access plus direct reply (Phone Link's way, Android only).** A NotificationListenerService receives every notification with sender, conversation, message text and, for messaging apps, the MessagingStyle history the app attached. If the notification carries a reply action, the app can send a reply through it. Play Store apps already do this per network: AutoResponder for WhatsApp, for Instagram, for Messenger and for Telegram all state they "reply to notifications" rather than touching the app, and Watomatic on F-Droid does it open-source. Limits: you only see threads that notified you, nothing before install, you cannot start a new conversation (deep-link into the app instead), grouped "5 new messages" summaries can hide detail, and Android 15 and 16 redact one-time passcodes from untrusted listeners. No terms-of-service exposure, because the messaging apps themselves publish these notifications for exactly this kind of consumer.

**D. Official business APIs (Respond.io's way).** WhatsApp Business Platform, Instagram Messaging API and Messenger Platform, with Meta app review and business verification. Fully sanctioned, but only for a business talking to its customers. Free-form replies only within 24 hours of the customer's last message, templates otherwise, and per-message billing since 1 July 2025 (inbound and replies inside the window are free). Cannot touch anyone's personal chats.

**E. Become an interoperable messaging service (BirdyChat's way, EU only).** Under the Digital Markets Act, Meta must let other messaging services exchange messages with WhatsApp and Messenger users in the EU. The first two, BirdyChat and Haiket, went live in November 2025. To join you run your own messaging service, sign Meta's reference offer, implement the Signal protocol, and prove ownership of your own user identities. WhatsApp users must opt in on their side. Groups came in phase two, calls are due around 2027. This is a way for a new messenger to reach WhatsApp users. It is not a way to read a person's existing WhatsApp account, and it does not exist outside the EU.

| Approach | Coverage | Platforms | Legal or ban risk | End-to-end encryption kept | Effort | Ongoing maintenance |
|---|---|---|---|---|---|---|
| A. Reverse-engineered | Full, with history | All | High, and Meta is escalating | Yes if on-device | High | High, Meta breaks it |
| B. Webview wrapper | Whatever the web app shows | Desktop | Rising (Sept 2026 detection) | Yes | Low | Medium |
| C. Notification inbox | Every app that notifies; inbound-triggered, reply only | Android | Low; sanctioned pattern | Yes, reads the rendered notification | Low to medium | Low; track Android changes |
| D. Official business APIs | Business-owned accounts only | Server | None if compliant | No, the business holds plaintext | Medium | Low, plus per-message fees |
| E. DMA interop service | WhatsApp and Messenger users who opt in, EU only | All | None | Yes, required | Very high | High, plus regulation |

## 4. Who has tried this and what happened

- **Beeper.** Bought by Automattic for $125M in April 2024. Relaunched 16 July 2025 with on-device bridges. Free for 5 accounts, Beeper Plus $9.99 a month for 10, Beeper Plus Plus $49.99 a month unlimited. Supports WhatsApp, Instagram, Messenger, X, Telegram, Signal, Matrix, Slack, Google Chat, Discord, LinkedIn and SMS/RCS; iMessage only through a Mac. "Millions of registered users", no revenue disclosed. Bridges are open source; self-hosting is documented but unsupported. The CEO conceded remaining reliability issues in the on-device model.
- **Texts.com.** The polished paid alternative at $12.50 to $15 a month. Bought by Automattic for $50M in October 2023 and merged into Beeper in 2025.
- **Beeper Mini.** iMessage on Android by phone number, December 2023. Apple blocked it within days and kept blocking it; Beeper gave up within three weeks.
- **Nothing Chats / Sunbird.** iMessage relay for Android, November 2023. Pulled from the Play Store in about a day after researchers found messages, attachments and contacts logged unencrypted on Sunbird's error-tracking dashboard. Sunbird reportedly relaunched in August 2026 with no independent audit published (single source).
- **The OG App.** An ad-free Instagram client. Apple removed it in September 2022 under guideline 5.2.2 after Meta objected.
- **Franz, Rambox, Ferdium, Station.** Webview wrappers. Three are alive and free; Station is dead. None is a business.

Lessons. The platform owner decides whether you exist, and Meta and Apple have both used that power. The exits were strategic acquisitions by one buyer already invested in messaging, not evidence of a large paying consumer base. Trust is the entire product: one logging mistake killed Nothing Chats in a day. Everyone who touched iMessage lost.

## 5. Legal and platform-policy risk, in detail

**Meta's terms.** WhatsApp's terms prohibit creating "software or APIs that function substantially the same as our Services" and reverse engineering. Meta's help pages name GB WhatsApp, WhatsApp Plus and YoWhatsApp as unofficial apps whose users get temporary and then permanent bans. Meta sued three makers of unofficial WhatsApp mods in October 2022. In January 2026 it also barred general-purpose AI chatbots from the WhatsApp Business API, a further sign of how it treats third parties on its network.

**App stores.** Apple's guideline 5.2.2 rejects apps that give unauthorised access to a third-party service. On Google Play, notification access is treated as a sensitive permission: the listing needs a prominent in-app disclosure and explicit consent before the permission prompt, the use has to match the app's core feature, and the Play Protect guidance names "apps that aggregate notifications to help users focus" as allowed while apps that hide other apps' notifications without prior consent are not. Play Protect blocks sideloaded apps that declare the notification-listener permission in some markets, so distribute through Play. Accessibility services are the wrong tool: only genuine accessibility apps may self-certify, and using them to read screens invites rejection.

**Android platform changes.** Android 15 stops untrusted notification listeners reading one-time passcodes; Android 16 extends that to the lock screen. Both are narrow so far, but the trend is towards more redaction, and Android 15 already disrupted Phone Link for some users. A notification inbox should degrade gracefully when content is redacted.

**Privacy law.** Whatever the approach, the app processes messages from people who never agreed to it. The defensible design is on-device only: no account, no server, no message ever leaves the phone, and any AI feature either runs locally or is opt-in with a plain-language disclosure. That is also what makes the Play Data safety form short.

**Other networks' terms.** Slack's 2025 API terms bar permanently storing messages fetched through the API, so a Slack integration cannot keep an archive. Discord bans self-bots outright. Signal offers no supported third-party path. Telegram is the only large network that welcomes third-party clients.

## 6. Market and money

- Consumers barely pay. Beeper went from paid to free in April 2024, then reintroduced paid tiers in July 2025 while keeping a generous free tier. Texts charged $12.50 to $15 a month and sold for $50M rather than growing into a standalone business. No survey on willingness to pay for unified messaging was found.
- Free open-source alternatives cap the price: Ferdium and Rambox on the desktop, the mautrix bridges (actively maintained through September 2026) for anyone technical.
- Demand for the notification angle is visible in a neighbouring category: Notisave, a notification history and search app, has over 10 million installs. Nothing mainstream turns that into a two-way inbox.
- The business side has money but is crowded: Respond.io at roughly $199 to $349 a month for ten seats, Trengo around $329 to $550 a month, Manychat from $15 a month, Wati adding about 20% on top of Meta's per-message fees. Winning there means selling to businesses, not building for consumers.

For one developer, the consumer product is a free app with a small paid tier and reputational upside. The business product is real revenue behind a sales effort.

## 7. Options ranked for you

| Option | What it is | Time to a usable beta | Risk | Upside | Verdict |
|---|---|---|---|---|---|
| 1. Android notification inbox | One inbox of every message notification from every app, with inline reply, snooze, search and a "waiting on me" list | 6 to 10 weeks solo | Low | Real consumer value, clean story, first mover on the two-way version | **Build this** |
| 2. Business inbox on official APIs for one niche | WhatsApp, Instagram and Messenger customer messages for a specific kind of small business | 8 to 12 weeks plus Meta review | Low legal, high commercial | Recurring revenue if you can sell | Second choice, only if you want a SaaS business |
| 3. Hybrid: option 1 plus a full Telegram client via TDLib | Telegram gets real history and search; everything else through notifications | Option 1 plus 4 to 6 weeks | Low | Deeper product for Telegram-heavy users | Phase two of option 1 |
| 4. Beeper-style bridges | Reverse-engineered WhatsApp, Messenger and Instagram | Months | High, and escalating | Competing with a free Automattic product | Do not |
| 5. Desktop webview wrapper | Ferdium again | Weeks | Rising | None over free incumbents | Do not |
| 6. DMA interoperable messenger | Your own messaging service that can reach WhatsApp users in the EU | Many months plus Meta agreement | Regulatory | Only if you want to build a new messenger for Europe | Not for one developer |

## 8. If you build option 1: shape of the product

**Positioning.** Not "all your chats in one app", which it cannot honestly be. "Everything that pinged you, in one place, answerable." Google's permitted use is literally aggregation to help users focus, so lean into it: triage, reply, snooze, mute, done.

**Core features for the beta.**
- Unified timeline grouped by conversation across every app that notifies, not just messengers: WhatsApp, Messenger, Instagram, Telegram, Signal, SMS, Slack, Discord, Teams, LinkedIn, email. New apps cost nothing to add.
- Inline reply through the notification's reply action, with a deep link into the source app when a thread has no reply action.
- A "waiting on me" list: threads where the last message was inbound and unanswered.
- Snooze and remind, per-app quiet hours, search across everything the app has seen.
- Mark-as-read when the user reads the message in the source app (the notification is removed, which the listener observes).
- Everything on device. No account, no server, no analytics on message content.

**Stack.** Flutter from the starter kit for the UI, a Kotlin NotificationListenerService behind a platform channel (evaluate the notification_listener_service package first, which exposes reply, but expect to own the native side), a local database, no backend. Play Store only.

**Validate these five things in week one, on a real phone running Android 15 or 16, before writing the app.**
1. WhatsApp, Messenger, Instagram, Telegram and Signal each post MessagingStyle notifications with a reply action, and a reply round-trips correctly. Evidence says yes for all but Signal; confirm yourself.
2. What arrives when five messages land at once in one chat and across chats: whether the MessagingStyle history carries every message or only the summary.
3. The listener survives Samsung and Xiaomi battery management for a full day.
4. Content is intact when the phone is locked and when Android flags a passcode, and the app shows a sensible placeholder when it is redacted.
5. A draft of the prominent-disclosure screen and the Data safety answers fits Play's policy without a server.

If any of the first three fails on a mainstream device, stop; the product cannot be reliable enough to trust.

**State the limits in the listing.** No history from before install. Only conversations that notified you. Cannot start new chats. Android only, and iOS cannot do this at all.

## 9. Questions only you can answer

- Consumer app or business tool? This analysis assumes consumer.
- Is Android-only acceptable? The consumer version has no iOS path.
- Where are your users? The EU interop route only exists in Europe; WhatsApp Business demand is strongest in India, Latin America and the Middle East.
- Free with a small paid tier, or paid from day one?

## 10. Sources

- Meta, WhatsApp third-party chats live in Europe with BirdyChat and Haiket, Nov 2025: https://about.fb.com/news/2025/11/messaging-interoperability-whatsapp-enables-third-party-chats-for-users-in-europe/
- Meta Engineering, how DMA interoperability works (reference offer, Signal protocol, separate service), Mar 2024: https://engineering.fb.com/2024/03/06/security/whatsapp-messenger-messaging-interoperability-eu/
- European Commission, messaging interoperability developer portal: https://digital-markets-act.ec.europa.eu/developer-portal/messaging-interoperability_en
- CNBC, Commission declines to designate iMessage, Feb 2024: https://www.cnbc.com/2024/02/13/apple-imessage-microsoft-bing-not-gatekeepers-under-eu-dma.html
- WhatsApp Terms of Service: https://www.whatsapp.com/legal/terms-of-service
- whatsmeow issue 810, "account may be at risk" warnings, May 2025: https://github.com/tulir/whatsmeow/issues/810
- Baileys issue 2658, same wave: https://github.com/whiskeysockets/Baileys/issues/2658
- WABetaInfo, WhatsApp testing a warning for unofficial web clients, 1 Sept 2026: https://wabetainfo.com/whatsapp-is-testing-a-safety-warning-for-unofficial-web-clients/
- BleepingComputer, Meta sues makers of unofficial WhatsApp apps, Oct 2022: https://www.bleepingcomputer.com/news/security/meta-sues-app-dev-for-stealing-over-1-million-whatsapp-accounts/
- TechCrunch, Apple removes The OG App, Sept 2022: https://techcrunch.com/2022/09/29/apple-removes-the-og-app-an-ad-free-instagram-client-from-the-app-store/
- TechCrunch, Beeper Mini cut off by Apple, Dec 2023: https://techcrunch.com/2023/12/08/apple-cuts-off-beeper-minis-access-after-launch-of-service-that-brought-imessage-to-android/
- Beeper blog, Moving Forward, Dec 2023: https://blog.beeper.com/2023/12/21/beeper-moving-forward/
- TechCrunch, Automattic buys Beeper for $125M, Apr 2024: https://techcrunch.com/2024/04/09/wordpress-com-owner-acquires-multi-service-messaging-app-beeper-for-125m/
- TechCrunch, Beeper relaunch with on-device model and pricing, Jul 2025: https://techcrunch.com/2025/07/16/beepers-all-in-one-messaging-app-relaunches-with-an-on-device-model-and-premium-upgrades/
- Beeper FAQ (plans, on-device connections): https://www.beeper.com/faq
- Beeper developer docs, self-hosting bridges: https://developers.beeper.com/bridges/self-hosting/
- TechCrunch, Automattic buys Texts.com for $50M, Oct 2023: https://techcrunch.com/2023/10/24/wordpress-com-owner-buys-all-in-one-messaging-app-texts-com-for-50m
- 9to5Google, Nothing Chats and Sunbird data exposure, Nov 2023: https://9to5google.com/2023/11/18/nothing-chats-sunbird-unencrypted-data-privacy-nightmare/
- Google Play Protect developer guidance (notification listener, permitted uses): https://developers.google.com/android/play-protect/warning-dev-guidance
- Google Play, prominent disclosure and consent: https://support.google.com/googleplay/android-developer/answer/11150561
- Google Play, permissions and APIs that access sensitive information (accessibility): https://support.google.com/googleplay/android-developer/answer/16585319
- Android 15 behaviour changes (OTP redaction for untrusted listeners): https://developer.android.com/about/versions/15/behavior-changes-all
- Android Authority, Android 16 sensitive notifications on the lock screen: https://www.androidauthority.com/android-16-sensitive-notifications-lock-screen-3501564/
- Windows Central, Android 15 and Phone Link notifications: https://www.windowscentral.com/software-apps/windows-11/microsoft-warns-that-android-15-will-make-windows-phone-link-worse
- Microsoft, Phone Link notification setup (uses notification access): https://support.microsoft.com/en-us/topic/setting-up-notifications-in-the-phone-link-0ad015d9-0c9c-6d0c-f67c-be0538459f18
- Android developers, Wear OS notification bridging: https://developer.android.com/training/wearables/notifications/bridger
- Android developers, conversation notifications and direct reply: https://developer.android.com/social-and-messaging/guides/communication/notifications-conversations
- AutoResponder for Messenger (replies via notifications): https://play.google.com/store/apps/details?id=tkstudio.autoresponderforfb
- AutoResponder for IG (replies via notifications): https://play.google.com/store/apps/details?id=tkstudio.autoresponderforig
- Watomatic, open-source WhatsApp auto reply via notifications: https://f-droid.org/packages/com.parishod.watomatic/
- Flutter package notification_listener_service: https://pub.dev/packages/notification_listener_service
- Telegram TDLib: https://core.telegram.org/tdlib
- signal-cli (unofficial): https://github.com/AsamK/signal-cli
- Discord, self-bots policy: https://support.discord.com/hc/en-us/articles/115002192352
- Slack API terms update, May 2025: https://docs.slack.dev/changelog/2025/05/29/tos-updates/
- WhatsApp Business Platform pricing: https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing
- Twilio, WhatsApp per-message pricing from July 2025: https://help.twilio.com/articles/30304057900699
- Instagram Platform overview (professional accounts, app review): https://developers.facebook.com/docs/instagram-platform/overview/
- mautrix bridges (activity through Sept 2026): https://github.com/mautrix
- whatsmeow: https://github.com/tulir/whatsmeow
