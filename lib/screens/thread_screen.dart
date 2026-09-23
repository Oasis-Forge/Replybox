import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/repository.dart';
import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../providers/inbox_provider.dart';
import '../providers/thread_provider.dart';
import '../services/services.dart';
// INB-13's 16dp gutter and 48dp height are the same numbers INB-23 fixes for
// every control in this area, so they come from the one place that holds them
// rather than being written out again here.
import '../theme.dart';
import '../widgets/date_separator.dart';
import '../widgets/failure_notice.dart';
import '../widgets/message_bubble.dart';
import '../widgets/thread_notice.dart';

/// The second tap (INB-7 to INB-13, INB-18).
///
/// Takes the conversation the list already has, so the header draws in the
/// first frame instead of waiting on a read: the list holds the row it was
/// tapped on, and re-fetching it only to draw the same title would put a blank
/// bar on screen for a frame. The provider's copy replaces it as soon as it
/// lands — it is the fresher one, having just advanced `read_through_at`.
///
/// **What has to be above this route.** The screen builds its own
/// [ThreadProvider], because a thread's lifetime is the time one is open
/// (`thread_provider.dart` says why it is not a field on the list's provider),
/// and it takes what that needs from the tree: a `Repository` and a
/// `DeviceServices`, plus a [CaptureSignal] where one is provided — without the
/// signal the thread still draws, it just will not redraw inside INB-25's
/// second when capture writes something while it is open.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    required this.conversation,
    this.createProvider,
    super.key,
  });

  /// The row the list was tapped on.
  final Conversation conversation;

  /// Test seam. The screen owns and disposes whatever this returns, exactly as
  /// it owns the one it builds itself.
  final ThreadProvider Function(BuildContext context)? createProvider;

  /// The route the list pushes.
  static Route<void> route(Conversation conversation) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ThreadScreen(conversation: conversation),
      );

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

/// What INB-13's bottom bar can honestly offer for this conversation.
///
/// Five states and not a label with a fallback, because four of the five are
/// different facts about the phone and INB-16 forbids collapsing them: the app
/// has seen the app go, the app is holding its notification, the app can see the
/// app is there and can be opened, the app can see it and there is nothing in it
/// to open, and the app cannot see anything at all. Two of those used to draw a
/// button that failed on every tap.
enum _OpenPath {
  /// This process holds the notification's own content intent (INB-13's first
  /// path). The only path that works for a package outside the manifest's
  /// `<queries>`, because a `PendingIntent` needs no package visibility.
  chat,

  /// No notification held, and the package manager resolved both the app
  /// ([PackagePresence.installed]) and a launcher intent for it
  /// ([Launchability.launchable]), so that intent can be started.
  app,

  /// The package manager resolved the app and no launcher intent for it
  /// ([Launchability.noLauncher]): it is installed, it has a name and an icon,
  /// and it has no screen to open.
  ///
  /// The state the 23 September 2026 drill found the screen could not reach.
  /// `com.android.shell` is installed and resolvable and has no launcher
  /// activity, so the bar drew `Open Shell` and every tap produced INB-13's
  /// snackbar — a control that could never work, which is the shape [none] was
  /// added to remove and then did not cover, because the code asked
  /// `PackagePresence` (does this package exist) while meaning `Launchability`
  /// (can I open it).
  noLauncher,

  /// [PackagePresence.gone]: the app was inside the declaration and the package
  /// manager says it is not there. INB-16's line, in place of the control.
  gone,

  /// Nothing held and nothing the app may conclude ([PackagePresence.unknown]).
  ///
  /// There is no launch left to offer. `getLaunchIntentForPackage` is filtered
  /// by package visibility and answers null for every package the manifest does
  /// not declare, and INB-20 keeps `QUERY_ALL_PACKAGES` out of the build — so a
  /// control here could only ever produce INB-13's "could not be opened"
  /// snackbar, every time, for the life of the app. The bar says that instead.
  none,
}

class _ThreadScreenState extends State<ThreadScreen>
    with WidgetsBindingObserver {
  /// How close to the end still counts as "the newest message was fully
  /// visible" (INB-7). The list's own bottom padding, so a view resting against
  /// the last bubble counts even though the scrollable has a few pixels left.
  static const double _pinTolerance = 12;

  /// A jump lands on an estimate while the list is still building its tail, so
  /// it repeats until it stops moving. Bounded, because a list whose extents
  /// never settle would otherwise jump on every frame for the life of the
  /// screen.
  static const int _jumpAttempts = 8;

  final ScrollController _scroll = ScrollController();

  late final ThreadProvider _thread;

  /// INB-16's three answers. Null until the first lookup lands, which reads the
  /// same as [PackagePresence.unknown]: the app says less rather than guessing.
  SourceAppIdentity? _identity;

  /// The two services this screen keeps asking, held from [initState].
  ///
  /// Read once rather than on each use: [dispose] and the lifecycle callback both
  /// run at moments when reading from the tree is not allowed, and an inherited
  /// widget looked up there is the shape that throws after the route is gone.
  PackageInfoService? _packages;
  AppLauncher? _launcher;

  /// The notification key [_chatHeld] is an answer about, or null before the
  /// first ask. The empty string means the thread has no message to ask about.
  String? _askedKey;

  /// Whether this process still holds that notification's own content intent, so
  /// INB-13's `Open chat` can be offered (CAP-14).
  ///
  /// False until the listener says otherwise, which is the honest cold-start
  /// answer: a `PendingIntent` cannot be serialised, so nothing survives the
  /// process that received it.
  bool _chatHeld = false;

  int _drawnEntries = 0;
  bool _openedAtNewest = false;

  /// INB-7: the view follows a message that arrives while the thread is open
  /// only if the newest one was fully visible when it arrived.
  bool _pinnedToNewest = true;

  @override
  void initState() {
    super.initState();
    _thread =
        widget.createProvider?.call(context) ?? _providerFromTree(context);
    _thread.addListener(_onThreadChanged);
    _scroll.addListener(_rememberPin);
    unawaited(_thread.open(widget.conversation.id));

    final DeviceServices? services = _readOrNull<DeviceServices>(context);
    _packages = services?.packages;
    _launcher = services?.launcher;

    final PackageInfoService? packages = _packages;
    if (packages != null) {
      // Synchronous first, so a package the list already asked about draws its
      // answer in the first frame instead of flashing a different control.
      _identity = packages.lookupCached(widget.conversation.package);
      unawaited(_lookUpPackage(packages));
    }

    // INB-16's `sourceAppGone` line and a re-installed app's icon both depend on
    // the screen asking again after the user has been away, and this screen used
    // to ask only here. `main.dart` drops the package manager's answers on every
    // resume and its comment claimed that was what made the line appear; it is
    // half of it — nothing re-asked, so the thread went on drawing `Open
    // WhatsApp` with the old name and icon over an app that had just been
    // uninstalled, and the tap failed with a snackbar.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _thread.removeListener(_onThreadChanged);
    // `close()` and then `dispose()` would be one notification into a tree that
    // is coming down. Disposing does what closing was for — the thread's
    // messages go with the screen rather than staying in memory behind the
    // list — and it drops the capture signal's listener on the way out.
    _thread.dispose();
    _scroll.removeListener(_rememberPin);
    _scroll.dispose();
    super.dispose();
  }

  ThreadProvider _providerFromTree(BuildContext context) => ThreadProvider(
    context.read<Repository>(),
    context.read<DeviceServices>(),
    captureSignal: _readOrNull<CaptureSignal>(context),
  );

  static T? _readOrNull<T extends Object>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Both of the bar's facts can change while the user is away, and nothing
  /// tells the app (INB-13, INB-16).
  ///
  ///  * The source app can be uninstalled or re-installed. Watching for that
  ///    would mean a broadcast receiver, a component this app does not have, so
  ///    the answer is dropped and asked again rather than watched for
  ///    ([PackageInfoService.forgetAll]).
  ///  * The listener can be disconnected and reconnected, which clears the
  ///    in-memory map (CAP-13, CAP-14). A `Open chat` label held over that would
  ///    promise a chat nothing can open.
  ///
  /// `forgetAll` is called here rather than relied on from `main.dart`, which
  /// also calls it on resume. Both are idempotent, and doing it here is what
  /// makes this screen's answer depend on this screen instead of on which
  /// observer the binding happens to notify first.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final PackageInfoService? packages = _packages;
    if (packages != null) {
      packages.forgetAll();
      unawaited(_lookUpPackage(packages));
    }
    unawaited(_askWhetherChatIsHeld(again: true));
  }

  /// INB-16: never throws, and every failure is [PackagePresence.unknown]
  /// rather than a sentence the screen would have to invent.
  Future<void> _lookUpPackage(PackageInfoService packages) async {
    final SourceAppIdentity identity = await packages.lookup(
      widget.conversation.package,
    );
    if (!mounted) return;
    setState(() => _identity = identity);
  }

  /// INB-13's first path, asked before the tap because the label says which
  /// launch will run.
  ///
  /// The key is the newest message's, which is the notification the control is
  /// about: `Open chat` opens the conversation where its last message arrived.
  /// Asked once per notification, because the answer only moves when the thread
  /// grows a newer message or the app has been away ([again]).
  ///
  /// Never throws — [AppLauncher.canOpenChat] spends every failure as "nothing
  /// is held", which is a state the bar already has a sentence for.
  ///
  /// The old answer stands for the length of one channel round trip after a
  /// newer message arrives, rather than the control blanking and coming back on
  /// every message. A tap inside that window fires the *new* key, so the worst
  /// case is INB-13's snackbar and never a launch into the wrong conversation.
  Future<void> _askWhetherChatIsHeld({bool again = false}) async {
    final AppLauncher? launcher = _launcher;
    if (launcher == null) return;
    final List<ThreadEntry> entries = _thread.entries;
    // Empty rather than null, so "this thread has no notification to ask about"
    // is a value [_askedKey] can hold and not a repeated ask.
    final String key = entries.isEmpty
        ? ''
        : entries.last.message.notificationKey;
    if (!again && key == _askedKey) return;
    _askedKey = key;
    final bool held = key.isEmpty ? false : await launcher.canOpenChat(key);
    // The thread moved on while the ask was in flight; that newer ask owns the
    // answer.
    if (!mounted || _askedKey != key || held == _chatHeld) return;
    setState(() => _chatHeld = held);
  }

  /// Which of INB-13's launches the bar may offer, in the order the rule fixes.
  ///
  /// `gone` comes first and outranks a held notification on purpose: INB-16 says
  /// the line stands *in place of* the control for an app the package manager
  /// says is not there, and a content intent into an uninstalled app is a
  /// `PendingIntent` whose target no longer exists.
  ///
  /// A held notification outranks [Launchability.noLauncher] for the opposite
  /// reason, and that order is the whole value of the content intent: an app
  /// with no launcher activity is precisely the app nothing else can reach, so
  /// while its notification is held there is a working second tap, and only
  /// after that is gone does the bar fall to the line.
  _OpenPath get _openPath {
    if (_identity?.presence == PackagePresence.gone) return _OpenPath.gone;
    if (_chatHeld) return _OpenPath.chat;
    if (_identity?.presence != PackagePresence.installed) return _OpenPath.none;
    // INB-13, corrected 23 September 2026: `installed` answers "is this package
    // on the phone", and the control needs "is there anything to open". Only a
    // measured no withholds the control — [Launchability.unknown] means the
    // answer did not travel, and a launch that then fails is the snackbar this
    // rule has always had.
    return _identity?.launchability == Launchability.noLauncher
        ? _OpenPath.noLauncher
        : _OpenPath.app;
  }

  void _rememberPin() {
    if (!_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    _pinnedToNewest =
        position.maxScrollExtent - position.pixels <= _pinTolerance;
  }

  /// INB-7's two scroll rules, and nothing else moves this list.
  ///
  ///  * it opens scrolled to the newest message;
  ///  * a message arriving while it is open is appended in place — the list is
  ///    oldest-first, so appending at the end moves nothing the reader is
  ///    looking at — and the view follows only if the newest was fully visible.
  void _onThreadChanged() {
    // A newer message is a newer notification, and INB-13's control is about the
    // newest one. Asked here rather than once at open, so a message arriving
    // while the thread is up can turn `Open chat` on within INB-25's second.
    unawaited(_askWhetherChatIsHeld());
    final int entries = _thread.entries.length;
    if (entries == _drawnEntries) return;
    final bool grew = entries > _drawnEntries;
    _drawnEntries = entries;
    if (entries == 0) return;
    if (!_openedAtNewest) {
      _openedAtNewest = true;
      _jumpToNewest(_jumpAttempts);
    } else if (grew && _pinnedToNewest) {
      _jumpToNewest(_jumpAttempts);
    }
  }

  void _jumpToNewest(int attemptsLeft) {
    if (attemptsLeft <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ScrollPosition position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      _scroll.jumpTo(position.maxScrollExtent);
      // The jump built more of the tail, so the end may have moved further
      // away. Try again on the next frame until it stops moving.
      _jumpToNewest(attemptsLeft - 1);
    });
  }

  /// INB-1's fallback chain, for every line that has to name the source app:
  /// the package manager's label for a declared package, then the label the
  /// listener stored on the `apps` row (INB-20), then the package name.
  String _appLabel(ThreadProvider thread) {
    final String? resolved = _identity?.label;
    if (resolved != null && resolved.isNotEmpty) return resolved;
    final String? stored = thread.sourceApp?.label;
    if (stored != null && stored.isNotEmpty) return stored;
    return widget.conversation.package;
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThreadProvider>.value(
      value: _thread,
      child: Consumer<ThreadProvider>(
        builder: (BuildContext context, ThreadProvider thread, _) {
          // The provider's copy once it has one; the list's until then, so the
          // header never blanks.
          final Conversation conversation =
              thread.conversation ?? widget.conversation;
          final bool isRaw = conversation.keySource == KeySource.package;
          final String appLabel = _appLabel(thread);

          // The conversation was removed underneath this screen — swiped from
          // the list, or taken by the included-apps list's "remove stored
          // messages" — while the route was still up (INB-6, INB-22, DEL-1).
          // A state of its own, which the provider decides: nothing failed and
          // the thread is not a conversation the app captured nothing for, and
          // this screen used to draw it as the second of those under a title
          // read from the row the list was tapped on.
          final bool gone = thread.conversationGone;

          return Scaffold(
            appBar: AppBar(
              // INB-2 and INB-12: a conversation with no name, and a raw one,
              // are both titled with the source app's name. INB-6 puts the only
              // delete in the list's swipe, so there is no action here.
              //
              // A deleted conversation keeps its title. It is the row the user
              // tapped and then deleted, and it is the only answer this screen
              // has to "which one went"; what made it read as stale was the
              // body underneath it saying nothing, which it no longer does.
              title: Text(
                conversation.isUnnamed || isRaw ? appLabel : conversation.title,
              ),
            ),
            body: gone
                ? FailureNotice(
                    // No retry: there is nothing to read again, and a control
                    // that ran the same read to the same answer would be a dead
                    // one. The bar's own back arrow is the way out. The line
                    // names no title and no sender (INB-24).
                    message: AppLocalizations.of(
                      context,
                    ).threadConversationGone,
                  )
                : _body(thread, conversation, isRaw, appLabel),
            // INB-13's control opens the source app *for this conversation*.
            // With no conversation left there is nothing for the second tap to
            // be about, so the bar goes rather than standing over a screen that
            // has just said there is nothing here.
            bottomNavigationBar: gone
                ? null
                : _BottomBar(
                    path: _openPath,
                    appLabel: appLabel,
                    hiddenNewest: thread.newestMessageHidden,
                    onOpen: () => _openSourceApp(thread),
                  ),
          );
        },
      ),
    );
  }

  Widget _body(
    ThreadProvider thread,
    Conversation conversation,
    bool isRaw,
    String appLabel,
  ) {
    // The one spinner on this screen, and it is the first read of the thread —
    // never the top of a loaded list, which INB-10 says must not suggest there
    // is more to load. A refresh keeps the notice, so it never reaches this.
    if (thread.isLoading && thread.notice == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // The read failed and left nothing behind. Without this the thread is a
    // list holding INB-10's notice and no messages, which reads as a
    // conversation the app captured nothing for — it would be saying something
    // untrue rather than saying nothing (product principle 3).
    if (thread.error != null && thread.entries.isEmpty) {
      return FailureNotice(
        // The line, never the exception: `Repository` builds its failures out
        // of the `Message` it was writing (INB-24).
        message: AppLocalizations.of(context).threadLoadFailed,
        onRetry: () => unawaited(_thread.open(widget.conversation.id)),
      );
    }

    final List<ThreadEntry> entries = thread.entries;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: _pinTolerance),
      // INB-10's notice is the first row of the list itself rather than a
      // header pinned above it: it scrolls away with the oldest message, and
      // reaching it is the whole of what scrolling to the top does. Nothing
      // loads there.
      itemCount: entries.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return ThreadNotice(
            notice: thread.notice,
            isRaw: isRaw,
            isUnnamed: conversation.isUnnamed,
            sourceAppEnabled: thread.sourceAppEnabled,
            // INB-10's window line comes with the notice itself
            // ([ThreadHistoryNotice.hidesOlderMessages]) rather than as a
            // second parameter, because it is part of one sentence with the
            // notice's date: a date the drawn messages do not reach is only
            // honest beside the reason they do not.
            appLabel: appLabel,
          );
        }
        final ThreadEntry entry = entries[index - 1];
        final Widget message = MessageBubble(
          message: entry.message,
          showsSender: entry.showsSender,
        );
        if (!entry.startsDay) return message;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DateSeparator(day: localDayOf(entry.message.sentAt)),
            message,
          ],
        );
      },
    );
  }

  /// INB-13: a launch that throws or resolves to nothing changes nothing on
  /// screen — one snackbar, for about five seconds, saying only that the app
  /// could not be opened (INB-16 is why it names no app).
  ///
  /// Which launch runs was decided before the tap, by the label the user read.
  /// Neither path falls through to the other: `Open chat` that found nothing
  /// held does **not** open the app's home screen instead, because that is the
  /// same lie in the other direction (`AppLaunch.kt`).
  Future<void> _openSourceApp(ThreadProvider thread) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool opened = switch (_openPath) {
      // The content intent belongs to the notification the newest message
      // arrived on, which is the one [_askWhetherChatIsHeld] asked about.
      _OpenPath.chat => await _openChat(),
      _OpenPath.app => await thread.openSourceApp(),
      // None of the three draws a control, so none has a tap to spend.
      _OpenPath.gone || _OpenPath.noLauncher || _OpenPath.none => false,
    };
    if (!mounted || opened) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.openAppFailed),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// INB-13's content-intent launch, fired straight at the service, and then
  /// checked.
  ///
  /// Not through the provider: `ThreadProvider.openSourceApp` is the launcher
  /// path and takes a package, and this path takes a notification key the
  /// provider has no reason to hold.
  ///
  /// Nothing else differs from the launcher path — the answer is the same
  /// boolean, spent the same way, and it means the same thing: the app opened,
  /// or it did not. On this path that took work, because `PendingIntent.send()`
  /// reports the send and not the launch; `android_app_launcher.dart` is where
  /// the difference is made up, so this screen can keep spending one boolean
  /// (INB-13, corrected 23 September 2026).
  Future<bool> _openChat() async {
    final AppLauncher? launcher = _launcher;
    final String? key = _askedKey;
    if (launcher == null || key == null || key.isEmpty) return false;
    try {
      return await launcher.openChat(key);
    } on Object {
      // A launch that throws and a launch that resolved to nothing are one
      // outcome in INB-13.
      return false;
    }
  }
}

/// INB-13's bar: full width inside 16dp gutters and 48dp high, which is the bar
/// the reply field will occupy when area REP ships — so the second tap stays in
/// the same place whichever state the conversation is in (product principle 5).
///
/// It is drawn on every thread, not only on one with no live action. Until REP
/// ships this control *is* the second tap of the reply path (INB-18), and a bar
/// that appeared and vanished with CAP-14's in-memory map would move the second
/// tap between one launch and the next.
///
/// ## The bar is always here; the control is not always a control
///
/// Three of [_OpenPath]'s five states draw a sentence where the button would
/// be, and the bar keeps its place and its height either way. INB-16 already did
/// that for an app the package manager says is gone. [_OpenPath.none] is the
/// same shape for the same reason: there, no launch this app is allowed to make
/// can land, so a button would be a control whose every tap ends in INB-13's
/// snackbar. A control that cannot work is not a control, and product principle
/// 3 makes the honest move the one that says so.
///
/// [_OpenPath.noLauncher] is the third, and it is the one the first two missed.
/// The app is installed and the app is visible and there is still nothing to
/// start, and the 23 September 2026 drill found the bar drawing `Open Shell`
/// over exactly that and failing on every tap. Each of the three says a
/// different true thing: the app is gone, the app has no screen to open, or
/// Replybox cannot see the app at all.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.path,
    required this.appLabel,
    required this.hiddenNewest,
    required this.onOpen,
  });

  /// Which of INB-13's launches this bar may offer, or neither.
  final _OpenPath path;

  final String appLabel;

  /// INB-3: while the newest message is hidden the bar holds this control
  /// whatever the action map says, and the line beside it states that the app
  /// chose not to answer a message it cannot show — a capability declined, not
  /// a platform limit.
  final bool hiddenNewest;

  final Future<void> Function() onOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Metrics.gutter,
          8,
          Metrics.gutter,
          8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (hiddenNewest)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  l10n.hiddenNoReply,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            _control(context, l10n, theme),
          ],
        ),
      ),
    );
  }

  Widget _control(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    // INB-16: inside the manifest's `<queries>` a not-found is an uninstall and
    // nothing else, and the line replaces the control rather than offering a
    // launch that cannot land.
    if (path == _OpenPath.gone) return _line(theme, l10n.sourceAppGone);

    // The app is there, the app has a name, and the app has no screen to open
    // (INB-13, 23 September 2026). Its own sentence and not INB-16's `gone`
    // line, because nothing has been uninstalled, and not the `unknown` line
    // either, because this is not the app saying it cannot see: it looked, and
    // there is nothing to start. A button here is the dead control the drill
    // found on `com.android.shell`.
    if (path == _OpenPath.noLauncher) {
      return _line(theme, l10n.sourceAppNoLauncher(appLabel));
    }

    // The same move, for the state the app cannot see into at all. INB-16's
    // `unknown` lets the app *say less* — it does not make a button that fails
    // every time honest, and that is what `Open in app` was here: the package is
    // outside the declaration, so its launcher intent is filtered by package
    // visibility and resolves to nothing on every tap, for good (INB-20).
    //
    // The line names no uninstall, because the app has seen none. It names the
    // limit it does know: it does not read what is installed on the phone.
    if (path == _OpenPath.none) {
      return _line(theme, l10n.sourceAppNotOpenable(appLabel));
    }

    // INB-13: the label says which launch will run, and only a package the
    // package manager actually resolved is named. `Open chat` names none — it
    // opens the conversation where its last message arrived, and the app claims
    // nothing about the app around it.
    final bool chat = path == _OpenPath.chat;
    final String label = chat ? l10n.openChat : l10n.openApp(appLabel);

    // INB-13 says the label says which path it is, and that has to hold for a
    // screen reader too. One label for both paths is what the 23 September 2026
    // drill found: `Open chat` and `Open <app>` are two different launches to
    // two different places, and both read out as the same sentence, so the one
    // distinction the rule makes was the one a screen-reader user could not
    // hear.
    final String semantics = chat
        ? l10n.semanticsOpenChat
        : l10n.semanticsOpenInApp(appLabel);

    return ConstrainedBox(
      // INB-23: 48dp on its shorter side, and the gutters around it are
      // INB-13's 16dp. A minimum, not a height: `Open <app>` carries a name the
      // app did not choose, and at 1.3x a long one is two lines — a button
      // pinned to 48dp would cut them off.
      constraints: const BoxConstraints(minHeight: Metrics.minTarget),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => unawaited(onOpen()),
          // INB-23's semantic label, put *inside* the button so the button's
          // own node carries it: a `Semantics` wrapped around the button would
          // leave two nodes and the label would be read twice.
          child: Semantics(
            label: semantics,
            child: ExcludeSemantics(
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A sentence where the control would be (INB-16).
  ///
  /// A minimum height and not a height. This is a wrapping sentence, and at the
  /// 1.3x text scale INB-23 renders at it is two lines on a 360dp phone in
  /// English and three in a longer language; a box fixed at 48dp cannot grow to
  /// hold them and the screen fails on overflow. INB-23's floor is what the 48
  /// was for, so it stays as the floor it is.
  Widget _line(ThemeData theme, String text) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: Metrics.minTarget),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}
