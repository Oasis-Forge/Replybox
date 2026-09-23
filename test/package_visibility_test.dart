/// The promise the developer made to users on 22 September 2026 (decision 13,
/// INB-20's correction of 23 September, CAP-27).
///
/// The manifest's `<queries>` now carries a launcher intent filter, so **every
/// app on this phone with an icon the user could tap is visible to this
/// process**. That was chosen with the cost in front of the developer, and it is
/// not what this file is about. This file is about the half that was bought back
/// in exchange:
///
/// > Replybox can *see* which apps are launchable, but only ever *asks* about a
/// > package that has already sent the user a notification. It never lists what
/// > is on the phone.
///
/// **Nothing but a test stands behind that sentence now.** Until the filter
/// landed, the manifest enforced it: a lookup for an undeclared package answered
/// nothing whatever the code did. From today a lookup that grew into an
/// enumeration would add no permission, fail no gate that reads a manifest, show
/// nothing on the store page, and change nothing a reviewer or a user could see.
/// `tool/check_queries.sh` keeps the part that is still checkable — what the
/// built manifest declares — and `test/manifest_test.dart` keeps the source half
/// of it. Neither can see a line of Kotlin.
///
/// So the assertions below are made against the **source**, which is unusual
/// here and deliberate. The behaviour they stand for is executed by
/// `SourceAppInfoTest` and `AppLaunchTest` on the JVM, where a fake
/// `PackageFacts` can record that it was never asked; what a JVM test cannot do
/// is notice a *second* call site somewhere else in the app that never goes
/// through the gate at all, or a new helper that asks the platform for a list.
/// Those are the two ways this promise breaks in practice, and they are what
/// this file looks for.
///
/// The Dart half is here too, because INB-20 states the rule about the app and
/// not about one layer of it: "in the capture package **or in Dart**, in any
/// build."
///
/// What is *not* here, to keep one copy of each fact: `SourceAppInfoTest`
/// executes the gate against a fake `PackageFacts` that records whether it was
/// asked, `QueriesDeclarationTest` owns the list of Kotlin files allowed to hold
/// a `PackageManager`, `manifest_test.dart` owns what `<queries>` declares, and
/// `tool/check_queries.sh` owns the built manifest on every release.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final Directory kotlin = Directory(
    'android/app/src/main/kotlin/com/oasisforge/replybox',
  );
  final Directory dart = Directory('lib');

  /// Source with every comment removed.
  ///
  /// Load-bearing, exactly as it is in `manifest_test.dart`. INB-20's rule is
  /// quoted in the source it governs: `SourceAppInfo.kt`, `AppLaunch.kt`, the
  /// manifest and `lib/services/android_package_service.dart` all write out
  /// `getInstalledApplications` and `queryIntentActivities` by name in order to
  /// say the app calls neither. A test reading raw text would fail on the
  /// paragraph explaining why the thing it forbids is absent — and, far worse,
  /// would then be "fixed" by deleting the explanation.
  String code(File file) => file
      .readAsStringSync()
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');

  /// Every source file under [dir] with the given extension, comments stripped,
  /// by path.
  Map<String, String> sources(Directory dir, String extension) {
    expect(
      dir.existsSync(),
      isTrue,
      reason:
          '${dir.path} is gone, so this test scanned nothing. A promise '
          'checked by a test that reads no files is not checked (INB-20).',
    );
    final Map<String, String> found = <String, String>{};
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith(extension)) continue;
      found[entity.path.replaceAll(r'\', '/')] = code(entity);
    }
    expect(found, isNotEmpty, reason: 'no $extension files under ${dir.path}');
    return found;
  }

  group('what the app never does: call anything that returns a list '
      '(INB-20, decision 13)', () {
    /// Every platform call that answers with more than one package, and the
    /// bare-intent resolve that is the same question asked sideways.
    ///
    /// INB-20 names the first three itself. The rest are here because the rule
    /// is about the shape of the question and not about a list of method names
    /// somebody remembered: any of these turns "which apps are on this phone"
    /// into one call, and with the launcher filter in `<queries>` every one of
    /// them would now answer.
    const Map<String, String> enumerating = <String, String>{
      'getInstalledPackages': 'every package on the phone',
      'getInstalledApplications': 'every application on the phone',
      'getInstalledModules': 'every installed module',
      'queryIntentActivities':
          'every activity matching an intent — against the '
          'launcher filter, that is the home screen',
      'queryIntentServices': 'every service matching an intent',
      'queryBroadcastReceivers': 'every receiver matching an intent',
      'queryContentProviders': 'every provider on the phone',
      'getPackagesForUid': 'every package sharing a uid',
      'getPackagesHoldingPermissions': 'every package holding a permission',
      'getPreferredPackages': 'the user\'s preferred packages',
      'resolveActivity':
          'the app behind a bare intent, which is the same '
          'question about the phone asked one answer at a time',
    };

    for (final MapEntry<String, Directory> tree in <String, Directory>{
      'Kotlin': kotlin,
      'Dart': dart,
    }.entries) {
      test('no ${tree.key} source enumerates what is installed', () {
        final Map<String, String> files = sources(
          tree.value,
          tree.key == 'Kotlin' ? '.kt' : '.dart',
        );
        final List<String> found = <String>[];
        for (final MapEntry<String, String> file in files.entries) {
          for (final MapEntry<String, String> banned in enumerating.entries) {
            if (file.value.contains(banned.key)) {
              found.add('${file.key}: ${banned.key} — ${banned.value}');
            }
          }
        }
        expect(
          found,
          isEmpty,
          reason:
              'INB-20 and decision 13: "what the app never does: call anything '
              'that returns a list." Since the launcher intent filter landed in '
              '<queries>, these calls answer for every app the user could tap, '
              'and nothing on the platform refuses them any more — no '
              'permission, no manifest gate, nothing on the store page. This '
              'test is the whole of what stands there, and the privacy policy '
              'says the app never lists what is on the phone (CAP-27). Found:\n'
              '${found.join('\n')}\n\n'
              'If a later area genuinely needs a package the user has never '
              'been notified by, decision 13 already answers it: ask the user '
              'for it, do not widen the lookup.',
        );
      });
    }

    test('QUERY_ALL_PACKAGES is named nowhere in the app source', () {
      // The manifest half is `manifest_test.dart`'s; this catches it arriving
      // through a Gradle file, a plugin's merged manifest snippet checked in
      // here, or a string built at runtime.
      final List<String> found = <String>[
        for (final MapEntry<String, String> file in <MapEntry<String, String>>[
          ...sources(kotlin, '.kt').entries,
          ...sources(dart, '.dart').entries,
        ])
          if (file.value.contains('QUERY_ALL_PACKAGES')) file.key,
      ];
      expect(found, isEmpty, reason: 'INB-20: found in $found');
    });
  });

  group('what the app asks: one package, by name, and only one it was already '
      'handed (INB-20)', () {
    File file(String name) => File('${kotlin.path}/capture/$name');

    test('the gate is the shipped six plus what this install has seen post, '
        'and nothing else', () {
      // `mayAsk` is public and separate from `lookup` precisely so the rule can
      // be read and asserted as itself. If it is inlined back into its callers
      // this test fails, and it should: the rule then has no name, two call
      // sites and no single place to check.
      final String source = code(file('SourceAppInfo.kt'));
      final int gate = source.indexOf('fun mayAsk');
      expect(
        gate,
        isNonNegative,
        reason:
            'No `fun mayAsk` in SourceAppInfo.kt. INB-20: "a package is askable '
            'when it has a row in `apps` ... or when it is one of the six in '
            'the shipped constant." That rule is the only thing keeping the '
            'privacy policy true and it needs a name.',
      );
      // The body, up to whatever declaration follows it.
      final int next = source.indexOf('fun ', gate + 'fun mayAsk'.length);
      final String body = source.substring(
        gate,
        next < 0 ? source.length : next,
      );

      expect(
        body,
        contains('ShippedApps.PACKAGES'),
        reason:
            'INB-20\'s first source: the six compiled into the binary, named in '
            'the manifest and shown in full by PERM-3 before any access is '
            'granted, so the only fact asking about them adds is whether this '
            'phone has them.',
      );
      expect(
        body,
        contains('hasPosted'),
        reason:
            'INB-20\'s second source, and the half the user was promised: a '
            'package is askable only once it has actually posted a notification '
            'this listener saw. Without it the gate is the shipped list again '
            'and INB-13\'s control goes back to failing for every app that '
            'joined the inbox by posting.',
      );
      expect(
        body,
        isNot(contains('packageManager')),
        reason:
            'The gate decides whether to ask the phone. Asking the phone inside '
            'it is the question already put.',
      );
      expect(
        body,
        isNot(contains('enabled')),
        reason:
            'INB-22: turning a row off changes nothing on screen but the '
            'switch. Its conversations keep their label, their icon and '
            'INB-16\'s presence, so the gate reads what has been *seen*, never '
            'what is currently captured.',
      );
    });

    /// Every call that puts a question to the phone about one named package.
    ///
    /// Receiver-qualified on purpose: `facts.faceOf(...)` is an ask, and the
    /// `fun faceOf` that declares it and the `override fun faceOf` that
    /// implements it are not. What is counted here is call sites.
    final RegExp asks = RegExp(r'\.(faceOf|appLauncher)\(');

    test('every ask is refused before the platform is touched, in whatever '
        'file it is written', () {
      // INB-20: "a lookup for a package with no `apps` row and not in the
      // shipped constant is refused **before the platform is touched**." An
      // answer fetched and then thrown away is not this rule: the promise is
      // that the app did not ask, and Android has already been told the
      // question by then.
      //
      // Scanned over the whole capture package rather than over the two call
      // sites that exist today, because the way this promise actually breaks is
      // a *third* caller — a screen that wants an icon, a later area that wants
      // to know whether an app is there — written by somebody who never read
      // this file. The gate is a function, so calling `faceOf` without it is
      // one line that compiles, passes every other test, and reads as
      // perfectly ordinary code.
      final List<String> ungated = <String>[];
      int found = 0;
      for (final MapEntry<String, String> file in sources(
        kotlin,
        '.kt',
      ).entries) {
        for (final RegExpMatch ask in asks.allMatches(file.value)) {
          found += 1;
          // The declaration this call sits inside, and the gate has to be
          // between the two.
          final int fn = file.value.lastIndexOf('fun ', ask.start);
          final int gate = file.value.lastIndexOf('mayAsk(', ask.start);
          if (fn < 0 || gate < fn) {
            ungated.add(
              '${file.key}: ${ask.group(0)} at ${ask.start}, '
              'enclosing fun at $fn, nearest mayAsk at $gate',
            );
          }
        }
      }

      expect(
        found,
        greaterThanOrEqualTo(2),
        reason:
            'Fewer asks than the two INB-13 and INB-16 are built on '
            '(SourceAppInfo.lookup and AppLaunch.openApp). Either they were '
            'renamed — in which case this test is scanning for nothing and has '
            'to follow them — or the app stopped asking, which is a product '
            'change and not a refactor.',
      );
      expect(
        ungated,
        isEmpty,
        reason:
            'A question is put to the phone about a package without going '
            'through SourceAppInfo.mayAsk first. With the launcher intent '
            'filter in <queries> that call answers for any package name a '
            'caller passes, so it is the app reading what is on the phone one '
            'question at a time — the thing INB-20 and the privacy policy say '
            'it does not do (CAP-27, decision 13). The refusal has to come '
            'first: "the app did not ask" is the promise, and an answer '
            'discarded after the asking is not it.\n${ungated.join('\n')}',
      );
    });

    test('hasPosted answers from this install\'s own record, never from the '
        'phone', () {
      // The gate is only worth anything if the thing it consults is a record of
      // what has already arrived here. A `hasPosted` that resolved the question
      // against the package manager would gate every lookup on a lookup.
      final List<String> implementations = <String>[
        for (final MapEntry<String, String> file in sources(
          kotlin,
          '.kt',
        ).entries)
          for (final RegExpMatch match in RegExp(
            r'override fun hasPosted\([^)]*\)[^\n]*\n?[^\n]*',
          ).allMatches(file.value))
            '${file.key}: ${match.group(0)!.trim()}',
      ];
      expect(
        implementations,
        isNotEmpty,
        reason:
            'nothing implements hasPosted, so the gate has no second source',
      );
      for (final String implementation in implementations) {
        expect(
          implementation,
          contains('hasEverSeen'),
          reason:
              'INB-20: askability is read from the `apps` record this install '
              'wrote when a package posted — CaptureStore.hasEverSeen, which '
              'nothing removes from — and from nothing else. Found: '
              '$implementation',
        );
        expect(
          implementation,
          isNot(contains('packageManager')),
          reason:
              'A gate that asks the phone whether it may ask the phone is not a '
              'gate. Found: $implementation',
        );
      }
    });

    // The fourth thing this group would assert — that only SourceAppInfo.kt,
    // AppLaunch.kt and ReplyboxListenerService.kt hold a `PackageManager` at
    // all — is `QueriesDeclarationTest`'s, by name, on the Kotlin side. A second
    // hand-maintained allow-list of Kotlin file names in Dart would drift from
    // it and then be "fixed" by whichever copy someone read first. The scan
    // above is the part that does not duplicate it: it follows the call sites
    // rather than the files, so a new ask inside an allowed file is caught too.
  });

  group('the Dart side asks the same one question (INB-20)', () {
    test('the package service calls one channel method, with one package', () {
      // The Dart service is what a screen talks to, and it is where a "just
      // fetch them all in one round trip" optimisation would be written. There
      // is no such method on the channel and this is what keeps it that way:
      // `lookupPackage` takes a single package name, and the native gate is
      // applied to that name (SourceAppInfo.mayAsk).
      final String source = code(
        File('lib/services/android_package_service.dart'),
      );
      final Set<String> invoked = RegExp(
        r"invokeMethod[^(]*\(\s*'([^']+)'",
      ).allMatches(source).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(
        invoked,
        <String>{'lookupPackage'},
        reason:
            'INB-20: the app asks about one package at a time, by name. A '
            'second method here — or a plural one — is the round trip that '
            'turns a per-package question into a read of the phone.',
      );
    });

    test('the channel hands lookupPackage a single name and never a list', () {
      // The other end of the same call. `CaptureChannel` already has a
      // `stringList()` reader, used by the enabled-set and queue-ack methods, so
      // making this branch take a list would be a two-word edit.
      final String source = code(
        File('${kotlin.path}/capture/CaptureChannel.kt'),
      );
      final int branch = source.indexOf('"lookupPackage"');
      expect(branch, isNonNegative, reason: 'the lookupPackage branch is gone');
      final int next = source.indexOf('" ->', branch + 20);
      final String body = source.substring(
        branch,
        next < 0 ? source.length : next,
      );
      expect(
        body,
        contains('call.string()'),
        reason: 'INB-20: one package name per ask',
      );
      expect(
        body,
        isNot(contains('stringList')),
        reason:
            'INB-20: `lookupPackage` takes one package. A list here is a '
            'lookup that has grown into an enumeration by the back door, and '
            'the per-name gate in SourceAppInfo would be applied to whatever '
            'the caller chose to send.',
      );
    });
  });
}
