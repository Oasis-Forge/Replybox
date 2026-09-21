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
