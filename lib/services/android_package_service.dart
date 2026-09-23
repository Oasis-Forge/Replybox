/// INB-1's app icon and label, and INB-16's installed-or-gone, over the same
/// `com.oasisforge.replybox/capture` channel the listener already exposes.
///
/// Like every other real service, nothing here is constructed outside
/// `main.dart` (docs/STACK_NOTES.md): a `MethodChannel` with no host on the
/// other end is the shape that once hung the suite for ten minutes, so the one
/// entry point below is guarded and degrades to the honest off-Android answer,
/// which is [PackagePresence.unknown].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'services.dart';

/// The same channel as `android_capture_service.dart`: the app's platform
/// surface is one channel, and a second one for a single method would be a
/// second thing to register and a second thing to forget to register.
const MethodChannel _captureChannel = MethodChannel(
  'com.oasisforge.replybox/capture',
);

/// The package manager, asked one declared package at a time.
///
/// ## What is cached, and why it is cached here rather than natively
///
/// Every resolved answer is held for the life of the process, keyed by package.
/// A conversation list draws a source icon on every row and rebuilds on every
/// scroll, every filter chip and every arriving message (INB-25), so the thing
/// worth avoiding is not the package manager lookup — Android already caches
/// that — but the **channel round trip and the byte copy** behind it. A cache on
/// the Kotlin side would still pay both. This one pays neither, and it hands
/// back the *same* [Uint8List] instance every time, which is what lets Flutter's
/// own image cache recognise a row's icon as one it has already decoded rather
/// than decoding a fresh copy of identical bytes per row.
///
/// What the cache can hold is bounded, and since 22 September 2026 the bound is
/// no longer six. This class used to refuse every package outside
/// `lib/data/shipped_apps.dart` before the channel call, because the manifest declared
/// only those and a lookup for anything else could not be told from package
/// visibility hiding the app. That gate is what made INB-13's control
/// permanently dead for every app that joined the inbox by posting (INB-20), so
/// the manifest now declares a MAIN + LAUNCHER filter and the refusal moved to
/// where it can be enforced rather than merely observed: `SourceAppInfo.mayAsk`
/// on the Kotlin side answers `unknown` without touching the package manager for
/// any package that is neither shipped nor one this install has seen post a
/// notification.
///
/// The bound is therefore the packages that have posted, plus the six — an
/// `apps` row apiece (INB-20), a few kB of PNG each at the 96px the Kotlin side
/// rasterises to. There is still no eviction: an unresolved answer is not stored
/// at all, so nothing a caller invents can put an entry here, and the resolved
/// ones are one per app that has actually messaged this phone.
///
/// No copy of that gate lives here, deliberately. A second gate in Dart would
/// have to be a second answer to "has this package posted?", and the only
/// authority on that is the native store the listener writes before CAP-1's
/// drop; a Dart copy built from whatever rows a screen happened to have loaded
/// would drift, and the layer that drifted would be the one nothing tests. What
/// is kept here is the honest off-Android answer below, which is the same
/// [PackagePresence.unknown] by another road.
///
/// A **failed** ask is not cached, and neither is a malformed one. A resolved
/// answer — [PackagePresence.installed] or [PackagePresence.gone] — is a fact
/// about the phone and keeping it is right; anything else is a fact about one
/// moment, and remembering it would leave a row on INB-16's `unknown` fallback
/// for the rest of the run over one bad call or one reply this build could not
/// read.
///
/// [forgetAll] is what handles an app installed or uninstalled while Replybox
/// was in the background. Nothing tells the app that happened — knowing would
/// mean a broadcast receiver, a component this app does not have — so the answer
/// is refreshed on resume rather than watched for.
class AndroidPackageInfoService implements PackageInfoService {
  AndroidPackageInfoService();

  /// Resolved answers, by package. See the note above on what does and does not
  /// land here.
  final Map<String, SourceAppIdentity> _resolved =
      <String, SourceAppIdentity>{};

  /// Asks in flight, by package, so a list drawing twelve rows for one app in
  /// the same frame makes one channel call and not twelve.
  final Map<String, Future<SourceAppIdentity>> _asking =
      <String, Future<SourceAppIdentity>>{};

  @override
  SourceAppIdentity? lookupCached(String package) => _resolved[package];

  @override
  Future<SourceAppIdentity> lookup(String package) {
    // INB-1's "the app never queries a package it has not declared" is enforced
    // natively now (`SourceAppInfo.mayAsk`), against the record of what has
    // posted — see the note above on why it is not answered twice.
    final SourceAppIdentity? held = _resolved[package];
    if (held != null) return Future<SourceAppIdentity>.value(held);
    return _asking.putIfAbsent(package, () => _ask(package));
  }

  /// Bumped by [forgetAll]. An ask carries the generation it started in, and an
  /// ask from an earlier one may neither write [_resolved] nor touch [_asking].
  ///
  /// Without it [forgetAll] was half a forget: it cleared the answers and left
  /// the asks, so a resume while a lookup was in flight found that lookup still
  /// in [_asking], handed its caller the pre-resume future back through
  /// `putIfAbsent`, and let a pre-resume answer land in the map the resume had
  /// just emptied. Catching an app uninstalled while Replybox was backgrounded
  /// is the whole point of this path (INB-16), and that was the one way it was
  /// not caught.
  int _generation = 0;

  @override
  void forgetAll() {
    // One act, not two: every answer this process holds is dropped, and every
    // ask that could still put one back is disowned.
    _generation++;
    _resolved.clear();
    _asking.clear();
  }

  Future<SourceAppIdentity> _ask(String package) async {
    final int generation = _generation;
    try {
      if (!Platform.isAndroid) return SourceAppIdentity.unknown(package);
      final Map<Object?, Object?>? answer = await _captureChannel
          .invokeMethod<Map<Object?, Object?>>('lookupPackage', package);
      final SourceAppIdentity identity = _read(package, answer);
      // Only a resolved answer is kept. An `unknown` here is a reply this build
      // could not read — a missing key, a presence string it does not know, a
      // wrong type — and caching it would make one bad reply stick to the row
      // for the rest of the run, which is the opposite of what the note above
      // promises and the same defect as caching a thrown call.
      //
      // And only while this ask is still the current one. A [forgetAll] that
      // ran while this call was on the channel means the answer in hand is
      // about the phone as it was before the resume, and writing it back is
      // exactly the stale restore the generation exists to stop.
      if (identity.presence != PackagePresence.unknown &&
          generation == _generation) {
        _resolved[package] = identity;
      }
      return identity;
    } on MissingPluginException {
      // No listener on this platform at all. Not cached: an unknown answer that
      // came from there being no host is not a fact about a package.
      return SourceAppIdentity.unknown(package);
    } on PlatformException {
      // INB-16: a failure says less rather than guessing. Never `gone` — the
      // app has not seen an uninstall, it has seen a call fail.
      return SourceAppIdentity.unknown(package);
    } finally {
      _forgetAsk(package, generation);
    }
  }

  /// Takes a finished ask out of [_asking], unless [forgetAll] already did.
  ///
  /// Its own method because `Map.remove` hands back the future it removed —
  /// this very one — and a bare call to it inside the `async` body above reads
  /// to the analyzer as a future nobody awaited. Here there is no future to
  /// await and nothing to misread.
  ///
  /// The generation check is not belt and braces: after a [forgetAll] the entry
  /// under this package belongs to the ask that replaced this one, and removing
  /// it would leave that ask undeduplicated — every row of a list drawing the
  /// same app would then open its own channel call.
  void _forgetAsk(String package, int generation) {
    if (generation != _generation) return;
    _asking.remove(package);
  }

  /// The channel's answer, read strictly.
  ///
  /// Anything unrecognised — a missing key, a presence string this build does
  /// not know, a wrong type — is [PackagePresence.unknown]. That direction is
  /// chosen rather than defaulted: the cost of reading a broken answer as
  /// unknown is a plainer row, and the cost of reading one as `gone` is telling
  /// the user an app they still have is uninstalled (INB-16).
  ///
  /// Visible to tests because it is the only part of this class a host VM can
  /// execute: [_ask] answers `unknown` off Android before it reaches the
  /// channel, which is what keeps a hostless `MethodChannel` out of the suite
  /// (docs/STACK_NOTES.md) and also puts this rule out of reach through the
  /// public API. Left untestable, the branch that could turn a malformed answer
  /// into `gone` is exactly the one nothing would catch.
  @visibleForTesting
  static SourceAppIdentity readAnswer(
    String package,
    Map<Object?, Object?>? answer,
  ) => _read(package, answer);

  static SourceAppIdentity _read(
    String package,
    Map<Object?, Object?>? answer,
  ) {
    if (answer == null) return SourceAppIdentity.unknown(package);
    switch (answer['presence']) {
      case 'installed':
        final Object? label = answer['label'];
        final Object? icon = answer['icon'];
        return SourceAppIdentity(
          package: package,
          presence: PackagePresence.installed,
          // An empty label is no label: INB-1 falls through to the stored `apps`
          // row and then to the package name, and a blank string would win that
          // fallback and draw a nameless row.
          label: label is String && label.isNotEmpty ? label : null,
          icon: icon is Uint8List && icon.isNotEmpty ? icon : null,
          // INB-13: read strictly and in both directions. Only an explicit
          // `false` withholds the control, because that sentence says there is
          // nothing to open and the app may only say it where the phone said
          // it; only an explicit `true` claims a launch will land. Anything
          // else — a key an older host did not send, a wrong type — is
          // `unknown`, which offers the control and spends a failure as
          // INB-13's snackbar, exactly as this app did before the fact
          // existed.
          launchability: _launchability(answer['launchable']),
        );
      case 'gone':
        // No label and no icon travel with this: the package manager resolved
        // nothing, so there is nothing of the app's to draw. The row keeps the
        // title and messages it already has (INB-16).
        return SourceAppIdentity(
          package: package,
          presence: PackagePresence.gone,
        );
      default:
        return SourceAppIdentity.unknown(package);
    }
  }

  /// `SourceAppInfo.KEY_LAUNCHABLE`, read as the tri-state it is.
  ///
  /// Not `answer['launchable'] == true`: that would fold "the host did not say"
  /// into "there is nothing to open", which is the sentence on screen, and this
  /// file's whole rule is that an answer it could not read says less rather
  /// than more (INB-16).
  static Launchability _launchability(Object? value) => switch (value) {
    true => Launchability.launchable,
    false => Launchability.noLauncher,
    _ => Launchability.unknown,
  };
}
