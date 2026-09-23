/// The permission disclosure — the app's own account of notification access,
/// said before the system page and never after (section 9, PERM-1 … PERM-7).
///
/// **This screen is the only route inside the app to the system's
/// notification-access page** (PERM-1). That is a property of the code and not
/// a convention: [PermissionsProvider.openAccessSettings] is called from
/// exactly one place in `lib/`, the primary control below, and every other
/// entry point that would lead to the system page — the first launch, PERM-8's
/// banner, the row at the foot of the included-apps list — pushes
/// [DisclosureScreen.routeName] instead. The system's own settings app is a
/// route this app cannot intercept, and PERM-5 covers a grant that arrives
/// that way: this screen is shown afterwards as information, with `Continue`
/// where the decline would be.
///
/// **It is never a gate** (PERM-4). It is pushed over the first screen and
/// popped off it; `main.dart`'s `home:` is the inbox on every launch including
/// the very first, nothing here is wrapped in a conditional that can replace a
/// screen, and the decline is one tap that leaves the inbox, the chooser and
/// search exactly as they were.
///
/// **Nothing on it advances but the two controls** (PERM-1). There is no timer
/// in this file, no auto-advance, no pre-ticked box, no "by continuing you
/// agree", and no route to the system page from inside the scrolling text —
/// the only two controls are in the fixed block at the foot, and a reader who
/// never scrolls can reach both.
///
/// Presentational, like every other screen in this app: every sentence comes
/// from the message files (LANG-2), every decision about *which* sentence comes
/// from [PermissionsProvider], and the only writes are the two the rules name —
/// recording that this screen was displayed (PERM-5) and asking for the system
/// page (PERM-7).
///
/// INB-24: nothing here writes a sender, a title, a message or a package name
/// anywhere but to the screen. There is no logging in this file, in any build.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/shipped_apps.dart';
import '../l10n/app_localizations.dart';
import '../providers/permissions_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import '../widgets/source_app.dart';

class DisclosureScreen extends StatefulWidget {
  const DisclosureScreen({super.key});

  /// Pinned. `included_apps_screen.dart` and the first-run push in `main.dart`
  /// both name this constant rather than the string, and PERM-1's "every entry
  /// point opens the disclosure first" is only enforceable while there is one
  /// name for it.
  static const String routeName = '/disclosure';

  @override
  State<DisclosureScreen> createState() => _DisclosureScreenState();
}

class _DisclosureScreenState extends State<DisclosureScreen> {
  @override
  void initState() {
    super.initState();
    // PERM-5: "onboarding is marked done only once the disclosure has actually
    // been on screen". Recorded here, from the screen's own `initState`, and
    // not from either control — what the stored fact has to mean is *it was
    // displayed*, so that a process killed on the system page, a back gesture,
    // a decline and a grant all leave the same mark. Writing it from the
    // decline would make a user who granted access and never came back get the
    // screen again; writing it from the primary control would make a back
    // gesture erase the fact that the app had already said its piece, and the
    // app would then be capturing from apps the user did not name (decision 6)
    // with the disclosure still queued behind them.
    //
    // Unawaited on purpose: the write is a settings row, it is idempotent in
    // the repository, and nothing on this screen reads it back. The provider
    // drops `shouldShowDisclosure` synchronously, which is what stops the
    // post-frame push in `main.dart` firing a second time in this launch.
    unawaited(context.read<PermissionsProvider>().markDisclosureShown());
  }

  /// PERM-1 and PERM-7, and the one call to the system page in the whole app.
  ///
  /// The screen does not stay to find out what happened, and there is nothing
  /// for it to find out: the process can be killed while the system page is
  /// open, so there is no "we came back" moment to observe (PERM-5). What the
  /// user sees on a return is whatever [PermissionsProvider.refresh] read from
  /// the system on the resume — either this screen with PERM-6's extra line,
  /// or an app with the banner gone.
  ///
  /// The false branch is PERM-7's third: nothing started, so the provider has
  /// already set [PermissionsProvider.canOpenAccessSettings] false and this
  /// build swaps the button for the written path. No snackbar and no dialog —
  /// the answer to a page that will not open is the path to it, on screen,
  /// where the button was.
  Future<void> _openSystemPage() async {
    await context.read<PermissionsProvider>().openAccessSettings();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final PermissionsProvider permissions = context
        .watch<PermissionsProvider>();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.permissionsDisclosureTitle)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // PERM-2: "the screen may scroll, the two actions may not". The
            // text is the only thing inside the scroll view, so at 1.3x text on
            // a phone the seven clauses and the six app names push each other
            // down and never push a control off the screen.
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Metrics.gutter,
                  16,
                  Metrics.gutter,
                  24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // PERM-2's five things, each as its own line and in the
                    // rule's order: what is read, what is done with it, that it
                    // stays here, what is still not visible, and that the grant
                    // can be withdrawn. The fourth is a heading with seven
                    // clauses under it, so it is built below rather than listed
                    // here.
                    _Paragraph(l10n.permissionsDisclosureReads),
                    _Paragraph(l10n.permissionsDisclosureUses),
                    _Paragraph(l10n.permissionsDisclosureStaysHere),

                    const SizedBox(height: 8),
                    _Heading(l10n.permissionsDisclosureLimitsTitle),
                    // CAP-12's four absences in CAP-12's order, then the three
                    // this area meets first (CAP-8, CAP-14/INB-13, PERM-17).
                    // Seven separate messages rather than one paragraph, so a
                    // translator sees one fact at a time and so PERM-2's test
                    // can find each clause in the tree — which is what makes it
                    // fail when CAP-12 grows an absence this list does not
                    // carry.
                    _Clause(l10n.permissionsDisclosureLimitBeforeInstall),
                    _Clause(l10n.permissionsDisclosureLimitAccessOff),
                    _Clause(l10n.permissionsDisclosureLimitAppOff),
                    _Clause(l10n.permissionsDisclosureLimitEdits),
                    _Clause(l10n.permissionsDisclosureLimitHidden),
                    _Clause(l10n.permissionsDisclosureLimitOpenInApp),
                    _Clause(l10n.permissionsDisclosureLimitWorkProfile),

                    const SizedBox(height: 8),
                    _Paragraph(l10n.permissionsDisclosureWithdraw),

                    const SizedBox(height: 16),
                    _Heading(l10n.permissionsDisclosureAppsTitle),
                    _Paragraph(l10n.permissionsDisclosureAppsExplainer),
                    const _ShippedAppList(),
                  ],
                ),
              ),
            ),

            // PERM-1: both controls, outside the scroll view, always on screen.
            _Actions(
              permissions: permissions,
              l10n: l10n,
              theme: theme,
              onOpenSystemPage: () => unawaited(_openSystemPage()),
              onClose: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The fixed block at the foot: PERM-6's extra line, then the two controls.
///
/// A widget of its own so the three shapes it can take are in one place and can
/// be read against PERM-1, PERM-5 and PERM-7 side by side. They are:
///
///  * **Access missing, the page opens** — `Turn on notification access` over
///    `Continue without it`. The ordinary first-run shape.
///  * **Access missing, no settings page** (PERM-7's third branch) — the
///    written path where the primary button was, and the decline underneath it
///    unchanged. Never a button that does nothing.
///  * **Access already granted** (PERM-5) — `Continue` as the primary, with a
///    route back to the system page beside it rather than a decline: there is
///    nothing left to decline, and the screen is being shown as information
///    about a grant the user made in the system's own settings app.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.permissions,
    required this.l10n,
    required this.theme,
    required this.onOpenSystemPage,
    required this.onClose,
  });

  final PermissionsProvider permissions;
  final AppLocalizations l10n;
  final ThemeData theme;
  final VoidCallback onOpenSystemPage;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bool hasAccess = permissions.hasAccess;
    final bool canOpen = permissions.canOpenAccessSettings;

    // PERM-7's third branch, drawn once and used by both layouts below: the
    // page cannot be opened from here, so the app says so and writes out where
    // to find it by hand (LANG-2). A `Text` and not a disabled button — a
    // greyed-out control still reads as something that would work if the user
    // pressed it correctly, and this one never will on this phone.
    final Widget writtenPath = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        l10n.permissionsDisclosureNoSettingsPage,
        style: theme.textTheme.bodyMedium,
      ),
    );

    final Widget openSystemPage = canOpen
        ? _WideButton(
            label: l10n.permissionsDisclosureTurnOn,
            onPressed: onOpenSystemPage,
            filled: !hasAccess,
          )
        : writtenPath;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Metrics.gutter,
        8,
        Metrics.gutter,
        Metrics.gutter,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // PERM-6: one extra line, and only on a return inside this run with
          // access still missing — `accessStillOff` is scoped to the run for
          // exactly that reason. It sits here, in the fixed block, rather than
          // at the top of the scrolling text: it is an answer to something the
          // user just did, and a user who came back from the system page is
          // looking at the controls and not at the top of the page. One short
          // sentence, so the two controls below it stay on screen at 1.3x.
          if (permissions.accessStillOff)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.permissionsDisclosureStillOff,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          if (hasAccess) ...<Widget>[
            // PERM-5's information shape. `Continue` is the primary because
            // there is nothing here left to decide: access is on, and the only
            // thing this screen is doing is saying what was agreed to.
            _WideButton(
              label: l10n.permissionsDisclosureContinue,
              onPressed: onClose,
              filled: true,
            ),
            const SizedBox(height: 8),
            openSystemPage,
          ] else ...<Widget>[
            openSystemPage,
            const SizedBox(height: 8),
            // PERM-4: declining is one tap, and it is a tap on this. It pops
            // the disclosure and does nothing else — no flag is written here,
            // nothing is disabled, and the screen behind it is the whole app.
            _WideButton(
              label: l10n.permissionsDisclosureDecline,
              onPressed: onClose,
              filled: false,
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the two controls, at INB-23's floor and full width.
///
/// `Size.fromHeight(Metrics.minTarget)` rather than trusting the theme's
/// `materialTapTargetSize`: that setting pads a button up to 48dp *including*
/// the padding Material adds outside its visual bounds, which is a tap target
/// and not a visible control. These two are the things a first-time user is
/// meant to find, so they are 48dp of button.
class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.label,
    required this.onPressed,
    required this.filled,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    const ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size.fromHeight(Metrics.minTarget),
      ),
    );
    // The label is the whole semantic content of the control (INB-23: a control
    // reads as one thing), so there is no `Semantics` wrapper here and no
    // second copy of the sentence — the button's own child is what a reader
    // announces.
    final Widget child = Text(label, textAlign: TextAlign.center);
    return filled
        ? FilledButton(style: style, onPressed: onPressed, child: child)
        : OutlinedButton(style: style, onPressed: onPressed, child: child);
  }
}

/// PERM-3's list: every app captured without being chosen, in full.
///
/// **Rendered from `shippedMessagingApps` and from nothing else.** That
/// constant is the single source CAP-1's native filter, INB-21's chooser, the
/// manifest's `<queries>` and this screen all read, and PERM-3 says a second
/// copy is the defect: a list typed out here would be one release away from
/// naming five apps while the filter enables six, which is precisely the app
/// capturing from something the user was never told about (decision 6).
///
/// No truncation, no "and others", no collapsed row, no `maxLines` anywhere
/// below, and no scroll view of its own — the whole list is laid out inside the
/// screen's one scroll view, so every entry is in the tree at every text scale
/// and PERM-3's test can find all six.
///
/// The label and the icon come from [sourceAppLabel] and [SourceAppFaces],
/// which is INB-1's one chain: the package manager's label for a package the
/// manifest declares, then the label the listener stored on the `apps` row, then
/// the package name. On this screen the second of those is almost always
/// absent — the point of PERM-3 is that it is read *before* any of these apps
/// has posted — so what it actually resolves is the package manager's name, and
/// the package name for an app that is not installed.
class _ShippedAppList extends StatelessWidget {
  const _ShippedAppList();

  @override
  Widget build(BuildContext context) {
    return SourceAppFaces(
      // INB-20: the app asks about exactly these six and never enumerates what
      // is installed. These are the six the manifest names one by one, which is
      // what lets a not-found here mean "not installed" and nothing else.
      packages: shippedMessagingApps,
      builder:
          (BuildContext context, Map<String, SourceAppIdentity> identities) =>
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String package in shippedMessagingApps)
                    _ShippedAppRow(
                      package: package,
                      identity: identities[package],
                    ),
                ],
              ),
    );
  }
}

/// One app on PERM-3's list: its icon, its name, and whether it is here.
///
/// Not a control and not a `ListTile`: nothing on this screen advances but the
/// two buttons (PERM-1), so this row has no tap target and no 48dp floor to
/// meet — INB-23's floor is about controls, and its correction of 22 September
/// 2026 says putting a target on something that does nothing is the defect and
/// not the fix.
///
/// It reads as one thing (INB-23). [MergeSemantics] is what does that: the icon
/// is already excluded from the tree by [SourceAppIconImage], and the name and
/// the not-installed marker are two `Text`s that a reader should hear as one
/// entry rather than as two unrelated lines.
class _ShippedAppRow extends StatelessWidget {
  const _ShippedAppRow({required this.package, this.identity});

  final String package;

  /// Null until the package manager has answered, which is not the same as
  /// [PackagePresence.unknown] and must not be drawn as one: nothing has been
  /// asked yet, and INB-16 forbids stating an absence the app has not seen.
  final SourceAppIdentity? identity;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String label = sourceAppLabel(package: package, identity: identity);

    // PERM-3 marks an app that is *not installed*, and only that. The three
    // values are three different facts (INB-16): `installed` is here,
    // `gone` is a package the manifest declares that the package manager says
    // is absent — an answer this screen can stand behind — and `unknown` is
    // nothing learned, which is also what a null identity is. Only `gone` gets
    // the marker; the other two say nothing, because the point of naming an app
    // the user can switch off before it ever posts is lost entirely if the app
    // also tells them, wrongly, that apps they have are missing.
    final bool notInstalled = identity?.presence == PackagePresence.gone;

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SourceAppIconImage(identity: identity, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: theme.textTheme.bodyLarge,
                    // INB-23, LANG-5: a package name stays left to right inside
                    // a mirrored layout. Asked by comparing against what the
                    // chain returned rather than by re-running its branches,
                    // which is the shape `source_app_row.dart` settled on — the
                    // last fallback *is* the package.
                    textDirection: label == package ? TextDirection.ltr : null,
                  ),
                  if (notInstalled)
                    Text(
                      l10n.permissionsDisclosureAppNotInstalled,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A heading inside the scrolling text.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// One of PERM-2's five lines.
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    // No `maxLines` and no `TextOverflow`: PERM-2 renders at 1.3x text on a
    // phone and fails on overflow, and a clipped sentence is a disclosure that
    // stopped mid-claim.
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

/// One clause of PERM-2's fourth line.
///
/// Bulleted with a leading dot drawn as its own excluded-from-semantics box
/// rather than with a `•` inside the sentence: a reader that announced the dot
/// would say "bullet" before each of seven absences, and a dot inside the
/// string would be untranslatable punctuation a translator has to carry
/// (LANG-2).
class _Clause extends StatelessWidget {
  const _Clause(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Mirrors with the language: the dot leads the clause in both
          // directions (INB-23, LANG-5).
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text('•', style: style),
            ),
          ),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
