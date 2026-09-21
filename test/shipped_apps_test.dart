import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/data/shipped_apps.dart';

/// INB-16, INB-20 and CAP-1: the shipped list, the manifest's `<queries>` and
/// the native filter's copy of the same six packages are one set.
///
/// This is the test INB-20 asks for by name, over all three copies. Neither
/// duplicate is avoidable: `<queries>` has to be a manifest element or the build
/// cannot resolve a label or an icon, and CAP-1's filter has to be native
/// because the first notification after a grant can arrive on an install where
/// no Dart has ever run.
///
/// Each copy fails differently and the native one fails quietly. A package left
/// in `<queries>` alone is a lookup the app never makes. A package in the Dart
/// list alone is a row with a blank name. A package in the Kotlin set alone is
/// *captured by default*: messages other people sent, stored from an app that
/// was never on PERM-3's disclosure and that the user never named. That is the
/// one direction nothing else in the build would catch.
void main() {
  final File manifest = File('android/app/src/main/AndroidManifest.xml');
  final File shippedApps = File(
    'android/app/src/main/kotlin/com/oasisforge/replybox/capture/ShippedApps.kt',
  );

  /// Every double-quoted string in `ShippedApps.kt`, in source order.
  ///
  /// The file keeps itself readable from outside Kotlin by holding nothing else
  /// quoted, and this reads it at its word rather than trusting it: anything
  /// quoted anywhere in the file lands in this list, so a package smuggled into
  /// a second constant, or a quoted word dropped into a comment, shows up here
  /// instead of slipping past a parser aimed at one declaration.
  List<String> quotedStringsInShippedAppsKt() {
    expect(
      shippedApps.existsSync(),
      isTrue,
      reason:
          '${shippedApps.path} is gone. CAP-1 filters natively on the constant '
          'it holds, so if that constant moved this test has to follow it. A '
          'test that quietly checks nothing is exactly how a package gets '
          'captured by default without PERM-3 ever naming it.',
    );
    return RegExp(r'"([^"]*)"')
        .allMatches(shippedApps.readAsStringSync())
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
  }

  /// The packages inside `ShippedApps.PACKAGES` itself, read out of the Kotlin
  /// source because a Dart test has no other way to reach them.
  ///
  /// Anchored on the declaration rather than taking the whole file, so this
  /// stays true to what CAP-1 actually filters on even if the file gains
  /// something else quoted. The two readings are compared below; that
  /// comparison is what makes the whole-file shortcut safe.
  List<String> kotlinShippedApps() {
    final String source = shippedApps.readAsStringSync();

    final RegExpMatch? declaration = RegExp(
      r'val\s+PACKAGES\b',
    ).firstMatch(source);
    expect(
      declaration,
      isNotNull,
      reason:
          'No `val PACKAGES` in ${shippedApps.path}. CAP-1 filters on that '
          'constant natively, so if it was renamed this test has to follow it '
          'rather than quietly check nothing.',
    );

    // Balanced scan instead of "up to the next )", so a trailing comment like
    // `// Google Messages (RCS)` cannot end the list early and hide every
    // package after it.
    final int open = source.indexOf('(', declaration!.end);
    expect(
      open,
      isNot(-1),
      reason: 'PACKAGES in ${shippedApps.path} opens no list.',
    );
    int depth = 0;
    int close = open;
    for (; close < source.length; close++) {
      if (source[close] == '(') depth++;
      if (source[close] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    expect(
      close,
      lessThan(source.length),
      reason: 'PACKAGES in ${shippedApps.path} never closes its list.',
    );

    final List<String> packages = RegExp(r'"([^"]*)"')
        .allMatches(source.substring(open + 1, close))
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(
      packages,
      isNotEmpty,
      reason:
          'PACKAGES in ${shippedApps.path} holds no string literals. If it now '
          'builds its packages from named constants or a function, rewrite '
          'this parser to follow it rather than leaving it to compare an empty '
          'set against an empty set.',
    );
    return packages;
  }

  Set<String> manifestQueriedPackages() {
    final RegExp packageTag = RegExp(r'<package\s+android:name="([^"]+)"');
    return packageTag
        .allMatches(manifest.readAsStringSync())
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
  }

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
    expect(manifestQueriedPackages(), shippedMessagingApps.toSet());
  });

  test('the native filter captures by default from exactly this list', () {
    // CAP-1: the listener decides what to drop before Dart exists, so this
    // Kotlin set -- not shippedMessagingApps -- is what actually switches an
    // app on for a fresh install. A package added here alone never reaches
    // <queries> and never reaches PERM-3's disclosure, so it captures messages
    // from an app the user was never told about and cannot see named anywhere.
    // Nothing else in the build compares it, which is why this assertion is
    // the point of the file.
    expect(
      kotlinShippedApps().toSet(),
      shippedMessagingApps.toSet(),
      reason:
          'ShippedApps.PACKAGES and lib/data/shipped_apps.dart have drifted '
          '(CAP-1, INB-20). A package only the Kotlin set names is captured by '
          'default with no disclosure (PERM-3); a package only Dart names is '
          'offered in the chooser but never captured.',
    );
  });

  test('ShippedApps.kt quotes its packages and nothing else', () {
    // The file says of itself that every quoted string in it is a package name.
    // That is the property that lets anything outside Kotlin read it, so it is
    // asserted rather than believed -- and asserting it closes the gap the
    // anchored parser leaves: a seventh package put in a *second* constant in
    // this file would satisfy `val PACKAGES` and still reach CAP-1's filter.
    expect(
      quotedStringsInShippedAppsKt(),
      kotlinShippedApps(),
      reason:
          '${shippedApps.path} holds a quoted string that is not one of '
          "PACKAGES' entries. If that is a note, unquote it; if it is a "
          'package, it is captured by default from outside the one constant '
          'every other copy is compared against (CAP-1, INB-20).',
    );
  });

  test('the native filter lists no package twice', () {
    // setOf() swallows a duplicate, so the Kotlin set would still equal the
    // Dart set and the six-is-six count above would still pass. Compare the
    // literals, which is where a bad paste shows.
    final List<String> packages = kotlinShippedApps();
    expect(
      packages.length,
      packages.toSet().length,
      reason: 'a package name is repeated in ${shippedApps.path}: $packages',
    );
  });

  test('the three copies of the shipped list are one set', () {
    // The assertion INB-20 asks for, stated once over all three sources so a
    // reader can see what "one set" means without assembling it from the tests
    // above.
    expect(
      <String>{
        ...shippedMessagingApps,
        ...kotlinShippedApps(),
        ...manifestQueriedPackages(),
      },
      shippedMessagingApps.toSet(),
      reason:
          'the union of lib/data/shipped_apps.dart, ShippedApps.kt and the '
          "manifest's <queries> is wider than the shipped list itself, so at "
          'least one of the three names a package the others do not (INB-20)',
    );
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
