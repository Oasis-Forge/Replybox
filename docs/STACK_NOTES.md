# Stack notes: Flutter

Read on demand: the fill-ins `/kickoff` uses, and the traps earlier Flutter apps ran into.

## Fill-ins

| Placeholder | Value |
|---|---|
| `STACK` | `Flutter x.y.z / Dart x.y.z` from `flutter --version` |
| `FLUTTER_VERSION` | the Flutter version alone; it's used by `ci.yml`, `release.yml`, and `claude.yml` |
| `CMD_INSTALL` | `flutter pub get > $null` |
| `CMD_ANALYZE` | `flutter analyze` |
| `CMD_FORMAT` | `dart format lib test` |
| `CMD_FORMAT_CHECK` | `dart format --output=none --set-exit-if-changed lib test` |
| `CMD_TEST_FILE` | `flutter test test/<file>_test.dart` |
| `CMD_TEST_ALL` | `flutter test -r failures-only` |
| `CMD_COVERAGE` | `flutter test --coverage` (writes `coverage/lcov.info`) |
| `CMD_BUILD_RELEASE` | `flutter build apk --release`, then `flutter build appbundle --release` (they write `build/app/outputs/flutter-apk/app-release.apk`, `build/app/outputs/bundle/release/app-release.aab`, and Play's `build/app/outputs/mapping/release/mapping.txt`; copy them out with Bash `cp`) |
| `CMD_RUN` | `flutter run` |

SDK: if `flutter` isn't on PATH, or PATH points at a different SDK than CI pins, use `D:\Desktop\projects\flutter_sdk\flutter\bin\flutter.bat`, with `dart.bat` next to it. The format hook formats with the SDK `FLUTTER_ROOT` names, then that folder, then whatever `dart` is on PATH; set `FLUTTER_ROOT` on a machine where the SDK lives elsewhere.

## Scaffold

From the repo root, after the kit is copied (it keeps existing files):

```bash
flutter create --org <APP_ID without its last part> --project-name <snake_case_name> --platforms android,ios .
```

Add `windows,macos,linux` to `--platforms` if desktop is a target. Then:
- `pubspec.yaml`: `version: 0.1.0+1`. The version lives only there; Android and iOS read it from pubspec.
- Set the Android `applicationId`/`namespace` and the iOS/macOS bundle IDs to `APP_ID` exactly. `flutter create` appends the project name to the org.
- `.gitignore`: add `/dist/`, `/coverage/`, `/store/`, `android/key.properties`, and `*.jks`.
- `analysis_options.yaml`: add `unawaited_futures`, `prefer_single_quotes`, `prefer_const_constructors`, and `always_declare_return_types`.
- **Release signing has to be wired in by hand.** `flutter create` generates no signing config, so a release build is debug-signed even with `android/key.properties` present and every CI secret set — and Play rejects the upload for not matching the upload certificate. Add this to `android/app/build.gradle.kts` above `android {`, and the `signingConfig` line inside `buildTypes`:

  ```kotlin
  import java.util.Properties

  val keystoreProperties = Properties().apply {
      val f = rootProject.file("key.properties")
      if (f.exists()) f.inputStream().use { load(it) }
  }

  android {
      signingConfigs {
          create("release") {
              keystoreProperties.getProperty("storeFile")?.let { storeFile = file(it) }
              storePassword = keystoreProperties.getProperty("storePassword")
              keyAlias = keystoreProperties.getProperty("keyAlias")
              keyPassword = keystoreProperties.getProperty("keyPassword")
          }
      }
      buildTypes {
          release {
              // Falls back to the debug key when key.properties is absent, so a local
              // release build still works; release.yml checks the bundle's real
              // certificate, so CI cannot ship a debug-signed one by accident.
              signingConfig = if (rootProject.file("key.properties").exists()) {
                  signingConfigs.getByName("release")
              } else {
                  signingConfigs.getByName("debug")
              }
          }
      }
  }
  ```

  On the Groovy `build.gradle`, the same thing with `def keystoreProperties = new Properties()` and `signingConfigs { release { ... } }`.
- `release.yml` dumps the release APK's permissions and hands them to `tool/check_permissions.sh`, which compares them against the `ALLOWED` list in that workflow (RUN-2) **both ways**: a permission a plugin added fails the release, and so does one the app needs and quietly lost. Add each permission as a shipped feature needs it, space-separated (`android.permission.POST_NOTIFICATIONS`), and update the privacy policy in the same PR. An empty `ALLOWED` means "declares none", not "allow anything".
- Delete the `desktop` job in `ci.yml` if desktop isn't a target, and the `ios` job if iOS isn't.

## Don't read

`build/`, `.dart_tool/`, `android/.gradle/`, `ios/Flutter/ephemeral/`. Grep `pubspec.lock` and `ios/Runner.xcodeproj/project.pbxproj`; never read them whole. Open `android/ ios/ linux/ macos/ windows/ web/` only for platform tasks.

## Architecture that worked

- `lib/models/`: pure classes with `toMap`/`fromMap`, and `copyWith` using a sentinel so nullable fields can be cleared. Calculations live here as pure functions, so they're easy to test.
- `lib/db/`: a `DBHelper` sqflite wrapper with an ordered list of migration steps. Never edit a merged step or the version-1 create.
- `lib/providers/`: `provider` + `ChangeNotifier`; write first, then change state, roll back on failure. Don't add another state library.
- `lib/services/`: device services behind interfaces (`Noop…` for tests, `Device…` built only in `main.dart`). A real service as a default parameter hung the test suite for 10 minutes.
- `lib/screens/`: presentational; `context.read/watch<Provider>()`.
- `lib/l10n/`: ARB files → generated `AppLocalizations`, committed. CI runs `flutter gen-l10n` and then `git diff --exit-code -- lib/l10n`.
- `test/helpers.dart`: `FakeDB`, `testApp`, and fixture builders. Database tests use `sqflite_common_ffi` in memory.

## Traps

- **Right-to-left:** use `EdgeInsetsDirectional` and `AlignmentDirectional`, and wrap amounts and numbers in `textDirection: TextDirection.ltr`. `intl` exports its own `TextDirection`, so import it with `hide TextDirection`.
- **Currency in right-to-left languages:** `NumberFormat.simpleCurrency` gives Latin symbols in Arabic (`SAR`, not `ر.س.`), and the Arabic pattern adds right-to-left marks. Use the local symbol from CLDR, and when an amount sits inside right-to-left text, wrap it in U+2066…U+2069 (a left-to-right isolate), built with `String.fromCharCode`.
- **`in_app_purchase` on Android:** closing the purchase sheet without buying can arrive as a purchase update with an empty `productID` (status canceled, error, or even purchased). Treat it as the sheet closing, or the screen waits for the store forever. `buyNonConsumable` returning `false` means the sheet never opened. Test every way the sheet can end, closing it included.
- **`google_mobile_ads` banner size is a real trade-off, not a lookup.** The large anchored adaptive size can reserve up to 15% of the screen height and leaves blank bands around the ad. The standard one, `getCurrentOrientationAnchoredAdaptiveBannerAdSize`, keeps the ad flush with the bottom — but it was deprecated in **8.0.0**, and the replacement the changelog names is `getLargeAnchoredAdaptiveBannerAdSize`: the large one. So there is no version of this where you get the tight banner from a supported call. Decide and date it: keep the deprecated call behind an explicit `// ignore: deprecated_member_use` with a comment saying why, knowing it will be removed; or take the large size and check against ADS-2 and ADS-3 that the reserved height still doesn't shift anything under a finger. What you cannot do is use it silently — `flutter analyze` makes warnings fatal by default, so the deprecated call fails the stack's own CI check until the ignore is there.
- `DateFormat` with a locale away from a screen (a widget payload, a PDF, a background task) needs `initializeDateFormatting` first. Screens get it from the Material delegate.
- `pumpAndSettle` never settles with some widgets (`PdfPreview`, endless animations). Pump until a condition holds instead.
- Windows and Linux need `sqflite_common_ffi` set up in `main.dart`, with the database in the app support folder. Web has no sqflite.
- `local_auth`: Android's `MainActivity` must be a `FlutterFragmentActivity` with an AppCompat launch theme, and iOS needs `NSFaceIDUsageDescription`.
- Some plugins need the MSVC ATL component on Windows, so CI installs it.
- Plugins add permissions silently. Check the release APK with `aapt2 dump permissions`, and prefer ~100 lines of platform-channel glue over a package that brings in WorkManager or boot receivers.
- `pdf` package: use static TTF fonts (variable fonts lose their weights), and set text direction per run on right-to-left pages. Test a PDF by reading its text back, not by byte count.
- Writing `\u` escapes has put literal invisible characters in files. Use `String.fromCharCode` instead.
- The format hook may use a different SDK than CI. Point `FLUTTER_ROOT` at the SDK CI pins, and run that SDK's `dart format lib test` before committing.
- Icons and splash: draw them in a test (`tool/render_app_icons_test.dart`), then run `dart run flutter_launcher_icons` and `dart run flutter_native_splash:create`, and commit the generated files.

## Device drill (Android emulator, Git Bash)

`/emulator` does all of this as text through `tool/emu.sh`, with a snapshot before each test; the commands below are for doing it by hand. `bash tool/emu.sh app` prints the application id `launch` uses: it reads `applicationId` from the Android build file, so the tool carries no placeholder and kit fixes reach it outright; set `APP_ID` to override.

```bash
"$LOCALAPPDATA/Android/Sdk/emulator/emulator.exe" -avd Medium_Phone -no-boot-anim
adb install -r dist/<slug>-X.Y.Z.apk
adb shell am start -S -n <APP_ID>/.MainActivity
```

- Screenshots need `MSYS_NO_PATHCONV=1` on both halves: `adb shell "screencap -p /sdcard/s.png"`, then `adb pull /sdcard/s.png <local>`. Without it, Git Bash rewrites `/sdcard`.
- A long press or drag needs `input motionevent DOWN x y`, a sleep, `MOVE`s, and `UP` as separate calls. `input swipe` is too smooth for the launcher.
- Screenshot coordinates are in the displayed image's frame; scale them before tapping.
- In a right-to-left locale the app bar is mirrored, so the overflow menu is on the left.
- Check the screen after every navigation step: blind batches of taps go wrong without anyone noticing. Check it by reading it, not by photographing it — `/emulator` lists the screen as text for a fraction of a screenshot. Screenshots stay for what has to be judged by eye (`CLAUDE.md` → Token rules). Driving by hand without `/emulator`, `adb shell uiautomator dump` gives the same list.
- The first tap on a home-screen widget after `am force-stop` gets eaten. Tap again before concluding it's broken.
- The emulator holds the user's own test data. Back up in the app first, and restore or undo every change before finishing.

### Notification capture on the emulator (API 37 / Android 17, 21 September 2026)

Facts that cost real time to find, all of them about this system image rather than about the app:

- **There is no `sqlite3` binary on the image.** The app's database is private, so neither `adb shell sqlite3` nor `adb pull` reaches it. Copy the bytes out through `run-as` and query them on the host:
  ```bash
  adb exec-out run-as com.oasisforge.replybox cat databases/replybox.db > "$TMP/replybox.db"
  ```
  `exec-out`, not `shell`: `shell` translates newlines and corrupts the file. Do it with the app stopped, or a write-ahead log holds rows the copy will not have.
- **That command fails on a fresh install, and the failure reads like a broken command.** `databases/replybox.db` does not exist until Dart has opened the database once, so on a device the app has been installed on but never launched, `run-as ... cat` answers `No such file or directory` and writes a zero-byte file the host then fails to open. The file is missing because the app has not run, not because the path or the `run-as` is wrong. **Launch the app once first** — `adb shell am start -S -n com.oasisforge.replybox/.MainActivity` — and check with `adb shell run-as com.oasisforge.replybox ls databases`. `bash tool/spike.sh db [file]` does the check, says exactly this when it fails, and copies the file when it does not.
- **A debug build declares TWO notification listeners** — the shipped `ReplyboxListenerService` and the spike's — and both appear on Android's notification-access screen under the same app label. Leave the spike one **off** for any drill about shipped behaviour: it writes a world-readable dump into external storage, sees every package, and its rows are indistinguishable from the shipped listener's at a glance. Turn it on only for the CAP-21 drill below, which is the one drill the shipped listener cannot run — and which, in its second half, reaches the shipped capture path through `SpikeCaptureBridge` instead. Leave that bridge off too unless the drill you are running is that one.
- **`cmd notification post -S messaging` cannot produce a null `Person`.** It substitutes a `Person` named `Them` on every history entry, so the shell can never post the shape INB-9 turns on — the owner's own line, which Google Messages writes with *neither* sender key. A real app's inline reply in the shade is the only way to make one. Three rounds of fixes hid a defect behind that gap.
- **A shell-posted `MessagingStyle` carries no `category` key at all**, and `cmd notification post` has no flag to set one. So CAP-21's gate cannot be opened from the shell, in either direction.
- **The shade's "Clear all" arrives as `CANCEL_ALL`, not `LISTENER_CANCEL_ALL`.** All six removals in the drill carried `"removalReasonName":"CANCEL_ALL"`. CAP-22 ignores both, so behaviour is right — but any note or test naming `LISTENER_CANCEL_ALL` as the shade-clear reason is describing something else.
- **`raw-nocategory` arrives with no `category` key at all, not `"category": null`.** The shape is built by never calling `setCategory`, and that is what the bundle carries: the key is absent. `Notification.category` reads back as `null` either way, so CAP-21's gate closes the same, but a dump line and a fixture are not interchangeable — a fixture written with `"category": null` is testing a key that a real uncategorised notification does not have. Written by the projection through org.json, a null value drops the key, so the dump and the device agree; a fixture hand-written with an explicit null does not.
- **An emptied title arrives as `""` and an absent title arrives with no `title` key.** Genuinely different bytes on the wire, from `setContentTitle("")` and from never calling it. That is the distinction CAP-8's residual turns on — a value Android emptied is redaction, a key that was never set is an app that set no title — and it is now observed rather than assumed (shapes `title-empty` and `title-absent`, 21 September 2026).
- **The system posts its own group summaries under our package.** Three `isGroupSummary: true` rows arrived under `0|com.oasisforge.replybox|g:Aggregate_SilentSection`, which the app never created: the platform's aggregate for the silent notification section, posted on the app's behalf. One of them had inherited `isOngoing` from an ongoing child. CAP-6 drops every summary, so the outcome is right, but nothing in the rules anticipated a summary the app did not post — a shipped app could receive the same aggregate from a third-party package, and a rule that reasoned about "the summary the app posted" would be reasoning about a notification that has no author.
- **`adb shell input text` goes through the keyboard, and the keyboard auto-capitalises.** Typing the same words into the shade's reply field twice produced `repeat probe` and then `Repeat probe` — two different messages, so a drill meant to prove that a *genuine* repeat is stored twice proved nothing instead. It is silent: the dump and the database both look right, and only the capital letter says the test never ran. Type text that already starts with a capital, and read the text back out of the queue before trusting the step (drill, night of 21 September 2026).
- **Past two conversations the shade groups them, and a reply then needs two expands.** With one notification the `Reply` action is on screen. With two, Google Messages posts them under one group: the group has an `Expand`, and each child inside it has its own `Expand`, and `Reply` only appears after both. A script that looks for `Reply` and gives up is reporting the shade's layout, not a missing action.
- **A reconnect re-queues every active notification.** After a `force-stop` the listener re-reads `getActiveNotifications()` and appends posts it has already queued and had acked, with their original `postTime` — so a queue pulled after a restart holds lines older than the `listener_connected` above them. That is CAP-13 working, not a failed ack; the alignment recognises them and writes nothing.
- **`cmd notification redact_otp_from_untrusted_listeners` no longer runs from the shell**: it answers `Package android does not belong to 2000` for both `true` and `false`. Redaction is on by default at this level, so nothing was affected, but a run that "turned it off" first was a run with it on. `tool/spike.sh redact` is gone for that reason.

### Drill: CAP-21's raw path, CAP-6, CAP-7 and CAP-8's title

CAP-21 keeps a non-`MessagingStyle` notification as one `raw` line when its category is `msg`, `social` or `email`, and offers a reply only when the notification itself carries a `RemoteInput`. Nothing on the device posts that shape: `cmd notification post` has no category flag, and no installed app posts one on demand. `SpikeRawPoster` (debug source set only) does, and `tool/spike.sh` drives it.

**Read this first — the drill has two halves and they prove different things.**

The poster posts under Replybox's own package, and `ReplyboxListenerService` drops `sbn.packageName == packageName` as the first statement of both its entry points (PERM-12). That drop is unconditional, in every build, and stays that way: `OwnPackageGuardTest` fails if it grows a condition, moves below anything, or is deleted, and fails again if any file under `src/main` so much as names the debug-only bridge below. So the **shipped listener** stores nothing from this drill, by design — measured on 21 September 2026: 11 notifications posted, the included-apps store 5/1/1 before and after, zero `raw` rows.

*Half one, the platform half (steps 1–9).* What the device actually delivers for each shape, read off the spike listener: whether `category` survives, whether `EXTRA_TITLE` arrives absent or as `""`, whether the ongoing and group-summary flags are set, whether a `RemoteInput` round-trips. Those are exactly the fields `NotificationProjection.isCapturable` gates on. This half needs no bridge.

*Half two, the storage half (steps 10–14).* CAP-21's storage behaviour — one raw message per notification, the app as the thread, a three-times re-post leaving one row, CAP-6 and CAP-7 actually dropping — had no device evidence at all, and cannot get any from the shipped listener for the reason above. `SpikeCaptureBridge` (debug source set, off until `spike.sh bridge on`) replays the poster's notifications through the **shipped** projection, store and queue with **one field substituted**: `package` becomes `com.oasisforge.spikeraw`, and `bridgedFrom` is written beside it so the queue file says so. Everything else is the platform's own bytes and the shipped code.

**What half two is not.** It is not a third-party app. The listener's own read of a genuine third-party package — CAP-1's first sighting, the package-manager label lookup, the package filter — stays undriven. And the inbox row it produces is **not what a user would see**: it is what a user would see if a third-party app posted that exact notification. PERM-12's user-visible promise holds throughout (Replybox never appears in its own included-apps list; the substituted package is not the app's id and not under it), but its other sentence does not: with the bridge open, text the app posted itself does reach the native queue. That is why the bridge is opt-in per drill, why `spike.sh reset` turns it off, and why step 14 deletes what it stored. CAP-21 comes off provisional (CAP-25) only with a second debug APK carrying its own `applicationId`, or a real third-party app that posts the shape — not with this.

1. `flutter build apk --debug`, then `bash tool/spike.sh install`.
2. `bash tool/spike.sh grant-post`. Without `POST_NOTIFICATIONS` the poster's `notify` is a silent no-op that reads exactly like a broken receiver; the poster writes `"result":"notifications_disabled"` into the dump rather than letting you guess.
3. `bash tool/spike.sh reset`, then `bash tool/spike.sh enable`. This is the drill that needs the spike listener on — it is the only reader that sees our own package.
4. Launch the app once (`adb shell am start -S -n com.oasisforge.replybox/.MainActivity`), then copy the database out and count the rows, so step 9 has a before: `bash tool/spike.sh db "$TMP/before.db"`. The launch is not optional — the database file does not exist until Dart opens it, and the copy fails with `No such file or directory` on a fresh install.
5. `bash tool/spike.sh raw`. Twelve shapes, one second apart, plus one id re-posted three times.
6. `bash tool/spike.sh pull docs/research/spike-dumps/<date>-raw-shapes.jsonl`, and add its line to that folder's README saying which projection wrote it — the spike listener's, not the shipped one's.
7. Read the dump in pairs. Every shape appears twice: a `"event":"post_request"` row saying what was **built**, then the listener's `"event":"posted"` row saying what **arrived**. The pairing is the whole point; a field the platform rewrote is visible without a second source.
8. Check each shape against the rule it exists for:
   - `raw-msg`, `raw-social`, `raw-email` — `category` arrives as `msg`/`social`/`email` and `template` is absent. That is CAP-21's gate open, and it is the first device evidence it has ever had.
   - `raw-nocategory` — `category` is `null`. The gate must stay shut; this is the promotion that must never become a message (CAP-2).
   - `raw-reply` — `hasRemoteInput` is `true` and the action's `resultKey` is present. Run `bash tool/spike.sh reply` and look for `"event":"poster_reply_received"` with the text: that closes CAP-21's reply clause rather than merely observing an action exists.
   - `title-empty` versus `title-absent` — `"title":""` against `"title":null`. `""` is a value and survives; absent is a different fact. CAP-8's hidden check turns on exactly that distinction and `NotificationProjection` documents it as a residual, so it needs a dated observation and not an assumption.
   - `ongoing` — `isOngoing` is `true` (CAP-7). Check the field, do not assume the flag: Android 14 changed what `setOngoing` means for a notification with no foreground service behind it.
   - `summary` and `summary-child` — the summary's `isGroupSummary` is `true` and its `messages` array is empty, while the child arrives beside it carrying the content. That is CAP-6's whole justification, and it had been inferred from whatever the first spike happened to capture.
   - `repost` — one id, three `posted` rows, a different text each time. Two posts can pass a dedup that only compares against the last row, and a chat notification updating as lines arrive posts the same id many times over; three is the everyday shape CAP-5 has to survive. `bash tool/spike.sh repost 5` drives it harder.
   - `raw-otp` beside `raw-otp-control` — the same raw shape, one with a code in its text and one without. The app cannot make a redaction marker and must not try: CAP-8 recognises a hidden message structurally and never by matching the system's string, and only Android's own OTP redaction can produce one. So this is a question, not an assertion, and **both answers are results**: if `raw-otp`'s `text` comes back altered while the control comes back intact, CAP-8's residual has device evidence on CAP-21's path; if both come back intact, the answer on the record is that redaction does not apply to a non-`MessagingStyle` notification at this level, and CAP-8's raw-path residual stays undriven. Redaction cannot be switched off here (`spike.sh redact`), so whatever arrives is what the platform does.
9. Fire the reply if you have not: `bash tool/spike.sh reply`. Then copy the database out again (`bash tool/spike.sh db "$TMP/after-platform.db"`) and diff the row counts against step 4. They must be **identical**: twelve shapes posted, nothing stored. That is PERM-12's own-package drop observed rather than read, and it is why half one can never stand in for the storage half.

Half two — CAP-21's storage path. Read the caveat above again before recording anything from here as CAP-21 evidence.

**And read this before running it: half two is blocked on a screen that does not exist yet (night of 21 September 2026).** Step 11 asks you to switch `com.oasisforge.spikeraw` on in Included apps. There is no Included-apps screen — `lib/` has no `screens/` folder and `main.dart` shows a placeholder. `Repository.setAppEnabled` and `InboxProvider.setAppEnabled` exist and nothing calls them, so the only thing that could flip the row is a UI that is not built. Driven that far and no further: with the bridge on, `spike.sh post raw-msg` put `com.oasisforge.spikeraw` into `files/capture-store.json` as `pending`, `enabledByDefault:false`, labelled with the package name, wrote `"result":"package_off"` into the dump, queued nothing and stored nothing — CAP-1's first sighting observed, and PERM-12 holding (Replybox is in neither `everSeen` nor `pending`). Everything past that gate — one raw message per notification, the app as the thread, a three-times re-post leaving one row, CAP-6 and CAP-7 dropping, CAP-8's residual on a raw line — is still undriven. Writing the `enabled` row by hand is not a substitute: it skips the step the bridge exists to keep.

10. `bash tool/spike.sh bridge on`. It prints `bridge ON` and names the substituted package. Nothing is stored yet.
11. `bash tool/spike.sh post raw-msg`. Still nothing stored, and that is the point: CAP-1 leaves an app off until the user turns it on, so the first sighting only puts a row in the chooser. Open the app → Included apps, and switch **com.oasisforge.spikeraw** on. It shows as its package name, because no app of that name is installed and the shipped label lookup falls back to the package — the same fallback a real app gets when the package manager cannot see it. Replybox itself must **not** appear anywhere in that list; if it does, stop, because PERM-12 is broken and the bridge is not what broke it.
12. `bash tool/spike.sh raw`, then `bash tool/spike.sh db "$TMP/after-bridge.db"` and read the rows:
    - `raw-msg`, `raw-social`, `raw-email` — one `messages` row each, `kind` `raw`, in a conversation whose key is the package alone and whose label is the package name. First device evidence CAP-21's storage clause has ever had.
    - `raw-nocategory` — no row. The promotion that must never become a message (CAP-2).
    - `ongoing`, `summary` — no rows, and `"result":"not_capturable"` in the dump beside each. That is the **shipped** `isCapturable` dropping them (CAP-6, CAP-7), not the bridge.
    - `repost` — three `posted` events, **one** message row, the text of the last one. More than one row is CAP-5 failing on the everyday shape.
    - `title-empty` versus `title-absent` — both stored, and the stored text differs the way the dump's `""` and absent key differ (CAP-8's residual).
    - `raw-reply` — stored with a reply offered; the others stored without one (CAP-21's `RemoteInput` clause).
13. `bash tool/spike.sh dismiss` and read the `"event":"bridge"` lines for `"bridgedEvent":"removed"`: a removal reaches the queue too, so CAP-22 sees the same thing it would see for a third-party notification.
14. Put the device back, and do not skip any of it: `bash tool/spike.sh bridge off`, delete the `com.oasisforge.spikeraw` conversation and switch that app off in Included apps (or clear the app's data), `bash tool/spike.sh disable`, `adb shell pm revoke com.oasisforge.replybox android.permission.POST_NOTIFICATIONS`, and clear the shade. `bash tool/spike.sh reset` also turns the bridge off, so a later drill cannot inherit it.
