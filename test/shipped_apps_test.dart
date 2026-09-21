import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/data/shipped_apps.dart';

/// INB-16 and INB-20: the shipped list and the manifest's `<queries>` are one
/// set.
///
/// This is the test the rule asks for by name. Without it the app can
/// pre-enable a package whose label and icon the build cannot resolve, and the
/// failure shows up as a row with a blank name on a user's phone rather than
/// as a red build.
void main() {
  final File manifest = File('android/app/src/main/AndroidManifest.xml');

  test('there are exactly six default-on apps (decision 9)', () {
    // Six is not arbitrary: it is the set the spike's check 1 is defined over,
    // and every one of them has to fit on the disclosure at 1.3x text (PERM-3).
    // Growing this list is a product decision, not a code change.
    expect(shippedMessagingApps.length, 6);
    expect(shippedMessagingApps.toSet().length, 6, reason: 'no duplicates');
  });

  test('every shipped package is declared in the manifest queries', () {
    final String xml = manifest.readAsStringSync();
    for (final String package in shippedMessagingApps) {
      expect(
        xml,
        contains(package),
        reason:
            '$package is captured by default but is not in <queries>, so the '
            'build cannot resolve its label or icon (INB-16)',
      );
    }
  });

  test('the manifest declares no messaging package the constant lacks', () {
    // The other direction. A package left in <queries> after being dropped
    // from the constant is a package the app can still look up and has no
    // reason to.
    final String xml = manifest.readAsStringSync();
    final RegExp packageTag = RegExp(r'<package\s+android:name="([^"]+)"');
    final Set<String> declared = packageTag
        .allMatches(xml)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();

    expect(declared, shippedMessagingApps.toSet());
  });

  test('the PROCESS_TEXT query the Flutter engine needs is still there', () {
    // The <queries> element already held this before the packages were added;
    // replacing it rather than adding to it breaks text selection.
    expect(
      manifest.readAsStringSync(),
      contains('android.intent.action.PROCESS_TEXT'),
    );
  });

  test('isShippedMessagingApp agrees with the list', () {
    expect(isShippedMessagingApp('com.whatsapp'), isTrue);
    expect(isShippedMessagingApp('com.example.shopping'), isFalse);
  });
}
