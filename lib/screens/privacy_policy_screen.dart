/// The privacy policy, in the app (PERM-16).
///
/// **It ships inside the app and reading it makes no network request.** That is
/// the rule and it is also the only way this page could exist here at all: the
/// release build declares no `INTERNET` permission (PERM-15, product principle
/// 1), so a policy fetched from the hosted copy would be a blank screen on
/// every phone. Every sentence below is a message ID, translated with every
/// other string in the app (LANG-2), and the hosted copy's address is shown
/// beside them as text.
///
/// **The three claims the disclosure makes are quoted, not restated.** What is
/// read (`permissionsDisclosureReads`), that it includes apps the user never
/// named (`permissionsDisclosureAppsExplainer`) and that nothing leaves the
/// phone (`permissionsDisclosureStaysHere`) are PERM-2's and PERM-3's own
/// message IDs, drawn here by the same getters the disclosure draws them by.
/// PERM-16 asks for exactly that: a second wording of the same claim is a
/// second thing to keep true, and the first time one of them changed the app
/// would be telling a user one story on the permission screen and another on
/// the policy. A script compares this page against `docs/privacy-policy.md`;
/// nothing compares two copies inside the app, because there is only one.
///
/// **Nothing in the app leaves the phone, and that includes this screen.**
/// PERM-16 allows a control that opens the hosted copy in a browser, on the
/// condition that it is labelled as doing exactly that. No such control ships:
/// [onOpenHosted] is injected rather than reached for, `main.dart` passes
/// nothing, and the address stands on its own as selectable text — see
/// [onOpenHosted] for what is missing and why.
///
/// **Correction, 23 September 2026.** This paragraph opened *The one control in
/// the whole app that leaves the phone*, which named a control that has never
/// existed. PERM-16 was worded the same way and took its own dated correction
/// on this date: "the only thing in the app that does" names nothing, so the
/// available claim is the strictly stronger one — nothing in the app leaves the
/// phone at all (product principle 1). `docs/privacy-policy.md` now makes that
/// claim unconditionally and a stranger reads it, so a comment here still
/// describing the weaker shipped app was the drift PERM-16 exists to stop,
/// pointing the other way. If a launcher is ever added, PERM-16's labelling
/// requirement comes back with it and this paragraph goes back to what it said.
///
/// INB-24: nothing here writes a sender, a title, a message or a package name
/// anywhere but to the screen. There is no logging in this file, in any build.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Unicode's directional isolate pair, built by code point on purpose: both
/// characters are invisible and zero-width, and a literal one pasted into the
/// source is a character nobody reviewing this file can see.
///
/// They mark a run as its own bidirectional context, so it neither takes its
/// direction from the sentence around it nor reorders that sentence's
/// punctuation. That is what LANG-5 asks for where a left-to-right value sits
/// inside a sentence that mirrors.
final String _leftToRightIsolate = String.fromCharCode(0x2066);
final String _popDirectionalIsolate = String.fromCharCode(0x2069);

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({this.onOpenHosted, super.key});

  /// Pinned. `included_apps_screen.dart` pushes this constant.
  static const String routeName = '/privacy-policy';

  /// The hosted copy of this same page, served by GitHub Pages from
  /// `docs/privacy-policy.md` (docs/RELEASING.md).
  ///
  /// A constant on the screen that prints it rather than a value in
  /// `lib/data/`: it is not data the app reasons about — nothing reads it, no
  /// rule branches on it, and the app never fetches it — it is a string this
  /// one page displays. It is also the address the store listing points at, so
  /// it moves only when the listing does.
  static const String hostedAddress =
      'https://oasis-forge.github.io/Replybox/privacy-policy';

  /// Opens [hostedAddress] in the phone's browser, or null where the app has no
  /// way to.
  ///
  /// **Null everywhere today, and the control is simply absent when it is.**
  /// There is no seam in `lib/services/services.dart` that opens a URL:
  /// `AppLauncher` opens a package and a notification's own chat and nothing
  /// else, and `SystemSettings` opens the two system pages PERM-14 names. A
  /// browser route would need a method channel branch and an `ACTION_VIEW`
  /// intent that no agent owns this round, so rather than ship a button that
  /// silently does nothing — the one shape PERM-7 and PERM-14 both forbid, and
  /// the exact defect `NoopAppLauncher.succeeds` defaulting to true produced on
  /// a real phone — the page shows the address as selectable text and says
  /// nothing about opening it.
  ///
  /// Injected rather than read from the tree so that the control can be tested
  /// for what PERM-16 actually requires of it — that its label says it opens a
  /// browser and leaves the phone — before anything can open one.
  final Future<void> Function(String url)? onOpenHosted;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final Future<void> Function(String url)? open = onOpenHosted;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyPolicyTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Metrics.gutter,
            16,
            Metrics.gutter,
            24,
          ),
          children: <Widget>[
            _Heading(l10n.privacyPolicyStoredTitle),
            // PERM-2's first line and PERM-3's sentence, quoted by their own
            // message IDs. These two getters are the same ones
            // `disclosure_screen.dart` calls; if one of them changes, both
            // screens change together, which is the whole point of PERM-16's
            // "exist once".
            _Paragraph(l10n.permissionsDisclosureReads),
            _Paragraph(l10n.permissionsDisclosureAppsExplainer),
            _Paragraph(l10n.privacyPolicyStoredWhere),

            _Heading(l10n.privacyPolicyPackagesTitle),
            // Decision 13 bought this back as a rule rather than as a manifest
            // entry, and made saying it here a merge condition: the manifest's
            // MAIN + LAUNCHER `<queries>` filter makes every launchable app
            // visible to this process, and what keeps the app from reading the
            // phone's app list is a gate in code (INB-20). A page that did not
            // say so would be under-stating what the app can see.
            _Paragraph(l10n.privacyPolicyPackages),

            _Heading(l10n.privacyPolicyLeavesTitle),
            // PERM-2's third line, quoted — the third of PERM-16's three
            // shared claims.
            _Paragraph(l10n.permissionsDisclosureStaysHere),
            _Paragraph(l10n.privacyPolicyLeaves),
            _Paragraph(l10n.privacyPolicyDeleting),

            const SizedBox(height: 8),
            // The hosted copy's address, as text (PERM-16). Selectable so it
            // can be copied and typed into a browser by hand, which is the only
            // route to it while [onOpenHosted] is null — and a route worth
            // having even once there is a button, because a phone with no
            // browser is a phone the button would fail on.
            SelectableText.rich(
              TextSpan(
                // The address is wrapped in Unicode isolate marks before it
                // goes into the sentence: the sentence around it mirrors with
                // the language, a URL does not (LANG-5, INB-23). Without the
                // isolate the bidi algorithm reorders the address against a
                // right-to-left run and the trailing full stop lands inside it.
                // The marks are invisible and carry no width.
                text: l10n.privacyPolicyHostedAddress(
                  '$_leftToRightIsolate$hostedAddress$_popDirectionalIsolate',
                ),
                style: theme.textTheme.bodyMedium,
              ),
            ),

            if (open != null) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton(
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll<Size>(
                    Size.fromHeight(Metrics.minTarget),
                  ),
                ),
                onPressed: () => unawaited(open(hostedAddress)),
                // PERM-16: the label *is* the warning. It says it opens a
                // browser and that this leaves the phone, in the same words on
                // the control the user presses, rather than in a dialog
                // afterwards — by then they have already left.
                child: Text(
                  l10n.privacyPolicyOpenHosted,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A section heading.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// One claim. No `maxLines`: the policy renders at 1.3x text on a phone like
/// every other main screen (LANG-6, INB-23), and a policy that clips mid-claim
/// is worse than one that is not there.
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}
