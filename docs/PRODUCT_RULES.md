# Product rules

_21 September 2026._

This file defines how Replybox behaves: the calculations, defaults, and edge cases behind each screen. Where a competitor was studied (see `docs/research/competitor-analysis.md`), a section says what they do, what we take from it, and our rule: we learn from their app; we don't copy its rules. Where none was, a section starts from the user need instead.

- Rule IDs (`DATA-1`) are stable: never renumber or reuse one. A dropped rule stays, struck through, with its date and reason. Tests, code comments, PRs, and roadmap items reference them.
- A rule is testable: a number, a default, an order, an edge case. "Entry is fast" isn't a rule; "a basic entry takes about four taps" is.
- "Not verified" marks competitor behavior we saw only partly.
- Every rule keeps the product principles in `CLAUDE.md`: 1. Nothing leaves the phone: no account, no server, no analytics, no internet permission in the release build. 2. Free is complete: inbox, reply, waiting list and search never move behind a payment. 3. Honest about limits: the app says what it cannot see. 4. Never hides or answers another app's notification unless the user asked. 5. Two taps to reply or clear.

## Section shape

`/spec <area>` writes a section in this shape:

> ## N. Area
>
> **They do:** what the competitor does, in our words. Parts we couldn't check: not verified.
>
> **Learn:** the user need behind it, and where they fall short.
>
> - **AREA-1** Our rule.

With no competitor studied (`docs/research/competitor-analysis.md` records that, dated), a section has no **They do** and opens with **Learn**, written from the user need itself. Never write a **They do** from what a competitor is assumed to do: the rules below it would then cite a guess as observed fact.

The sections below are starter rules that held up in an earlier app. Keep, change, or delete each one, and record the choice under Decisions.

## 1. Data foundations

**Learn:** undo, trash, backup merge, sync, and translations all depend on these being right before any user data exists.

- **REC-1** Every record has `created_at` and `updated_at`.
- **REC-2** Every record ID is a UUID v4, so records from a backup or another device never collide. Built-in defaults use fixed IDs instead, so the same default matches across devices.
- **DEL-1** Deleting sets `deleted_at`; it doesn't remove the row. Deleted records count nowhere: totals, charts, search, or export.
- **DEL-2** Delete needs no confirmation. A snackbar offers Undo for about 5 seconds. Deleted items stay in the trash for 30 days, then get purged on app start.
- **DATA-1** User-facing names of built-in items (default categories, default accounts) are translatable labels referenced by ID, never stored text.
- **MONEY-1** If the app handles money: amounts are integers in thousandths of a unit (`12.50` → `12500`), so sums never drift and every ISO currency fits. The record's type carries the sign.
- **DATE-1** A date the user picks is a local calendar date. It stays on that date if the device's time zone changes later.

## 2. Backup and export

**Learn:** a raw database file breaks across schema versions, and defaults that send data off the device cost trust.

- **BAK-1** A backup is a file with the app version and the schema version, saved or shared only when the user chooses to.
- **BAK-2** Before a restore replaces or merges anything, the app saves an automatic backup of the current data.
- **BAK-3** Merge matches records by ID (REC-2); the later `updated_at` wins, deletions included (DEL-1). The app then shows how many records were added, updated, and unchanged.
- **BAK-4** A backup from a newer schema is refused with a message to update the app. Older backups are migrated with the app's own schema steps.
- **BAK-5** Exported files use ISO dates and plain decimals with a `.`, whatever the language. Spreadsheet text starting with `=`, `+`, `-`, or `@` gets a leading apostrophe.

## 3. First run and trust

**Learn:** asking for an account, permissions, or cloud backup up front costs trust before the app has earned any.

- **RUN-1** An empty screen explains itself with one clear first action.
- **RUN-2** The release build declares no permission a shipped feature doesn't need, so the store's data-safety answers stay true. The release workflow checks it.
- **RUN-3** The first launch asks only what the device can't tell (for example the language and currency) on one page, preselected from the locale. Permissions are requested when the feature that needs them is first used, and everything else works if they're refused.
- **RUN-4** A walkthrough of up to four pages follows setup. Every page has Skip, it respects reduce motion, it can be replayed from Settings, and it shows once. An update on a device that already has data skips setup and the walkthrough.

## 4. Languages

**Learn:** a translated app only feels native when numbers, dates, plurals, search, and layout direction are right too. A cut-off label looks broken.

- **LANG-1** The app follows the device language and falls back to English. Settings offers "System default" and each language in its own name. A change applies without a restart.
- **LANG-2** Every user-facing text comes from the message files, including notifications, widgets, and generated files. Plurals and variable parts are ICU messages, never pieced-together strings. CI fails on a missing message or mismatched placeholders.
- **LANG-3** Dates, numbers, and amounts follow the chosen language's format. Files the app writes don't (BAK-5).
- **LANG-4** Search ignores case and accents in every language, including the Turkish dotted and dotless i.
- **LANG-5** Right-to-left languages mirror the layout: navigation, lists, swipe actions, arrows. Amounts, numbers, and expressions stay left to right inside them.
- **LANG-6** Translations are machine-made in the same PR that adds or changes the English message. Widget tests render the main screens in every language on a phone-size screen at 1.3× text size, and fail on overflow.

## 5. App lock

**Learn:** private data needs a lock, but a forgotten app PIN locks people out of their own records.

- **LOCK-1** App lock is off by default and uses the device's own biometrics or screen lock, so the app never stores a PIN. Turning it on or off asks for authentication first.
- **LOCK-2** With app lock on, the app asks at launch and after at least a minute in the background, and hides its content until unlocked. Notifications and widgets show no private data.
- **LOCK-3** If the device no longer has biometrics or a screen lock, app lock turns itself off instead of locking the data away.

## 6. Plus and paying
<!-- The app is free and carries no ads. A one-time "Plus" purchase unlocks the capabilities listed in docs/PLAN.md section 3. Name the screens and the locked capabilities when you /spec this section. -->

**Learn:** an ad SDK collects device identifiers and needs the internet permission, so ads would turn "nothing leaves the phone" into a false answer on the Play data-safety form and cost the app the one claim nothing else in the category can make. The free tier therefore pays for nothing, and the upgrade has to be worth buying on its own merits. A subscription to *not* see something is resented; what is sold must already work.

- **PAY-1** Plus is a one-time non-consumable purchase, not a subscription, and it unlocks every Plus capability at once. It follows the store account, "Restore purchases" sits beside the price, and the app asks the store what is owned at each launch, so a refund or a family-shared purchase lands without a reinstall.
- **PAY-2** Prices come from the store, in the buyer's currency. Never hard-coded, and nothing to do with any setting in the app.
- **PAY-3** Nothing is sold before it exists. A Plus capability that isn't finished is shown as "coming soon", with no price and no button.
- **PAY-4** Nothing that already works moves behind a payment. Paying adds what is new: the inbox, reply, the waiting list and search stay free whatever else changes (product principle 2).
- **PAY-5** Selling is quiet: one row in Settings and one small "Plus" tag on a locked capability. No interstitial upsell, no countdown, no trial that lapses into a charge — and no ad of any kind, in any build, anywhere in the app.
- **PAY-6** A purchase that fails or is left pending never charges twice and never leaves the app half-paid: the app finishes every purchase with the store whatever the outcome, including the purchase sheet being closed without buying, and nothing unlocks until the store confirms it. A store with no such product configured is a real state — show "nothing to sell yet" rather than a button that only fails.

## Decisions
<!-- Numbered and dated answers to open questions, citing the rules they settle. -->
1. (21 September 2026) **No ads, ever.** The kit's starter rules ADS-1 to ADS-9 were deleted rather than struck through: they were never adopted here, and this file's own note says a starter rule may be kept, changed or deleted as long as the choice is recorded. An ad SDK collects device identifiers and brings the internet permission with it, which contradicts product principle 1 and would make the data-safety form longer than the app's whole story. A deliberate departure from the kit's default, with the reasoning in `docs/PLAN.md` section 2. PAY-5 carries the no-ads promise as a testable rule.
2. (21 September 2026) **The free tier is the whole product; Plus is extra** (PAY-4). Free keeps the unified inbox, inline reply and open-in-app, the "waiting on me" list, app lock, choosing which apps are included, and 30 days of history and search. Plus adds custom snooze times and nudges, unlimited history, rules (VIP senders, keyword alerts, mute, per-app quiet hours), the home-screen widget, export and backup, on-device summaries and reply drafts where the device supports them, and the extra themes and icons. The split is `docs/PLAN.md` section 3, and it is what PAY-4 is measured against.
3. (21 September 2026) **Plus is a one-time purchase, not a subscription** (PAY-1). Buyers of notification tools expect one-time, and no Plus capability costs anything per use, so there is no running cost to recover. A yearly subscription beside it is a decision for after launch, from the first quarter's numbers, not for v1.
4. (21 September 2026) **Sections 1 to 5 are kept as the kit wrote them** (REC, DEL, DATA, MONEY, DATE, BAK, RUN, LANG, LOCK). MONEY-1 is conditional on the app handling money and this one does not, so it never fires; it stays rather than being renumbered around. `/spec <area>` refines each section before the PR that implements it.

## Roadmap impact
<!-- Rules that change the data model or the build order, and where they land in docs/ROADMAP.md. Schema changes go in Phase 1. -->
<!-- Rules that change the data model or the build order, and where they land in docs/ROADMAP.md. Schema changes go in Phase 1. -->
