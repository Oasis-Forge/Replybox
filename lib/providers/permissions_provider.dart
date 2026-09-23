import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/battery_guidance.dart';
import '../db/repository.dart';
import '../models/source_app.dart';
import '../services/services.dart';
import 'inbox_provider.dart';

/// PERM-13's answer, as one value.
///
/// Six branches and not three booleans. PERM-13 fixes an order — the access
/// banner, then `capture is not running right now`, then the quiet observation
/// — and says the first condition that holds wins. A screen that held the three
/// facts and ranked them would be a second place for that order to live, and
/// the two would disagree the first time one of them changed. The screen
/// switches on this once.
///
/// The three `accessOff*` branches are PERM-8's three sentences, resolved here
/// for the same reason: which of them holds is a question about stored
/// `capture_sessions` rows (PERM-9's estimate flag, `installed_at`), which is
/// data the screen does not have and must not learn.
///
/// What no value here means: *capture is working*. There is no such branch and
/// there cannot be one. Section 9 is explicit that a listener which silently
/// died is indistinguishable from a phone nobody has messaged, so the most this
/// enum ever says about a healthy app is [none] — nothing to report — and
/// [quiet], which states when something last arrived and draws no conclusion
/// from the gap.
enum CaptureStatusLine {
  /// Nothing to say.
  ///
  /// Access is granted and either the listener is connected with something
  /// having arrived inside PERM-11's window, or one of PERM-11's preconditions
  /// is unmet, or the listener has told this process nothing at all yet
  /// (`listenerConnected()` answering null). That last case is the important
  /// one: [none] is also what "the app has learned nothing" looks like, and
  /// PERM-10 forbids drawing a line on it.
  none,

  /// PERM-8, first branch: the newest closed capture window was closed on a
  /// reported disconnection, inside the listener's own callback and with that
  /// callback's time (PERM-9). [PermissionsProvider.statusSince] is that
  /// instant, exactly, and the sentence says "since".
  accessOffSince,

  /// PERM-8, second branch: the window was closed on a later discovery, so its
  /// end is PERM-9's estimate. [PermissionsProvider.statusSince] is the last
  /// moment the app can prove — the newest event the listener delivered — and
  /// the sentence says "since at least". Never the moment the app noticed
  /// (product principle 3).
  accessOffSinceAtLeast,

  /// PERM-8, third branch: no window has ever been closed, because access has
  /// never been granted since install. [PermissionsProvider.statusSince] is
  /// `installed_at` and the sentence names it as the install date — never a
  /// time the app does not hold (CAP-12).
  accessNeverOn,

  /// PERM-10: access is granted, this app's own listener reported itself
  /// disconnected, a rebind was either asked for or suppressed by the
  /// 60-second floor, and the ten seconds have passed with the listener still
  /// reporting itself disconnected. [PermissionsProvider.statusSince] is null:
  /// the app does not know when the unbind happened, and PERM-9's discipline
  /// forbids printing the time it noticed instead.
  notRunning,

  /// PERM-11: access granted, listener connected, twenty-four hours with no
  /// event of any kind. [PermissionsProvider.statusSince] is the newest of the
  /// last event and the last listener connection, which is what the line
  /// states. It is dismissible, carries no error styling, and is the one branch
  /// here that reports an observation rather than a state.
  quiet,
}

/// Everything the app is allowed to say about notification access, resolved in
/// one place (section 9, PERM-13).
///
/// **This class is where the honesty of the permissions area lives.** Section 9
/// separates three states — access not granted, which the system will tell us;
/// granted but not connected, which the system will also tell us; and connected
/// with nothing arriving, which nothing can tell us apart from a quiet weekend
/// — and every rule in the area turns on not dressing the third up as the
/// second. So for each state this class records what the app knows, how it
/// knows it, and what it refuses to say:
///
///  * **Access off** — known, from `Settings.Secure` through
///    [NotificationSource.hasAccess], read again on every cold start and every
///    resume (PERM-5) and on every listener binding heard while the app is open
///    (PERM-8, [_onCaptured]). Said plainly, with a time that is either exact or
///    hedged with "at least" depending on which observation closed the window
///    (PERM-8, PERM-9). Refused: any claim about *when* access was taken away
///    where only a discovery time is held.
///  * **Granted, listener not connected** — known, but only as far as this
///    process has observed: [NotificationSource.listenerConnected] answers
///    true, false, or null for "neither lifecycle callback has fired here".
///    Said only on a **false** that survives a rebind request and ten seconds
///    (PERM-10). Refused: anything at all on a null, which is a listener that
///    may simply be slow to bind, and any statement about *why* it is unbound.
///  * **Granted, connected, silent** — not known and never knowable from here.
///    Said as an observation with a time and a hedge: nothing has arrived since
///    then, which may be perfectly normal (PERM-11). Refused, in both
///    directions: that capture has stopped, and that capture is working. The
///    check that would settle it needs `POST_NOTIFICATIONS` and waits for the
///    release that already declares it (PERM-12, PERM-15).
///
/// **PERM-5, made impossible to break rather than merely respected.** There is
/// no stored fact in this class's reach that could unlock a screen: [hasAccess]
/// has no setter, `_hasAccess` is assigned in exactly one place — from the
/// platform read at the top of [refresh] — and no key exists in `settings` that
/// records a grant, a return from the system page, or that the user "was sent
/// to settings". The three keys this area does store all record something *the
/// app put on a screen*: `disclosure_shown_at` (it was on screen),
/// `battery_guidance_shown_at` (it was shown) and `quiet_notice_shown_at`
/// (PERM-11's line was drawn — [markQuietNoticeShown]). A
/// fourth, `last_capture_event_at`, records an event's own time. None of them is
/// ever read to decide whether the app can see notifications, and the only
/// getter that answers that question cannot be fed from anything but the
/// platform.
///
/// **Owns no timer and no lifecycle observer, and exactly one subscription.**
/// The ten-second wait is the injected [delay] and not a `Timer`, and
/// `main.dart` owns the `WidgetsBindingObserver` that calls [refresh] on
/// resume. The subscription is [CaptureSignal] and it was added on
/// 23 September 2026, because two clauses of section 9 name an event this class
/// had no way of hearing — see [_onCaptured] — so [dispose] now has exactly one
/// thing to tear down. What *can* outlive the tree is the future inside
/// PERM-10's wait, which is why every `await` in this file is followed by an
/// [isDisposed] check before the next write: a ten-second wait that finished
/// into a disposed notifier is the throw [DeferredNotifier] exists to prevent.
class PermissionsProvider extends ChangeNotifier with DeferredNotifier {
  /// Both dependencies are injected, never reached for, exactly as
  /// [InboxProvider]'s are: that is what lets a test hand over an in-memory
  /// database and the no-op services. Positional because Dart has no private
  /// named parameters and these fields have no business being public.
  ///
  /// [clock] and [delay] are injected for the reason [InboxProvider]'s clock
  /// is: PERM-10's ten seconds and sixty seconds and PERM-11's twenty-four
  /// hours are real durations, and a test that waits them is a slow flaky test.
  /// [delay] defaults to `Future<void>.delayed`, so the app waits for real and
  /// only a test can make the wait instant — or hold it open, which is how
  /// PERM-10's "the line does not show during the ten-second wait" is asserted
  /// at all.
  ///
  /// [captureSignal] is nullable and wired only by `main.dart`, exactly as
  /// [InboxProvider]'s and [AppsProvider]'s are: a test that is not about a
  /// listener binding builds this with none and gets a provider that reads on
  /// demand and nothing else. See [_onCaptured] for what it is for.
  PermissionsProvider(
    this._repository,
    this._services, {
    CaptureSignal? captureSignal,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _clock = clock ?? _utcNow,
       _delay = delay ?? _realDelay {
    _captureSignal = captureSignal;
    _captureSignal?.addListener(_onCaptured);
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  static Future<void> _realDelay(Duration d) => Future<void>.delayed(d);

  final Repository _repository;
  final DeviceServices _services;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  /// The nudge every provider that can be on screen already listens to
  /// (INB-25). Held so [dispose] can let go of it.
  CaptureSignal? _captureSignal;

  /// PERM-10's wait. Design and not a measurement: the spike of 21 September
  /// 2026 (check 3) never measured how quickly a rebind takes effect, so this
  /// number is replaced by a dated run on hardware and the line it produces is
  /// marked provisional on screen (CAP-25).
  static const Duration _rebindWait = Duration(seconds: 10);

  /// PERM-10's floor between two rebind requests. Also design: it exists so a
  /// user who resumes the app three times in a minute cannot make the app ask
  /// Android to rebind three times, and so that the *second* of those resumes
  /// answers at once instead of starting a fresh ten-second silence.
  static const Duration _rebindFloor = Duration(seconds: 60);

  /// PERM-11's window, used twice: how long silence must last before the line
  /// is offered, and how long the line then stays away. The rule says the
  /// twenty-four hours is a guess — nobody has measured how long this listener
  /// survives on a phone trying to kill it, nor how long a real user's phone
  /// plausibly stays quiet.
  static const Duration _quietWindow = Duration(hours: 24);

  CaptureStatusLine _statusLine = CaptureStatusLine.none;
  DateTime? _statusSince;
  bool _hasAccess = false;
  bool _shouldShowDisclosure = false;
  bool _sentToAccessSettingsThisRun = false;
  bool _canOpenAccessSettings = true;
  bool _shouldShowBatteryGuidance = false;
  String? _manufacturer;
  BatteryGuidanceEntry? _guidance;
  bool _deviceFactsRead = false;
  bool _quietNoticeDismissed = false;
  DateTime? _lastRebindRequestAt;
  bool _rebindWaitInFlight = false;
  bool _hasAnnounced = false;

  /// One signal-driven read in flight and at most one queued behind it
  /// ([_onCaptured]).
  bool _signalReadInFlight = false;
  bool _signalReadAgain = false;

  /// PERM-13's one resolved line, and the only thing a screen switches on.
  ///
  /// [CaptureStatusLine.none] until the first [refresh] completes, which is the
  /// honest starting point: before the platform has been asked, the app knows
  /// nothing, and a screen drawing a line from a value nobody has filled in
  /// would be stating a fact it has not established.
  CaptureStatusLine get statusLine => _statusLine;

  /// The instant [statusLine]'s sentence names, per branch (PERM-8, PERM-11).
  ///
  /// Null for [CaptureStatusLine.none] and [CaptureStatusLine.notRunning],
  /// because neither has a time the app can stand behind, and — the one case
  /// worth naming — possibly null for [CaptureStatusLine.accessNeverOn] as
  /// well, where `installed_at` has not been written yet. `main.dart` writes
  /// that key once per launch before any screen exists, so it is null only in a
  /// test or a launch that failed before that write. A screen must draw the
  /// timeless sentence there rather than invent a date (CAP-12).
  DateTime? get statusSince => _statusSince;

  /// The system's answer at the last [refresh] (PERM-5).
  ///
  /// False before the first one, and false after a read that threw: no screen
  /// may claim the app can see notifications it cannot. **Read from the
  /// platform every time and from nothing the app stored** — see the class
  /// comment for why that is a property of the code and not a convention.
  bool get hasAccess => _hasAccess;

  /// PERM-4: whether the disclosure should be pushed *without a tap* — true on
  /// the one launch per install where it has never been on screen (PERM-5).
  ///
  /// This governs the automatic offer and nothing else. PERM-1's tap paths —
  /// the banner's action, the Settings row — never consult it, which is what
  /// keeps a stored flag from suppressing a screen the user asked for. It falls
  /// to false the moment [markDisclosureShown] is called, so the post-frame
  /// push cannot fire twice in one launch.
  bool get shouldShowDisclosure => _shouldShowDisclosure;

  /// PERM-6's one extra line: the user was sent to the system page **in this
  /// run** and the latest read still says access is missing.
  ///
  /// The condition is the *sending*, and getting that wrong is the defect this
  /// getter was written with. It first read "the disclosure has been on screen
  /// in this run", which is true in the screen's very first build — the screen
  /// records its own showing from `initState` — so a new user met *Notification
  /// access is still off, so nothing has been captured* before they had been
  /// offered anything at all. An app whose first sentence is a report of a
  /// failure the reader has not had the chance to cause is the opposite of the
  /// register this area is written in, and PERM-6 says plainly that the extra
  /// line belongs on **a return**: "a return with access still missing shows
  /// the same disclosure with one extra line".
  ///
  /// A return is not observable — PERM-5 is explicit that the process can be
  /// killed while the system page is open, so there is no return to catch —
  /// and this is the honest proxy for it: this run asked for that page, the
  /// read that followed still says no. Where the process *was* killed there is
  /// no line and no claim; PERM-8's banner is the app's whole account of the
  /// state on the next launch.
  ///
  /// Scoped to the run, never stored, and it unlocks nothing (PERM-5). A stored
  /// version would put the line on every later launch with access off, where it
  /// would no longer be answering anything the user just did.
  bool get accessStillOff => _sentToAccessSettingsThisRun && !_hasAccess;

  /// PERM-7: whether the primary button may still be a button.
  ///
  /// Starts true and is set false, permanently for the run, the first time
  /// [openAccessSettings] fails to start anything. The screen then shows the
  /// written path instead. It starts *true* rather than being probed because
  /// there is no honest probe: `CaptureChannel.start()` records why —
  /// package-visibility filtering makes `resolveActivity` unreliable on API 30
  /// and up, so the only way to learn whether the page opens is to try.
  bool get canOpenAccessSettings => _canOpenAccessSettings;

  /// PERM-14: whether the battery guidance should be pushed without a tap —
  /// true on the first launch or resume that reads access as **granted** while
  /// the stored flag is unset.
  ///
  /// False whenever access is off, including after a revocation, because
  /// PERM-14's condition is a grant being read from the system. A stale true
  /// surviving a revocation would push guidance about keeping a listener alive
  /// on top of a screen that is telling the user capture is off.
  bool get shouldShowBatteryGuidance => _shouldShowBatteryGuidance;

  /// `Build.MANUFACTURER` exactly as the device reported it, or null where it
  /// could not be read (PERM-14).
  ///
  /// Never normalised and never replaced with a substituted name: the screen
  /// prints this so an unlisted phone is visibly unlisted, and a made-up value
  /// would be the app telling the user something about their hardware the
  /// hardware did not say. Read once per run and cached — it cannot change
  /// under a running process.
  String? get manufacturer => _manufacturer;

  /// The verified steps for this phone, or null for PERM-14's generic branch.
  ///
  /// **Always null today**, and that is the decision rather than a gap
  /// (decision 11): the 24-hour OEM survival check did not run, an entry with
  /// no verified date does not ship, so `batteryGuidanceByManufacturer` is
  /// empty and every phone takes the generic branch.
  BatteryGuidanceEntry? get guidance => _guidance;

  /// PERM-11: true for the rest of this run after [dismissQuietNotice].
  ///
  /// [statusLine] is already [CaptureStatusLine.none] whenever this is true, so
  /// no screen needs it to decide what to draw. It exists so a test can tell
  /// "dismissed" from "the line never held", which are two different states
  /// behind the same silence.
  bool get quietNoticeDismissed => _quietNoticeDismissed;

  @override
  void dispose() {
    _captureSignal?.removeListener(_onCaptured);
    _captureSignal = null;
    super.dispose();
  }

  /// PERM-5: the whole state, read from the system. Called on every cold start
  /// and every resume.
  ///
  /// Reads [NotificationSource.hasAccess] from the platform every single time
  /// and reads nothing the app stored to decide it. No flag written by this app
  /// unlocks a screen, and no "we sent them to settings" state exists to be
  /// read.
  ///
  /// **One call is one resume**, which is what makes PERM-10's "at most one
  /// rebind request per resume" enforceable here rather than in a screen's
  /// lifecycle observer. There is no loop and no retry in [_refresh]: the
  /// single code path there asks for at most one rebind, so a second request
  /// inside one resume is not something a caller can arrange. The capture
  /// signal reads through the same method with `isResume: false` and is
  /// therefore not a second way to spend that request — [_onCaptured] says why
  /// at length.
  Future<void> refresh() => _refresh(isResume: true);

  /// A binding, heard the moment it happens rather than at the next resume
  /// (PERM-8, PERM-10).
  ///
  /// **What was wrong.** PERM-8 says its banner "is gone on the first app
  /// resume **or listener binding** after access returns, whichever comes
  /// first", and PERM-10 says its line "is removed **the moment** the listener
  /// connects". Both clauses were built as though only the first half existed:
  /// this class read on a cold start and on a resume, so a listener that bound
  /// while the app was open left the banner and the *capture is not running
  /// right now* line on screen until the user backgrounded the app and came
  /// back. Nothing was wrong on the phone and the app went on saying there was.
  ///
  /// **The mechanism was already there and nothing was plugged into it.** The
  /// listener enqueues a `listener_connected` lifecycle event and signals the
  /// `EventChannel`; `CaptureSync` drains it, the ingest opens a
  /// `capture_sessions` row, and the pass nudges [CaptureSignal] — the one
  /// object `main.dart` built precisely because "a single callback can only
  /// reach one object". [InboxProvider] and [AppsProvider] subscribe to it; so
  /// does this, now, on the same terms.
  ///
  /// **Three things this deliberately does not do.**
  ///
  ///  * It reads **nothing stored** to decide anything. The read it starts is
  ///    the same [_refresh], which asks the platform for access every time
  ///    (PERM-5). A signal is a cue to look, never evidence about the grant.
  ///  * It never asks for a rebind. PERM-10 counts requests per resume and per
  ///    sixty seconds, and a signal is neither — so [_refresh] takes
  ///    `isResume: false` here and returns without touching PERM-10's request,
  ///    its wait or its line. That is not a weakening: a capture signal fires
  ///    because something was *written*, which means the listener was alive,
  ///    and the state this path exists to notice is a listener that has come
  ///    back rather than one that has gone.
  ///  * It announces nothing on this stack. `CaptureSignal.captured()` is
  ///    delivered synchronously to its listeners, and the drain that fires it
  ///    can be reached from inside a build — so everything below the first
  ///    `await` in [_refresh] is off the caller's stack, and the first
  ///    announcement of all goes through [DeferredNotifier.notifyLater]
  ///    ([_announce]). A `notifyListeners` from inside a build is a
  ///    `markNeedsBuild` on a widget the framework is already building, which
  ///    Flutter refuses outright.
  ///
  /// Coalesced exactly as [InboxProvider] and [AppsProvider] coalesce, and for
  /// the same measured reason: a reconnection drains a queue and the spike's own
  /// fixture delivered five events under one timestamp, so a burst would
  /// otherwise start five overlapping platform reads. One read in flight, one
  /// queued behind it, and the queued one sees everything that landed in
  /// between.
  void _onCaptured() {
    if (_signalReadInFlight) {
      _signalReadAgain = true;
      return;
    }
    unawaited(_readAfterSignal());
  }

  Future<void> _readAfterSignal() async {
    _signalReadInFlight = true;
    try {
      do {
        // Cleared before the read, so a signal that arrives *during* it is
        // caught by the loop rather than by the check that let us in here.
        _signalReadAgain = false;
        await _refresh(isResume: false);
      } while (_signalReadAgain && !isDisposed);
    } finally {
      _signalReadInFlight = false;
    }
  }

  /// [refresh] and [_onCaptured]'s one body. [isResume] is PERM-10's whole
  /// difference between them and is spent in exactly one place below.
  Future<void> _refresh({required bool isResume}) async {
    _hasAccess = await _readAccess();
    if (isDisposed) return;

    // The only stored onboarding fact this method reads, and it decides the
    // automatic offer alone (PERM-4). Nothing about access is inferred from it.
    _shouldShowDisclosure = await _repository.disclosureShownAt() == null;
    if (isDisposed) return;

    if (!_hasAccess) {
      // PERM-13: the higher state holds, so the lower two are not evaluated at
      // all. Not an optimisation — PERM-10 and PERM-11 are only *meaningful*
      // with access granted, and asking a listener that has no grant whether
      // it is connected would produce a false that means "no access" and a
      // line that says something else.
      _shouldShowBatteryGuidance = false;
      await _resolveAccessOff();
      if (isDisposed) return;
      await _announce();
      return;
    }

    _shouldShowBatteryGuidance =
        await _repository.batteryGuidanceShownAt() == null;
    if (isDisposed) return;
    await _readDeviceFacts();
    if (isDisposed) return;

    // PERM-10. Three answers, and only one of them may draw a line.
    final bool? connected = await _services.notifications.listenerConnected();
    if (isDisposed) return;

    if (connected != false) {
      // True, or null for "this process has observed neither lifecycle
      // callback". PERM-10's line is gone the moment the listener connects, and
      // a null is nothing learned — so both clear it, and only a true goes on
      // to ask PERM-11's question, which presumes a connected listener.
      _resolve(CaptureStatusLine.none);
      if (connected == true) {
        await _resolveQuiet();
        if (isDisposed) return;
      }
      await _announce();
      return;
    }

    if (!isResume) {
      // A capture signal, with the listener reporting itself disconnected at
      // the instant we asked. **Nothing is requested and nothing is claimed.**
      //
      // PERM-10 measures its two caps in resumes — "at most one request per
      // resume and at most one per 60 seconds" — and a signal is not one, so a
      // rebind asked for here would be a second request inside a resume that
      // has already spent its one. The sixty-second floor bounds the *rate* and
      // would not catch that: a signal sixty-one seconds after the resume's own
      // request passes it cleanly.
      //
      // The line is left exactly as it was, which is the other half. If a
      // resume already established `notRunning`, that finding stands; if it
      // never did, this is a listener that may simply be between binds and
      // PERM-10 forbids accusing it without a request and ten seconds behind
      // the accusation. Either way the evidence is a resume's to gather.
      await _announce();
      return;
    }

    if (_rebindWaitInFlight) {
      // A resume that landed inside an earlier resume's ten seconds. It starts
      // no second wait and makes no second request — and, the part that is easy
      // to get wrong, it does not set the line either. The wait it is sitting
      // inside has not finished, so accusing the listener here would be exactly
      // the "first resume that accuses a listener merely slow to bind" that
      // PERM-10 names, reached through a side door.
      await _announce();
      return;
    }

    final DateTime now = _clock();
    final DateTime? lastRequest = _lastRebindRequestAt;
    if (lastRequest != null && now.difference(lastRequest) < _rebindFloor) {
      // PERM-10's floor suppressed the request, so **no new wait starts** and
      // the line shows at once. The evidence for it was gathered by the resume
      // that did ask: a rebind was requested less than a minute ago, ten
      // seconds passed, and the listener still reports itself disconnected now.
      // Waiting again would hide a known state for another ten seconds each
      // time the user glanced at the app.
      _resolve(CaptureStatusLine.notRunning);
      await _announce();
      return;
    }

    _lastRebindRequestAt = now;
    _rebindWaitInFlight = true;
    // Announced before the wait, with [statusLine] untouched: the access read,
    // the disclosure flag and PERM-14's offer are all resolved by now and a
    // screen should not sit on stale values for ten seconds. Nothing is
    // announced *for PERM-10* here, which is the clause that matters — the line
    // keeps whatever it already held until the wait ends.
    await _announce();
    try {
      // The answer is deliberately not read. `requestListenerRebind` reports
      // whether the request could be *made*, never whether the listener is now
      // connected, and PERM-10 spends both outcomes the same way: wait, then
      // ask the platform again. A false here is not evidence about the listener
      // and must never reach the user as a failure of capture.
      await _services.notifications.requestListenerRebind();
      if (isDisposed) return;
      await _delay(_rebindWait);
      if (isDisposed) return;
      final bool? after = await _services.notifications.listenerConnected();
      if (isDisposed) return;
      if (after == false) {
        _resolve(CaptureStatusLine.notRunning);
      } else {
        _resolve(CaptureStatusLine.none);
        if (after == true) {
          await _resolveQuiet();
          if (isDisposed) return;
        }
      }
    } catch (_) {
      // A throw from the channel is not evidence either. The line keeps what it
      // held, which is the same answer a null would have produced: nothing was
      // learned, so nothing is claimed.
    } finally {
      // In the `finally` so an early return on [isDisposed] — or a throw —
      // cannot leave the flag raised and make every later resume believe a wait
      // is still running.
      _rebindWaitInFlight = false;
    }
    if (isDisposed) return;
    await _announce();
  }

  /// PERM-1 and PERM-7. Opens the system's notification-access page and returns
  /// whether it was asked for.
  ///
  /// The throw is caught here and never reaches a screen. PERM-7's third branch
  /// is exactly this: `CaptureChannel.openAccessSettings` tries the detail page
  /// and then the list page and raises `PlatformException('no_settings_page')`
  /// when neither starts, and `AndroidNotificationSource` deliberately does not
  /// swallow it. The app's answer to that is the written path from the message
  /// files, not an error dialog — so this sets [canOpenAccessSettings] false
  /// and returns false, and the screen swaps the button for the path.
  ///
  /// Anything else that comes back from that call is spent the same way, on
  /// purpose: whatever the shape of the failure, what the user needs to be told
  /// is that this phone will not open the page and where to find it by hand.
  /// It is also the one place [accessStillOff] is armed, and only on the branch
  /// where the page was actually asked for. A throw means the user was sent
  /// nowhere, so telling them afterwards that access is still off would be the
  /// app reporting on a trip it never took — they get PERM-7's written path
  /// instead, which is the thing they can act on.
  Future<bool> openAccessSettings() async {
    try {
      await _services.notifications.openAccessSettings();
      _sentToAccessSettingsThisRun = true;
      notify();
      return true;
    } catch (_) {
      _canOpenAccessSettings = false;
      notify();
      return false;
    }
  }

  /// PERM-5: onboarding is done when the disclosure has actually been on
  /// screen, and this is the only thing that records it.
  ///
  /// Called from the disclosure's own `initState`, so what is written down is
  /// that the screen was *displayed* — not that it was dismissed a particular
  /// way, and not that a grant followed. The app therefore never captures from
  /// an app the user did not name without having said so first (decision 6),
  /// including on the path where the grant was made in the system's own
  /// settings app and the disclosure was shown afterwards as information.
  ///
  /// Idempotent in both halves: the repository keeps the first stamp, and
  /// calling this again only re-states a false [shouldShowDisclosure].
  ///
  /// [notifyLater] and not [notify], and that is not a detail. The caller is an
  /// `initState`, so the synchronous work still on the stack is the build that
  /// is mounting the disclosure — and a `notifyListeners` from inside it marks
  /// the `InheritedProvider` above dirty in the middle of the frame that is
  /// already building it, which Flutter refuses outright. The announcement is
  /// worth nothing this frame anyway: the two flags it carries are read by the
  /// screen that is being built and by the launch path that has already pushed
  /// it. One microtask later the frame is over, the screen is on the phone, and
  /// the same announcement costs nothing.
  /// It deliberately arms nothing else. PERM-6's extra line is armed by
  /// [openAccessSettings] and not here: "the screen was displayed" and "the
  /// user was sent to the system page" are two different facts, and the first
  /// one is true before the reader has done anything at all.
  Future<void> markDisclosureShown() async {
    _shouldShowDisclosure = false;
    await notifyLater();
    await _repository.markDisclosureShown(_clock());
  }

  /// PERM-14's stored flag. It records that the guidance was **shown**, never
  /// that the grant was made.
  ///
  /// That distinction is the whole of the rule's last clause: a process killed
  /// while the system page is open has a grant and no guidance, and a flag that
  /// recorded the grant would swallow the one showing the user was owed. This
  /// flag can only be written by the guidance screen having drawn.
  ///
  /// [notifyLater] for the reason [markDisclosureShown] gives at length: this is
  /// called from the guidance screen's own `initState`, which is a build, and a
  /// notification dispatched from inside one is a `markNeedsBuild` on a widget
  /// the framework is already building.
  Future<void> markBatteryGuidanceShown() async {
    _shouldShowBatteryGuidance = false;
    await notifyLater();
    await _repository.markBatteryGuidanceShown(_clock());
  }

  /// PERM-11's stored stamp. It records that the line was **drawn**, and it is
  /// the notice itself that calls this.
  ///
  /// **What was wrong.** This write used to live at the bottom of
  /// [_resolveQuiet], where the twenty-four hours are *decided* rather than
  /// where the sentence reaches a person. A launch resolves the whole of
  /// section 9 before the first frame — `main.dart` awaits the first read from
  /// its `initState` — and then pushes the disclosure, or PERM-14's guidance, or
  /// both, over the inbox. So the one showing PERM-11 allows in a day could be
  /// spent behind two routes on a line nobody ever read, and the app would then
  /// stay silent for twenty-four hours about a phone it had noticed going quiet.
  ///
  /// **Why here.** PERM-14's `battery_guidance_shown_at` is written by the
  /// screen that drew it, from its own `initState`, precisely so the flag means
  /// *it was displayed* and not *we decided to display it*
  /// ([markBatteryGuidanceShown]). This is the same rule through PERM-11's door
  /// and now has the same shape: `CaptureStatusNotice` reports its own showing,
  /// and it reports it only on the branch that actually draws a sentence — the
  /// quiet line with no instant to name draws nothing at all, and spends
  /// nothing.
  ///
  /// The residual limit, stated rather than hidden: `initState` means *this was
  /// mounted*, and a route pushed over the inbox in the same frame leaves the
  /// line mounted under it. That is the identical proxy PERM-14 accepts for a
  /// whole screen, and the app has no better one — but it is now one frame of
  /// slack rather than a whole launch's worth.
  ///
  /// Announces nothing, deliberately. No value a screen reads moves here: the
  /// stamp is read back only by [_resolveQuiet] on the next read, and a
  /// notification from a caller that is itself a build would be the
  /// `markNeedsBuild` [DeferredNotifier] exists to keep out of one.
  Future<void> markQuietNoticeShown() =>
      _repository.markQuietNoticeShown(_clock());

  /// PERM-11's one action besides its own link.
  ///
  /// Hides the line for the rest of this run and stamps `quiet_notice_shown_at`
  /// again, which is what makes "at most once in any 24 hours" survive a
  /// relaunch: the run-scoped flag dies with the process, the stamp does not.
  /// That second stamp is kept even now that the notice stamps its own showing
  /// — a dismissal is a later instant than the showing was, and rolling the
  /// window forward to it is what the rule's "at most once in any 24 hours"
  /// means for a user who has just said they are not interested.
  Future<void> dismissQuietNotice() async {
    _quietNoticeDismissed = true;
    if (_statusLine == CaptureStatusLine.quiet) {
      _resolve(CaptureStatusLine.none);
    }
    notify();
    await _repository.markQuietNoticeShown(_clock());
  }

  /// PERM-14's battery-optimisation list page. False means nothing started, and
  /// the screen shows the written path (PERM-7's shape, reached a second time).
  ///
  /// True means an activity started and nothing more. It is not a claim that
  /// anything about this app's battery treatment changed — the app cannot change
  /// any of those settings for itself, which is one of the few things PERM-14
  /// lets the screen say outright.
  Future<bool> openBatteryOptimisationSettings() async {
    try {
      return await _services.systemSettings.openBatteryOptimisationSettings();
    } catch (_) {
      return false;
    }
  }

  /// PERM-14, PERM-15's last clause: this package's own app-info page. Same
  /// contract as [openBatteryOptimisationSettings].
  Future<bool> openAppInfoSettings() async {
    try {
      return await _services.systemSettings.openAppInfoSettings();
    } catch (_) {
      return false;
    }
  }

  /// PERM-5's read, with a throw reading as **false**.
  ///
  /// `AndroidNotificationSource.hasAccess` already degrades that way for an
  /// absent answer; this covers the rest. The direction is not a choice: a
  /// failed read reported as access would put an app that can see nothing
  /// behind a screen that says capture is on.
  Future<bool> _readAccess() async {
    try {
      return await _services.notifications.hasAccess();
    } catch (_) {
      return false;
    }
  }

  /// PERM-14's two device facts, resolved on the first refresh that gets here
  /// and then cached for the run.
  ///
  /// `Build.MANUFACTURER` does not change under a running process, so asking
  /// again on every resume would be a channel round trip for an answer that
  /// cannot have moved. The lookup is the exact, lower-cased match
  /// `batteryGuidanceFor` performs and nothing looser — a near-match is a phone
  /// this app has not been tested on, and treating it as a listed one would be
  /// the claim about a named manufacturer that decision 11 refuses to make.
  Future<void> _readDeviceFacts() async {
    if (_deviceFactsRead) return;
    String? reported;
    try {
      reported = await _services.systemSettings.manufacturer();
    } catch (_) {
      reported = null;
    }
    if (isDisposed) return;
    _deviceFactsRead = true;
    _manufacturer = reported;
    _guidance = batteryGuidanceFor(reported);
  }

  /// PERM-8's three sentences, chosen from the stored session rows.
  ///
  /// The branch is PERM-9's flag and not a computed guess: the row says which
  /// observation closed it, because the only derivable signal —
  /// `updated_at > ended_at` — fails in both directions and would let the app
  /// say "since" for a time it cannot stand behind.
  Future<void> _resolveAccessOff() async {
    final ({DateTime endedAt, bool estimated})? closed = await _repository
        .newestClosedCaptureSession();
    if (isDisposed) return;
    if (closed != null) {
      _resolve(
        closed.estimated
            ? CaptureStatusLine.accessOffSinceAtLeast
            : CaptureStatusLine.accessOffSince,
        since: closed.endedAt,
      );
      return;
    }
    // No window has ever been closed. PERM-8 reads that as "access has never
    // been granted since install" and answers with `installed_at` — a date the
    // app does hold — rather than with a gap it would have to invent. Note this
    // is not conflated with "no window is open": a running app has an open row
    // and a closed history at the same time, and this read only ever asks about
    // the closed ones.
    final DateTime? installedAt = await _repository.installedAtOrNull();
    if (isDisposed) return;
    _resolve(CaptureStatusLine.accessNeverOn, since: installedAt);
  }

  /// PERM-11, and every one of its four preconditions.
  ///
  /// Reached only with access granted and the listener reporting itself
  /// connected, because with either of those false the silence has a known
  /// cause and PERM-13 has already answered. All four gates below exist to stop
  /// the app saying something it cannot support:
  ///
  ///  * **A clock to measure from.** The newest of the last event and the last
  ///    listener connection, and null for both means nothing has ever arrived —
  ///    a fresh install, where twenty-four hours of silence is the expected
  ///    state and the line would be the app's first words to a new user.
  ///  * **Twenty-four hours of it**, measured from that instant and never from
  ///    the time a drain ran (product principle 3). `last_capture_event_at` is
  ///    written from the event's own `postTime` and only ever forward, so a
  ///    queue drained out of order cannot walk this clock backwards and put the
  ///    line on a busy phone.
  ///  * **At least one enabled app has been seen posting since install.** The
  ///    honest reading of `apps.last_seen_at`: without this, a phone where no
  ///    included app has ever posted — nothing installed, everything switched
  ///    off — gets a line about silence that is simply a description of the
  ///    setup. `installedAtOrNull` being null fails this gate rather than
  ///    passing it: with no install date there is no "since install" to compare
  ///    against, and the app does not guess one.
  ///  * **Not shown inside the last twenty-four hours, and not dismissed in
  ///    this run.** The rule caps it at once per day, and the stamp is what
  ///    makes that survive a relaunch.
  ///
  /// What it then says: when something last arrived, and that this may be
  /// perfectly normal. What it refuses to say, in either direction: that
  /// capture has stopped, and that capture is working.
  Future<void> _resolveQuiet() async {
    if (_quietNoticeDismissed) return;

    final DateTime? lastEvent = await _repository.lastCaptureEventAt();
    if (isDisposed) return;
    final DateTime? lastConnection = await _repository
        .lastListenerConnectedAt();
    if (isDisposed) return;
    final DateTime? newest = _newerOf(lastEvent, lastConnection);
    if (newest == null) return;

    final DateTime now = _clock();
    if (now.difference(newest) < _quietWindow) return;

    final DateTime? installedAt = await _repository.installedAtOrNull();
    if (isDisposed) return;
    if (installedAt == null) return;
    final List<SourceApp> apps = await _repository.allApps();
    if (isDisposed) return;
    final bool anySeenPosting = apps.any(
      (SourceApp app) => app.enabled && app.lastSeenAt.isAfter(installedAt),
    );
    if (!anySeenPosting) return;

    final DateTime? shownAt = await _repository.quietNoticeShownAt();
    if (isDisposed) return;
    if (shownAt != null && now.difference(shownAt) < _quietWindow) return;

    // Resolved, and **not stamped**. Deciding that the line may show is not the
    // same event as a person reading it, and [markQuietNoticeShown] carries the
    // whole of why the two were separated.
    _resolve(CaptureStatusLine.quiet, since: newest);
  }

  /// The later of two instants, either of which may be absent.
  DateTime? _newerOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Sets the line and its time together, which is the only way they are ever
  /// written.
  ///
  /// One assignment rather than two because the pair is a single fact: a line
  /// left over from one branch beside a time left over from another is how a
  /// screen ends up printing PERM-11's instant inside PERM-8's sentence. The
  /// default [since] of null is what [CaptureStatusLine.none] and
  /// [CaptureStatusLine.notRunning] both want, and neither has a time to give.
  void _resolve(CaptureStatusLine line, {DateTime? since}) {
    _statusLine = line;
    _statusSince = since;
  }

  /// Announce, deferring the first one (the discipline [DeferredNotifier]
  /// documents).
  ///
  /// A screen's first read of this provider runs inside the build that is
  /// reading it — `main.dart`'s `initState` awaits the first [refresh] — so the
  /// first announcement lands on a microtask, after that build has finished.
  /// Every later one is immediate: a resume is not inside anybody's build.
  Future<void> _announce() async {
    if (_hasAnnounced) {
      notify();
      return;
    }
    _hasAnnounced = true;
    await notifyLater();
  }
}
