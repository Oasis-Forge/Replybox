# Roadmap

Goal: build the full v1 feature set, then ship Replybox to Google Play. Behavior is defined in `docs/PRODUCT_RULES.md`; items cite its rule IDs. The phase-by-phase reasoning and the PR-by-PR plan behind this are in `docs/PLAN.md`. Group related items into larger PRs; CI must pass. Tick items in the same PR that completes them, and date every decision that adds, moves, or drops one.

## Phase 0: Tooling
Set up before the first feature, while it's cheap.
- [x] `CLAUDE.md`, `.claude/` settings, format hook, `/spec` `/verify` `/release` `/ship` `/handoff` skills, `build-doctor` agent (`/kickoff`)
- [ ] GitHub repo, Dependabot, CI (checks + a build for every mobile platform) green on a first PR
- [ ] `main` ruleset: PR required, the CI checks required, no force pushes or deletion (`docs/RELEASING.md`)
- [ ] Every merged PR is a release: the CI version check, then a build-as-a-check on merge. Nothing is published from CI and nothing is tagged; the store artifact is built locally and uploaded by hand (`docs/RELEASING.md`). `0.1.0` is the first.
- [ ] The release workflow runs once by hand without secrets (unsigned artifacts, nothing published)
- [ ] Privacy policy draft served by GitHub Pages
- [ ] The first product rules (`docs/PRODUCT_RULES.md`) for the areas Phase 2 opens with
- [ ] Competitor research (`docs/research/competitor-analysis.md`) — or that file records, dated, that no competitor was studied and why. Either ticks this; leaving it as the shipped template does not
- [ ] **Start the store paperwork now, because it is measured in weeks while everything else is measured in days.** Create and verify the developer accounts, reserve `com.replybox.app` in each console, and create the app record. It is the only item here that cannot be hurried later: identity verification takes days, and a new personal Play account then needs a closed test running for 14 continuous days with at least 12 testers before it can even apply for production. Write the date that test must start to hit the launch you want, and put it here: <!-- closed test starts by: DATE -->
  Everything in Phase 4 depends on it. The one-time purchase can only be tested against a real product in a real console, on a build installed from a real track.

## Phase 1: Foundations
Groundwork every feature builds on. Settle everything that shapes stored data now, before real users have any.
- [ ] **Capture spike on a real Android 15 or 16 phone**: the five checks in `docs/PLAN.md` section 5 (reply actions, burst behaviour, 24-hour survival on an OEM device, redaction, reply after dismissal), results dated in `docs/research/spike.md`, go/no-go. It comes first because a failure in any of the first three checks stops the product, and because its raw notification dumps become the fixtures every capture test is written against.
- [ ] Strict lints (unawaited futures, declared return types, consistent quotes, const where possible).
- [ ] Inject the storage layer and every device service into the state layer, so tests use an in-memory database and no-op fakes.
- [ ] Migration scaffold: an ordered list of schema steps run on upgrade, with a test that upgrades the oldest schema.
- [ ] Reliable writes: write first, then change state; on failure roll back and show an error.
- [ ] Localization scaffolding: every UI string in the message files from the start, even with one language.
- [ ] Schema step: record rules on every table: UUIDs, timestamps, soft delete (REC-1, REC-2, DEL-1).
- [ ] The stored shapes that can't change once users have data: integer money in thousandths if the app handles money (MONEY-1), a picked date as a local calendar date that survives a time-zone change (DATE-1), and built-in items stored by ID with translatable labels rather than stored text (DATA-1).
- [ ] <!-- Schema steps from "Roadmap impact" in PRODUCT_RULES.md, each with its rule IDs. -->
- [ ] Tests: model round-trip, each migration step, the core calculation rules, widget tests for the main flows.
- [ ] Platform decision: which targets ship in v1 and which come after (dated). <!-- 21 September 2026: Android and Google Play only, in v1 and after. iOS has no notification-listener equivalent, so there is no iOS version to postpone; desktop is out for the same reason (docs/PLAN.md section 10). Left unticked because the rest of this phase has not started. -->

## Phase 2: Features (in dependency order)
<!-- One bold-titled item per feature area, citing its rule IDs. Order them so each item's data exists before anything that reads it. The PR each one maps to is in docs/PLAN.md section 6, and /spec writes the area's rules before its code. -->
- [ ] **Capture** (area CAP): the Kotlin notification listener hardened from the spike — native queue, reconnection, removal reasons, the event channel — plus the Dart normaliser and one fixture test per app per case from the spike's dumps. Nothing else can be built until this stores something.
- [ ] **Inbox** (area INB): conversation list sorted by last message, thread view, per-app filters, and Settings with the included-apps list. The first screens anyone sees.
- [ ] **Permissions and onboarding** (area PERM): prominent disclosure before the system settings page, the deep link to notification access, the return check, the manufacturer-specific battery guidance, and the included-apps chooser. After the inbox, so the permission leads somewhere worth granting it for.
- [ ] **Reply** (area REP): native reply through the notification's own reply action, the in-memory action map with reconnection, the optimistic outbound message, and "open in app" wherever a reply action is gone. This is the product.
- [ ] **Triage: waiting, done, snooze** (areas WAIT and SNZ): the "waiting on me" list as the default tab, one-tap done with undo, the three free snooze presets, the native alarm receiver, and rescheduling after reboot.
- [ ] **Search and retention** (areas SRCH and RET): search over sender, text and conversation title, ignoring case and accents (LANG-4); 30 days kept on free, with a purge that spares snoozed and waiting conversations; "delete everything" (DEL-1); storage used shown in Settings.
- [ ] **App lock** (LOCK-1–LOCK-3): the data is other people's messages, so this is not optional — and it stays free, because a trust feature is never paid for (product principle 2).
- [ ] **First run:** empty states with one clear first action, saying what the app cannot see before the user finds out (RUN-1).

## Phase 3: Store readiness
- [ ] Display name "Replybox" on every platform: launcher label, bundle names, window titles.
- [ ] Launcher icons and splash screen, generated from one committed source.
- [ ] Store IDs, permanent after the first upload and free of personal names: `com.replybox.app`.
- [ ] Privacy policy published, and updated for every feature that touches user data. Decide how it is served: GitHub Pages needs the repo to be public, or a paid plan (`docs/RELEASING.md` → Privacy policy).
- [ ] `LICENSE` decided and committed. With no file the code is "all rights reserved", which is a choice worth making rather than defaulting into — and a readable repo is one of the few ways "nothing leaves your phone" can be checked rather than believed (`docs/PLAN.md` section 2).
- [ ] The release build declares only the permissions the store listing admits to; the release workflow dumps the built artifact's permissions and fails on any it doesn't expect (RUN-2). Write the list against a real build, not from memory, and check both directions: a permission the app needs and lost is as much a bug as one a plugin added.

## Phase 4: Before release
<!-- Scope added after Phase 2, each item with its decision date. Languages come first, so every later PR adds all languages as it goes. The first-run walkthrough comes last, so it shows finished features. -->
- [ ] **Languages** (LANG-1–LANG-6)
- [ ] **Plus purchase** (PAY-1–PAY-6): one-time, after the free feature set is complete. Nothing that already works moves behind it (PAY-4), so it ships with a capability of its own — unlimited history is the first. It needs a product in the Play console and can only be tested on an internal track by a licence tester, so this item is blocked on the Phase 0 store-paperwork item, not on anything in Phase 5. If the account isn't verified by the time you reach this, the code is finished and untestable.
- [ ] **Plus capabilities** (PAY-3, PAY-4): rules and quiet hours, the home-screen widget and nudges, export and backup (BAK-1–BAK-5), and on-device summaries where the device supports them. Each lands after the purchase works, and none is shown for sale before it exists. `docs/PLAN.md` PRs 12 to 14.
- [ ] **First-run setup and walkthrough** (RUN-3, RUN-4): last.

## Phase 5: Google Play
<!-- The only store Replybox targets. -->
- [ ] Finish the Android one-time setup in `docs/RELEASING.md`: signing, contact details, payments profile, secrets. The account itself and the app record were done in Phase 0.
- [ ] Internal testing from a release, including in-app products bought by licence testers.
- [ ] Closed test finished and production access applied for. It should already be running: the 14 continuous days with at least 12 testers started in Phase 0, and the application asks what the testers did and what changed as a result, not just how many there were.
- [ ] Store listing in every language from `store/play/` (text, screenshots, feature graphic, icon), privacy policy URL, and the data safety form. The listing states the limits — no history from before install, only conversations that notified you, no starting a new chat — rather than leaving a reviewer or a one-star review to find them.
- [ ] EU trader status, then apply for production and promote the release.

<!-- Phases 6 (desktop stores) and 7 (Apple) were deleted at kickoff, 21 September 2026: Android and Google Play are the only targets, now and later. iOS has no notification-listener equivalent, so there is no Apple version to postpone (docs/PLAN.md section 10). The numbering below is left alone so existing references to "Phase 8" still point at it. -->

## Phase 8: After launch
Shipping is where an app starts costing attention rather than work. These recur; date each one as it is done, and treat a missed deadline as a bug.
- [ ] Each release: read the store's crash and performance figures and the new reviews, before starting the next item. `docs/RELEASING.md` → When a release is bad.
- [ ] **Target API level**, annually. Play stops showing an app to new devices when it falls behind, and the deadline is the same date every year for everyone. Put the date here: <!-- target API deadline: DATE -->
- [ ] Declarations that expire or go stale: the data-safety form and EU trader status. Re-check each at the same time as the target API bump, and whenever a feature changes what is stored or requested (RUN-2).
- [ ] **Every Android release**: read its behaviour-changes page for what it does to notification listeners. Redaction has widened twice already, in Android 15 and then 16, and the product is meant to degrade to "open in app" rather than fail (`docs/PLAN.md` section 9).
- [ ] The support address is read by someone. Play publishes it on the listing, and the developer's email on every app, so it receives mail whether or not it is watched.

## After v1
<!-- Ideas deliberately left out of v1, one line. -->
- A real Telegram client over TDLib inside the same inbox: full history and search for the one large network that allows third-party clients (`docs/PLAN.md` section 10).
- A yearly subscription beside the one-time Plus purchase, decided from the first quarter's numbers.
- Tablet and foldable layouts.
- Never iOS. Say so in the FAQ, so nobody waits for it.

## Known bugs
<!-- Found and not fixed yet: what, where, and the rule it breaks. -->
