/// PERM-14's battery guidance — a place to look, and explicitly not a fix the
/// app promises.
///
/// **What this screen is allowed to say, and the reason the list is this
/// short.** The 24-hour OEM survival check did not run (spike, 21 September
/// 2026, check 3), so nobody has measured what any phone does to this app's
/// listener, or whether any of the settings below changes it. Section 9 is
/// blunt about what follows from that: the app offers a place to look and the
/// manufacturer it detected, and claims nothing about what a phone will do. So
/// this screen says four things and no fifth —
///
///  1. Android stops background services, and some phones stop them harder.
///  2. Replybox cannot change any of those settings for itself.
///  3. Which settings pages to look at.
///  4. That nobody has measured whether any of them keeps this listener alive.
///
/// **It never states what a named manufacturer does to this app.** It prints
/// `Build.MANUFACTURER` as the device reported it — so an unlisted phone is
/// visibly unlisted rather than silently generic — and that is the whole of
/// what it says about the make. The table it would look a phone's steps up in
/// (`lib/data/battery_guidance.dart`) ships empty by decision 11, every phone
/// therefore takes the generic branch, and an entry that ever lands there is a
/// dated record of settings pages on one verified device and still not a claim
/// about a make.
///
/// **Shown once, after the first screen and never in place of it** (PERM-14).
/// `main.dart` pushes it from the same post-frame callback the disclosure uses,
/// on the first launch or resume that reads access as granted while the stored
/// flag is unset. The flag is written here, in `initState`, and records that
/// the guidance was *shown* — never that the grant was made, so a process
/// killed on the system page still gets it next launch. It stays reachable
/// afterwards from the foot of the included-apps list, which is the only
/// Settings this version has, and from PERM-10's and PERM-11's lines.
///
/// Presentational. Every sentence is from the message files (LANG-2), the two
/// device facts come from [PermissionsProvider], and the only writes are the
/// shown-flag and the two requests to open a settings page.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/battery_guidance.dart';
import '../l10n/app_localizations.dart';
import '../providers/permissions_provider.dart';
import '../theme.dart';

/// Unicode's directional isolate pair, built by code point on purpose: both
/// characters are invisible and zero-width, and a literal one pasted into the
/// source is a character nobody reviewing this file can see.
///
/// They mark a run as its own bidirectional context, so it neither takes its
/// direction from the sentence around it nor reorders that sentence's
/// punctuation — which is what LANG-5 asks for where a left-to-right value sits
/// inside a sentence that mirrors.
final String _leftToRightIsolate = String.fromCharCode(0x2066);
final String _popDirectionalIsolate = String.fromCharCode(0x2069);

class BatteryGuidanceScreen extends StatefulWidget {
  const BatteryGuidanceScreen({super.key});

  /// Pinned. `included_apps_screen.dart` and the status lines that carry
  /// `captureGuidanceAction` both push this constant.
  static const String routeName = '/battery-guidance';

  @override
  State<BatteryGuidanceScreen> createState() => _BatteryGuidanceScreenState();
}

class _BatteryGuidanceScreenState extends State<BatteryGuidanceScreen> {
  /// Whether each page has been tried and refused to open (PERM-14, PERM-7).
  ///
  /// Two flags and not one, because they are two pages and either can be absent
  /// on its own: a build without the battery-optimisation list still has an
  /// app-info page, and replacing both controls because one failed would take
  /// away a route that works. Null is "not tried", false is "tried and nothing
  /// started"; there is no true, because a page that opened leaves the control
  /// exactly as it was — PERM-14 does not let this screen claim that anything
  /// about the app's battery treatment changed, only that an activity started.
  bool? _batteryPageOpened;
  bool? _appInfoPageOpened;

  @override
  void initState() {
    super.initState();
    // PERM-14's stored flag, written from the screen's own `initState` for the
    // same reason PERM-5's is: what it has to mean is *this was displayed*. A
    // flag written when the grant was read would be set by a process that was
    // killed on the system page before it ever drew this, and the showing the
    // user was owed would be swallowed.
    unawaited(context.read<PermissionsProvider>().markBatteryGuidanceShown());
  }

  /// PERM-14's generic branch, reached a second time (PERM-7's shape).
  ///
  /// False from the provider means no activity started, so the control is
  /// replaced by its written path and a line saying the app cannot open it —
  /// never left as a button that does nothing. True means an activity started
  /// and nothing more; nothing is recorded and nothing on screen changes,
  /// because the user is now in the settings app and what they do there is not
  /// something this app can see.
  Future<void> _openBatteryPage() async {
    final bool opened = await context
        .read<PermissionsProvider>()
        .openBatteryOptimisationSettings();
    if (!mounted) return;
    setState(() => _batteryPageOpened = opened);
  }

  Future<void> _openAppInfoPage() async {
    final bool opened = await context
        .read<PermissionsProvider>()
        .openAppInfoSettings();
    if (!mounted) return;
    setState(() => _appInfoPageOpened = opened);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final PermissionsProvider permissions = context
        .watch<PermissionsProvider>();

    final List<String> steps = _resolvedSteps(l10n, permissions.guidance);
    // An entry whose steps all dropped falls to the generic branch rather than
    // drawing an empty list: a heading with nothing under it reads as a screen
    // that failed to load, and the two Android pages below are what the app can
    // honestly offer either way.
    final bool generic = steps.isEmpty;

    final bool batteryFailed = _batteryPageOpened == false;
    final bool appInfoFailed = _appInfoPageOpened == false;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.batteryGuidanceTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Metrics.gutter,
            16,
            Metrics.gutter,
            24,
          ),
          children: <Widget>[
            _Paragraph(l10n.batteryGuidanceAndroid),
            // PERM-14's honesty clause, and it is not a footnote: it sits above
            // the controls, because a reader who takes the first two sentences
            // as a promise and then presses a button has been told the opposite
            // of what section 9 says this screen is for.
            _Paragraph(l10n.batteryGuidanceUnmeasured),

            const SizedBox(height: 8),
            _Paragraph(_manufacturerLine(l10n, permissions.manufacturer)),

            if (generic) _Paragraph(l10n.batteryGuidanceNoVerifiedSteps),

            // A verified entry's own steps, in the order they are performed.
            // Empty today and drawn from message IDs rather than from text
            // (LANG-2, DATA-1), so the first entry a hardware run writes is
            // translated with everything else.
            if (!generic)
              for (int i = 0; i < steps.length; i++)
                _Step(number: i + 1, text: steps[i]),

            const SizedBox(height: 8),

            // The two Android pages. Each is a control until this phone says it
            // is not, and then it is the written path in the control's place.
            if (batteryFailed)
              _Paragraph(l10n.batteryGuidanceBatteryPagePath)
            else
              _PageButton(
                label: l10n.batteryGuidanceBatteryPage,
                onPressed: () => unawaited(_openBatteryPage()),
              ),

            const SizedBox(height: 8),

            if (appInfoFailed)
              _Paragraph(l10n.batteryGuidanceAppInfoPagePath)
            else
              _PageButton(
                label: l10n.batteryGuidanceAppInfoPage,
                onPressed: () => unawaited(_openAppInfoPage()),
              ),

            // Said once, beside whichever written path replaced a control, and
            // not once per failure: two copies of the same sentence under two
            // paths is the same sentence, and at 1.3x text it is the thing that
            // pushes the paths themselves off the screen.
            if (batteryFailed || appInfoFailed) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                l10n.batteryGuidanceCannotOpen,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The manufacturer sentence, or the one for a phone that reported nothing.
  ///
  /// The value is wrapped in Unicode isolate marks before it goes into the
  /// message, and that is LANG-5's half of PERM-14: the sentence around it
  /// mirrors with the language, the make does not. `Build.MANUFACTURER` is a
  /// Latin string arriving inside what may be a right-to-left sentence, and
  /// without an isolate the bidi algorithm reorders it against the surrounding
  /// run — a trailing full stop lands on the wrong side of the name, and a
  /// two-word make can come out reversed. `textDirection: TextDirection.ltr` on
  /// the whole `Text`, which is what `conversation_row.dart` does for a clock,
  /// is not available here: that widget is the value and this one is a
  /// sentence, and forcing the sentence left-to-right would mirror the
  /// translation instead.
  ///
  /// LRI rather than LRM or an RLE/PDF pair: an isolate is exactly the "this
  /// run is its own thing, do not let it reorder its neighbours" primitive, and
  /// it is the one Unicode still recommends. The marks are invisible and carry
  /// no width.
  ///
  /// Null is its own sentence and never a substituted name (PERM-14): a made-up
  /// "Unknown" would be the app telling the user something about their hardware
  /// that the hardware did not say.
  String _manufacturerLine(AppLocalizations l10n, String? manufacturer) {
    if (manufacturer == null || manufacturer.isEmpty) {
      return l10n.batteryGuidanceManufacturerUnknown;
    }
    return l10n.batteryGuidanceManufacturer(
      '$_leftToRightIsolate$manufacturer$_popDirectionalIsolate',
    );
  }

  /// A verified entry's steps, resolved from message IDs to sentences.
  ///
  /// **No cases today, and that is the table's decision and not an oversight**
  /// (decision 11): `batteryGuidanceByManufacturer` is empty, so
  /// [PermissionsProvider.guidance] is always null and this never runs on a
  /// phone. The switch exists so that the first entry a dated hardware run
  /// writes has one obvious place to be hooked up, and so that the shape of
  /// that hook-up is fixed now: an ID lands here, is answered with a message,
  /// and nothing in `lib/data/` ever holds a rendered sentence (LANG-2,
  /// DATA-1).
  ///
  /// An ID this cannot resolve is **dropped** rather than drawn as itself. A
  /// message key on screen is not a sentence in any language, and an entry that
  /// out-ran the message files would otherwise print `batteryGuidanceStepsX1`
  /// to a user. Dropping every step of an entry leaves an empty list, which the
  /// build above reads as the generic branch.
  List<String> _resolvedSteps(
    AppLocalizations l10n,
    BatteryGuidanceEntry? entry,
  ) {
    if (entry == null) return const <String>[];
    final List<String> resolved = <String>[];
    for (final String id in entry.stepMessageIds) {
      final String? message = _stepMessage(l10n, id);
      if (message != null) resolved.add(message);
    }
    return resolved;
  }

  /// One step's message ID, resolved to the sentence the message files hold.
  ///
  /// Null for every ID today, because there are no per-manufacturer step
  /// messages to resolve to — the naming convention for the first one a
  /// hardware run writes is `batteryGuidanceSteps<Manufacturer><n>`, and its
  /// `case` goes in the body below. A function rather than a map, because the
  /// generated `AppLocalizations` exposes getters and not a lookup by key: the
  /// mapping from an ID to a getter has to be written out somewhere, and
  /// written out once, here, is the whole of it.
  String? _stepMessage(AppLocalizations l10n, String id) => null;
}

/// One of the two Android pages, at INB-23's floor and full width.
class _PageButton extends StatelessWidget {
  const _PageButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: const ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size.fromHeight(Metrics.minTarget),
      ),
    ),
    onPressed: onPressed,
    // The label is the control's whole semantic content (INB-23), so there is
    // no wrapper here repeating it.
    child: Text(label, textAlign: TextAlign.center),
  );
}

/// One numbered step of a verified entry.
///
/// The number is drawn beside the sentence and excluded from the semantic tree:
/// it is an ordering the layout already carries, and a reader announcing "one",
/// "two" before each step hears the list twice. Left to right inside a mirrored
/// layout, like every other number in this app (INB-23, LANG-5).
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(
                '$number.',
                textDirection: TextDirection.ltr,
                style: style,
              ),
            ),
          ),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// A sentence on this screen. No `maxLines`: PERM-14's page renders at 1.3x
/// text on a phone like every other main screen (LANG-6, INB-23), and a clipped
/// sentence here would be a limit the app stated and then hid.
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}
