import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/services/android_package_service.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';

/// INB-16's tri-state, on the Dart side of the channel.
///
/// The Kotlin half is covered by `SourceAppInfoTest`: which packages are asked
/// about, and which answer each outcome produces. What is left here is the
/// reading of that answer, and the one direction it must never fail in — an
/// answer this build cannot make sense of is `unknown`, never `gone`, because
/// `gone` is a sentence on screen saying an app the user may still have is
/// uninstalled.
void main() {
  const String declared = 'com.whatsapp';

  group('reading the channel answer (INB-16)', () {
    test('installed carries the label, the icon and the launchability', () {
      final Uint8List icon = Uint8List.fromList(<int>[137, 80, 78, 71]);

      final Map<Object?, Object?> answer = <Object?, Object?>{
        'presence': 'installed',
        'label': 'WhatsApp',
        'icon': icon,
        'launchable': true,
      };

      final SourceAppIdentity identity = AndroidPackageInfoService.readAnswer(
        declared,
        answer,
      );

      expect(identity.presence, PackagePresence.installed);
      expect(identity.label, 'WhatsApp');
      expect(identity.icon, same(icon));
      expect(
        identity.launchability,
        Launchability.launchable,
        reason: 'INB-13: the whole installed answer, as the host sends it',
      );
      expect(
        identity.package,
        declared,
        reason: 'the package comes from the ask, never from the answer',
      );
    });

    test('INB-13 launchability is read strictly, and in both directions', () {
      // `installed` is not `launchable`: the 23 September 2026 drill found
      // `com.android.shell` installed, named, iconed, and with no launcher
      // activity — so the bar drew `Open Shell` and every tap failed. The fact
      // travels on its own key, and the reading of it is the one place this
      // build decides whether the thread may say "has no screen to open".
      SourceAppIdentity read(Object? launchable) =>
          AndroidPackageInfoService.readAnswer(declared, <Object?, Object?>{
            'presence': 'installed',
            'label': 'WhatsApp',
            'launchable': launchable,
          });

      expect(read(true).launchability, Launchability.launchable);
      expect(read(false).launchability, Launchability.noLauncher);

      // Everything that is not an explicit boolean is `unknown`, and the
      // direction matters: only a measured `false` withholds the control,
      // because that is the sentence on screen, and only a measured `true`
      // claims a launch will land. A host that did not send the key must leave
      // the app behaving as it did before the key existed — offer the control
      // and spend a failure as INB-13's snackbar — rather than accuse a
      // perfectly launchable app of having nothing to open.
      final SourceAppIdentity absent = AndroidPackageInfoService.readAnswer(
        declared,
        <Object?, Object?>{'presence': 'installed', 'label': 'WhatsApp'},
      );
      expect(
        absent.launchability,
        Launchability.unknown,
        reason: 'INB-13: a key that did not travel says nothing',
      );
      for (final Object? wrong in <Object?>[null, 'true', 1, 0, <Object?>[]]) {
        expect(
          read(wrong).launchability,
          Launchability.unknown,
          reason: 'INB-13: $wrong is not an answer',
        );
      }

      // And none of it disturbs the rest of the answer: whether the app is on
      // the phone and whether it has a screen are two facts (INB-16).
      expect(read(false).presence, PackagePresence.installed);
      expect(read(false).label, 'WhatsApp');
    });

    test('gone carries nothing of the app', () {
      final SourceAppIdentity identity = AndroidPackageInfoService.readAnswer(
        declared,
        <Object?, Object?>{'presence': 'gone', 'label': null, 'icon': null},
      );

      expect(identity.presence, PackagePresence.gone);
      expect(identity.label, isNull);
      expect(identity.icon, isNull);
      expect(
        identity.launchability,
        Launchability.unknown,
        reason:
            'INB-13: an app that is not there resolved no launcher intent '
            "either, and the thread draws INB-16's line over it anyway",
      );
    });

    test('an empty label is no label, not a nameless row', () {
      // INB-1 falls through to the label the listener stored and then to the
      // package name. An empty string would win that fallback and draw a row
      // with a blank where the app's name goes.
      final SourceAppIdentity identity = AndroidPackageInfoService.readAnswer(
        declared,
        <Object?, Object?>{'presence': 'installed', 'label': '', 'icon': null},
      );

      expect(identity.presence, PackagePresence.installed);
      expect(identity.label, isNull);
    });

    test('an answer this build cannot read is unknown and never gone', () {
      // Every shape a broken answer can arrive in. The assertion that matters is
      // the same one each time: not `gone`. Reading a malformed answer as an
      // uninstall is the one wrong thing INB-16 names, and it is the failure a
      // `switch` with a careless default would produce.
      final List<Map<Object?, Object?>?> broken = <Map<Object?, Object?>?>[
        null,
        <Object?, Object?>{},
        <Object?, Object?>{'presence': null},
        <Object?, Object?>{'presence': 'GONE'},
        <Object?, Object?>{'presence': 'uninstalled'},
        <Object?, Object?>{'presence': 0},
        <Object?, Object?>{'presence': 'unknown'},
      ];

      for (final Map<Object?, Object?>? answer in broken) {
        final SourceAppIdentity identity = AndroidPackageInfoService.readAnswer(
          declared,
          answer,
        );
        expect(
          identity.presence,
          PackagePresence.unknown,
          reason: 'INB-16: $answer must not be read as anything but unknown',
        );
        expect(identity.label, isNull);
        expect(identity.icon, isNull);
      }
    });

    test('an icon of the wrong type is dropped without losing the presence', () {
      // Whether the app is installed and whether its icon arrived are two facts.
      // Folding them would put a `sourceAppGone` line on a row for an app that
      // is right there.
      final SourceAppIdentity identity = AndroidPackageInfoService.readAnswer(
        declared,
        <Object?, Object?>{
          'presence': 'installed',
          'label': 'WhatsApp',
          'icon': 'not bytes',
        },
      );

      expect(identity.presence, PackagePresence.installed);
      expect(identity.label, 'WhatsApp');
      expect(identity.icon, isNull);
    });
  });

  group('what the cache is allowed to hold (INB-1, INB-16)', () {
    test('nothing an ask could not resolve, so one bad answer does not stick '
        'for the run', () async {
      // The class documents two invariants and neither used to hold: every
      // package went over the channel, and the answer was stored whatever it
      // was — so a malformed reply, or a call that could not be made at all,
      // left that row on `unknown` until the process died.
      //
      // Off Android there is no host, which is the same outcome as a failed
      // ask: `unknown`, and not remembered.
      final AndroidPackageInfoService service = AndroidPackageInfoService();

      expect(
        (await service.lookup(declared)).presence,
        PackagePresence.unknown,
      );
      expect(
        service.lookupCached(declared),
        isNull,
        reason: 'a failure is a fact about one moment, not about a package',
      );

      // The same for a package outside the shipped six. It used to be answered
      // here without the channel being crossed at all, because INB-1's "never
      // queries a package it has not declared" was enforced twice: once in this
      // class against `shippedMessagingApps`, and once natively. INB-20's
      // correction of 23 September 2026 made that Dart copy **wrong** — a
      // package with an `apps` row is now askable, and this gate refused every
      // one of them, so INB-13's control could never work for the apps that
      // joined the inbox by posting, which is the whole of what decision 13
      // bought. The single gate is `SourceAppInfo.mayAsk`, and
      // `test/package_visibility_test.dart` is what holds it there.
      //
      // What is left to assert here is the caching rule, which is the same for
      // every package: an ask that resolved nothing is never remembered.
      expect(
        (await service.lookup('com.example.shopping')).presence,
        PackagePresence.unknown,
      );
      expect(service.lookupCached('com.example.shopping'), isNull);
    });
  });

  group('the fake every test gets', () {
    test('answers unknown for anything it was not seeded with', () async {
      const NoopPackageInfoService service = NoopPackageInfoService();

      expect(service.lookupCached(declared)!.presence, PackagePresence.unknown);
      final SourceAppIdentity asked = await service.lookup(declared);
      expect(asked.presence, PackagePresence.unknown);
      expect(
        asked.package,
        declared,
        reason: 'the fake still answers about the package it was asked about',
      );
    });

    test('a seeded identity is what a row draws', () async {
      const NoopPackageInfoService service = NoopPackageInfoService(
        identities: <String, SourceAppIdentity>{
          declared: SourceAppIdentity(
            package: declared,
            presence: PackagePresence.gone,
          ),
        },
      );

      expect(service.lookupCached(declared)!.presence, PackagePresence.gone);
      expect(
        service.lookupCached('com.example.other')!.presence,
        PackagePresence.unknown,
        reason: 'seeding one package says nothing about any other',
      );
    });
  });
}
