import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The two manifest facts nothing else in the build checks (CAP-20, CAP-24).
///
/// Both are read out of the source XML as text, the way `shipped_apps_test.dart`
/// reads `ShippedApps.kt`, because a Dart test has no other way to reach them.
///
/// Why this file exists rather than a shell gate:
///
///  * **CAP-20.** `tool/check_permissions.sh` reads `uses-permission` lines and
///    nothing else — CAP-20 says so itself — so the `android:permission`
///    attribute on the listener `<service>` is invisible to it. That attribute
///    names the permission the *system* must hold to bind an exported service;
///    drop it and any app on the phone can bind Replybox's notification
///    listener. Nothing else in the build would notice.
///  * **CAP-24.** `tool/check_backup_rules.sh` says in its own header that it
///    can only confirm the built manifest still *points* at
///    `@xml/data_extraction_rules`: "emptying that file would pass here.
///    Nothing checks it today." This is what checks it.
///
/// The source manifest, not the built one: the merged manifest is what
/// `check_backup_rules.sh` reads, and these assertions are about what this
/// repository writes down. They are the other half of that gate, not a copy of
/// it.
void main() {
  final File manifest = File('android/app/src/main/AndroidManifest.xml');
  final File extractionRules = File(
    'android/app/src/main/res/xml/data_extraction_rules.xml',
  );

  /// The file with every `<!-- ... -->` removed.
  ///
  /// Load-bearing, not tidiness: the manifest's own CAP-20 comment contains the
  /// words `<uses-permission>`, and the extraction rules' header comment names
  /// `domain="file"` and `domain="sharedpref"`. A test reading the raw text
  /// would pass on a prose mention of the thing it is looking for and fail on a
  /// comment that merely discusses the thing it forbids.
  String withoutComments(File file) {
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '${file.path} is gone. A test that quietly checks nothing is exactly '
          'how an exported listener ships with no permission on it (CAP-20) or '
          'a backup exclusion goes missing (CAP-24).',
    );
    return file.readAsStringSync().replaceAll(
      RegExp(r'<!--.*?-->', dotAll: true),
      '',
    );
  }

  /// The opening tag of the `<service>` element whose `android:name` contains
  /// [nameFragment], attributes and all.
  String serviceTag(String xml, String nameFragment) {
    for (final RegExpMatch match in RegExp(
      r'<service\b[^>]*>',
      dotAll: true,
    ).allMatches(xml)) {
      final String tag = match.group(0)!;
      if (tag.contains(nameFragment)) return tag;
    }
    fail(
      'No <service> element naming $nameFragment in ${manifest.path}. CAP-20 '
      'makes notification access a service declaration rather than a requested '
      'permission, so if that declaration was renamed or removed this test has '
      'to follow it rather than quietly check nothing.',
    );
  }

  group('CAP-20 the listener service declaration', () {
    test('the listener still requires BIND_NOTIFICATION_LISTENER_SERVICE', () {
      // The one attribute that makes exporting this service safe. The system
      // holds BIND_NOTIFICATION_LISTENER_SERVICE and no other app does, so with
      // it the only binder is Android and without it every app on the phone can
      // bind Replybox's listener and talk to it. RUN-2's gate cannot see this:
      // it reads uses-permission lines and capture declares none (CAP-20), so
      // dropping the attribute is a silent change that ships.
      final String tag = serviceTag(
        withoutComments(manifest),
        'ReplyboxListenerService',
      );
      expect(
        tag,
        contains(
          'android:permission="android.permission.'
          'BIND_NOTIFICATION_LISTENER_SERVICE"',
        ),
        reason:
            'The listener <service> in ${manifest.path} no longer carries '
            'android:permission="android.permission.'
            'BIND_NOTIFICATION_LISTENER_SERVICE" (CAP-20). It is exported, so '
            'without that attribute any app on the device can bind it. '
            'tool/check_permissions.sh reads only uses-permission lines and '
            'will stay green on this.',
      );
    });

    test('the listener is exported, which is what makes the permission the '
        'only gate', () {
      // Stated beside the attribute above so the pair reads as one fact: an
      // exported service with a permission is a service only the system binds;
      // an exported service without one is open. If a later change makes this
      // service unexported the assertion above stops being about anything, and
      // this test says so rather than leaving it looking checked.
      final String tag = serviceTag(
        withoutComments(manifest),
        'ReplyboxListenerService',
      );
      expect(tag, contains('android:exported="true"'));
    });

    test('the main manifest declares no uses-permission at all (RUN-2, '
        'CAP-20)', () {
      // CAP-20: capture adds no uses-permission to the release build, and
      // PERM-15 keeps ALLOWED in release.yml empty. The release gate fails in
      // both directions, but it only runs on a release build; a plugin merge or
      // a stray copy-paste that adds one to this file should fail a test on the
      // branch that did it. Comments are stripped first because the CAP-20
      // comment in this very file writes the words out.
      expect(
        withoutComments(manifest),
        isNot(contains('<uses-permission')),
        reason:
            '${manifest.path} declares a uses-permission. Product principle 1 '
            'and CAP-20: capture requests no permission, notification access is '
            'a service declaration, and ALLOWED in release.yml is empty '
            '(RUN-2, PERM-15). If a permission is genuinely needed it is a '
            'product decision with a rule behind it, not a manifest edit.',
      );
    });
  });

  group('INB-16, INB-20 what <queries> declares (decision 13)', () {
    /// The body of the `<queries>` element, comments removed.
    ///
    /// Comments have to go first here more than anywhere else in this file: the
    /// element now carries a long note that writes out `QUERY_ALL_PACKAGES`,
    /// `getInstalledApplications` and `queryIntentActivities` by name, to say
    /// that the app declares and calls none of them. A raw-text assertion would
    /// fail on the paragraph explaining why the thing it forbids is absent.
    String queries() {
      final RegExpMatch? match = RegExp(
        r'<queries\b[^>]*>(.*?)</queries>',
        dotAll: true,
      ).firstMatch(withoutComments(manifest));
      expect(
        match,
        isNotNull,
        reason:
            'No <queries> element in ${manifest.path}. INB-16 puts the app\'s '
            'whole package visibility in it, so a missing element is not a '
            'narrower app — it is every source app back to INB-16\'s `unknown` '
            'and INB-13\'s control gone from every thread.',
      );
      return match!.group(1)!;
    }

    test('QUERY_ALL_PACKAGES is declared nowhere', () {
      // Decision 13 widened visibility with a `<queries>` filter, which needs
      // no permission and shows nothing on the store page. This permission is
      // the thing that was never on the table: it would make INB-16's third
      // state unreachable and turn the "only ever asks about a package that has
      // already posted" restraint into decoration, because there would be
      // nothing left the app could not see. RUN-2's release gate fails on any
      // uses-permission, but this names the one that matters here so a failure
      // reads as the rule it broke.
      expect(
        withoutComments(manifest),
        isNot(contains('QUERY_ALL_PACKAGES')),
        reason:
            '${manifest.path} declares QUERY_ALL_PACKAGES (INB-20, decision '
            '13). The app asks about one named package at a time and never for '
            'a list; this permission is how that stops being true.',
      );
    });

    test('the launcher intent filter decision 13 bought is still there', () {
      // The developer took this trade deliberately on 22 September 2026: every
      // launchable app becomes visible, and INB-13's `Open <app>` starts
      // working for the apps INB-20's second source is made of — the ones that
      // joined the inbox by posting. Lost in an edit, `getLaunchIntentForPackage`
      // silently answers null for all of them again and every thread outside
      // the six falls back to INB-16's `unknown`. Nothing throws and no other
      // gate notices.
      final String body = queries();
      final RegExpMatch? launcher =
          RegExp(r'<intent\b[^>]*>(.*?)</intent>', dotAll: true)
              .allMatches(body)
              .cast<RegExpMatch?>()
              .firstWhere(
                (RegExpMatch? m) =>
                    m!.group(1)!.contains('android.intent.action.MAIN'),
                orElse: () => null,
              );
      expect(
        launcher,
        isNotNull,
        reason:
            'No <intent> naming android.intent.action.MAIN inside <queries> in '
            '${manifest.path} (INB-13, INB-16, decision 13).',
      );
      expect(
        launcher!.group(1),
        contains('android.intent.category.LAUNCHER'),
        reason:
            'The MAIN <intent> in <queries> carries no LAUNCHER category, so it '
            'declares nothing: MAIN without a category matches no app the user '
            'could tap (decision 13).',
      );
    });

    test('the six packages are still named one by one beside the filter', () {
      // The filter covers an app *while it has a launcher activity*; these six
      // entries cover these six whatever shape they are in. That is what makes
      // a NameNotFound for one of them mean "uninstalled" and nothing else
      // (INB-16), and what lets PERM-3's disclosure resolve their labels before
      // any of them has posted. test/shipped_apps_test.dart pins which six;
      // this pins that the filter did not quietly replace them.
      final String body = queries();
      final List<String> declared = RegExp(
        r'<package\s+android:name="([^"]+)"',
      ).allMatches(body).map((RegExpMatch m) => m.group(1)!).toList();
      expect(
        declared,
        hasLength(6),
        reason:
            'INB-20: six `<package>` entries, one per shipped messaging app. '
            'Found: $declared. A launcher <intent> is not a substitute for '
            'them (INB-16).',
      );
    });

    test('<queries> declares no third filter nobody decided on', () {
      // Two intents and no more: the Flutter engine's PROCESS_TEXT entry, which
      // was here before any of this, and decision 13's launcher filter. A third
      // one would widen what this process can see without a decision, a rule or
      // a line in the privacy policy — and, like the two above, it would need no
      // permission and show nothing on the store page (CAP-27, INB-20).
      final List<String> intents = RegExp(
        r'<intent\b[^>]*>(.*?)</intent>',
        dotAll: true,
      ).allMatches(queries()).map((RegExpMatch m) => m.group(1)!).toList();
      expect(intents, hasLength(2), reason: 'INB-20: found $intents');
      expect(
        intents.where(
          (String i) => i.contains('android.intent.action.PROCESS_TEXT'),
        ),
        hasLength(1),
        reason:
            'The PROCESS_TEXT entry io.flutter.plugin.text.ProcessTextPlugin '
            'needs is gone from <queries>.',
      );
    });
  });

  group('CAP-24 the data extraction rules', () {
    /// The body of `<cloud-backup>` or `<device-transfer>`, comments removed.
    String section(String name) {
      final RegExpMatch? match = RegExp(
        '<$name\\b[^>]*>(.*?)</$name>',
        dotAll: true,
      ).firstMatch(withoutComments(extractionRules));
      expect(
        match,
        isNotNull,
        reason:
            'No <$name> element in ${extractionRules.path}. CAP-24 requires '
            'both <cloud-backup> and <device-transfer>: from API 31 this file '
            'is what the system reads, and a missing section is the default, '
            'which is to copy everything.',
      );
      return match!.group(1)!;
    }

    for (final String name in <String>['cloud-backup', 'device-transfer']) {
      test('$name excludes the message database and the native queue', () {
        // Both domains, both sections. `database` is the message database —
        // every sender, text and time the app has captured. `file` is
        // getFilesDir(), where capture-queue.jsonl holds projected message text
        // between the listener and Dart (CAP-15) and capture-store.json holds
        // the included-apps set (INB-20).
        //
        // This is the only path captured messages can leave the phone without
        // the internet permission (CAP-24), and RUN-2's permissions gate cannot
        // see it. tool/check_backup_rules.sh can only confirm the manifest still
        // points at this file, and says so in its own header: emptying the file
        // passes there.
        final String body = section(name);
        for (final String domain in <String>['database', 'file']) {
          expect(
            body,
            contains('domain="$domain"'),
            reason:
                '<$name> in ${extractionRules.path} no longer excludes '
                'domain="$domain" (CAP-24), so Android would copy captured '
                'messages to the user\'s Google Drive or to their next device. '
                'The privacy policy says they stay on the phone '
                '(docs/privacy-policy.md, CAP-27, product principle 1).',
          );
          expect(
            body,
            contains(RegExp('<exclude[^>]*domain="$domain"')),
            reason:
                '<$name> in ${extractionRules.path} names domain="$domain" on '
                'something that is not an <exclude> — an <include> here would '
                'do the opposite of what CAP-24 requires.',
          );
        }
      });
    }

    test('nothing in the file includes a domain back in', () {
      // An <include> beside the excludes would re-add what the excludes took
      // out, and every assertion above would still pass.
      expect(
        withoutComments(extractionRules),
        isNot(contains('<include')),
        reason:
            '${extractionRules.path} carries an <include> element. CAP-24 is '
            'about what never leaves the phone, and an include is how an '
            'exclusion is undone without touching the exclusion.',
      );
    });

    test('the manifest still points at this file and keeps backup off', () {
      // The source half of what tool/check_backup_rules.sh checks on the built
      // manifest. That gate runs on a release build; this one fails on the
      // branch that dropped the attribute.
      final String xml = withoutComments(manifest);
      expect(xml, contains('android:allowBackup="false"'));
      expect(xml, contains('android:fullBackupContent="false"'));
      expect(
        xml,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
        reason:
            'From API 31 the extraction rules are what the system reads, so a '
            'manifest with allowBackup="false" and no rules resource is still a '
            'device-to-device transfer waiting to happen (CAP-24).',
      );
    });
  });
}
