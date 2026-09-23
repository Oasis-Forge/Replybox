/// INB-13's launch, over the same `com.oasisforge.replybox/capture` channel the
/// listener already exposes.
///
/// ## What this file is here to stop happening again
///
/// There was no implementation of [AppLauncher] at all. `main.dart` built the
/// Android services with `NoopAppLauncher()`, whose `succeeds` defaulted to
/// **true**, so on a real phone `Open in app` started nothing and then reported
/// that it had worked: the screen took the success branch and INB-13's "could
/// not be opened" snackbar never drew either. Until area REP ships, that control
/// is the second tap of INB-18's reply path, so the app's only action was a lie.
///
/// Everything below therefore answers **false unless the phone said true**.
/// There is no platform, no channel state and no failure shape that produces a
/// true here without a launch having actually been started, and the no-op fake
/// now defaults the same way (`noop_services.dart`).
///
/// Like every other real service, nothing here is constructed outside
/// `main.dart` (docs/STACK_NOTES.md): a `MethodChannel` with no host on the
/// other end is the shape that once hung the suite for ten minutes, so both
/// entry points are guarded and degrade to the honest off-Android answer, which
/// is "it did not open".
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'services.dart';

/// The same channel as `android_capture_service.dart`: the app's platform
/// surface is one channel, and a second one for two methods would be a second
/// thing to register and a second thing to forget to register.
const MethodChannel _captureChannel = MethodChannel(
  'com.oasisforge.replybox/capture',
);

/// INB-13's two paths, which are two methods because they are two promises.
///
/// The label the user read decides which one runs, and neither is a fallback for
/// the other (see `AppLaunch.kt`):
///
///  - [openChat] is `Open chat`: the notification's own content intent, fired
///    from the in-memory map that holds CAP-14's reply actions. It needs no
///    package visibility, so it is the only path that can open an app the
///    manifest's `<queries>` does not declare.
///  - [open] is `Open <app>`: the package's own launcher intent, with the app
///    claiming nothing about where that lands. Package visibility answers this
///    one null for every undeclared package, so it is offered only where
///    `PackagePresence.installed` says the package manager resolved the app.
///
/// Neither carries an extra, a message, a sender or a conversation identifier
/// the app added; the Kotlin side is where that is held, and held structurally
/// (product principle 1, INB-13).
class AndroidAppLauncher implements AppLauncher {
  const AndroidAppLauncher();

  /// How long [openChat] waits for a sent content intent to take the screen
  /// before it reports that nothing opened (INB-13).
  ///
  /// Measured both ways on the emulator at API 37, 23 September 2026, on the
  /// same Google Messages conversation: an allowed launch took the screen well
  /// inside this window and the thread drew no snackbar, and a blocked one never
  /// takes it at all, so it drew the snackbar at the end of the window and the
  /// user was told. The whole of the wait is therefore only ever spent on the
  /// case that has nothing to wait for — where the alternative was waiting
  /// forever, on a tap that said nothing.
  static const Duration _launchWindow = Duration(milliseconds: 1500);

  /// INB-13's launcher-intent path.
  ///
  /// False is the answer for a package that is not installed and for one the
  /// manifest never declared, because the app cannot tell those apart and
  /// INB-16 forbids it from guessing. The screen spends both as the one
  /// snackbar that names no app.
  @override
  Future<bool> open(String package) => _launch('openApp', package);

  /// INB-13's content-intent path, by the key of the notification the thread's
  /// newest message arrived on.
  ///
  /// The label is drawn from [canOpenChat] and not from
  /// `ReplyService.canReplyTo`: they are two handles on one entry and either can
  /// be absent, so a notification that carried no reply action can still carry a
  /// content intent — which is most of what an app outside `<queries>` will ever
  /// offer, and all the app has to open it with.
  ///
  /// ## The send is not the launch, so the send is not the answer
  ///
  /// Measured on the emulator at API 37, 23 September 2026, on a Google Messages
  /// notification two seconds old: `PendingIntent.send()` **succeeded** and the
  /// system then refused the activity —
  /// `Background activity launch blocked! ... balAllowedByPiCreator: BSP.NONE`.
  /// Nothing opened, this method answered true, and the screen took the success
  /// branch, so INB-13's snackbar never drew either. A tap that does nothing and
  /// says nothing was the app's whole promise failing in silence, on its primary
  /// path.
  ///
  /// Two halves, and this is the second one.
  ///
  ///  * `AppLaunch.kt` lends the send this app's own foreground start
  ///    privileges, which Android 14 stopped lending implicitly. That is what
  ///    makes the launch *happen*.
  ///  * This method stops reporting a send as a launch. Android hands back no
  ///    outcome for an activity `PendingIntent`, so the one signal left is the
  ///    one a launch that landed always produces: Replybox stops being the app
  ///    on screen. [_launchWindow] of that not happening is answered false, and
  ///    the user gets INB-13's sentence.
  ///
  /// The contract is therefore the same as [open]'s and the screen spends one
  /// boolean: it opened, or it did not. The cost is a launch slow enough to take
  /// longer than the window, which is reported as a failure and then opens
  /// anyway; the window is set well past what a start takes so that stays rare,
  /// and a stale snackbar is a far smaller lie than a dead button.
  @override
  Future<bool> openChat(String notificationKey) async {
    if (!Platform.isAndroid) return false;
    // Armed before the send and not after. A launch can take the screen before
    // the channel's answer comes back, and a watch started afterwards would miss
    // the very thing it is watching for.
    final Completer<void> left = Completer<void>();
    final AppLifecycleListener watch = AppLifecycleListener(
      onStateChange: (AppLifecycleState state) {
        if (state != AppLifecycleState.resumed && !left.isCompleted) {
          left.complete();
        }
      },
    );
    try {
      if (!await _launch('openChat', notificationKey)) return false;
      // The binding's own answer, for a launch fast enough to have paused this
      // app before the listener existed at all. Only a state that is there and
      // is not `resumed` counts: the binding holds null until the first report,
      // and reading that as "something took the screen" would be a silent
      // success again, which is the whole defect.
      final AppLifecycleState? now = WidgetsBinding.instance.lifecycleState;
      if (now != null && now != AppLifecycleState.resumed) return true;
      await left.future.timeout(_launchWindow, onTimeout: () {});
      return left.isCompleted;
    } finally {
      watch.dispose();
    }
  }

  /// Whether the listener still holds that notification's content intent
  /// (INB-13).
  ///
  /// Asked, never stored. The map dies with the process and is cleared on every
  /// listener disconnection (CAP-13, `ReplyActions.clear`), so only the listener
  /// knows — and an answer remembered across a resume would be a label promising
  /// a chat nothing can open.
  ///
  /// Reads exactly like a failed launch: no host, no platform, a null answer or
  /// a `PlatformException` all mean nothing is held, which is the state the
  /// screen already has a sentence for.
  @override
  Future<bool> canOpenChat(String notificationKey) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _captureChannel.invokeMethod<bool>(
            'canOpenChat',
            notificationKey,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// One shape for both paths: ask, and read anything that is not an explicit
  /// `true` as "it did not open".
  ///
  /// Every failure lands here rather than on the caller. INB-13 makes a launch
  /// that throws and a launch that resolves to nothing the same outcome on
  /// screen — one snackbar, nothing else changed — so an exception escaping
  /// this method would only be a second shape for the screen to collapse back
  /// into false.
  Future<bool> _launch(String method, String argument) async {
    // Off Android there is no host to ask, and a hostless channel is the trap
    // docs/STACK_NOTES.md records. It is also the one place a "yes" would be
    // pure invention.
    if (!Platform.isAndroid) return false;
    try {
      // `?? false`: a null answer is a build whose Kotlin side did not answer,
      // which is not a launch.
      return await _captureChannel.invokeMethod<bool>(method, argument) ??
          false;
    } on MissingPluginException {
      // No host registered at all — a test binding, or a build where the
      // channel is not wired.
      return false;
    } on PlatformException {
      return false;
    }
  }
}
