import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/source_app.dart';
import '../providers/inbox_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import 'source_app.dart';

/// INB-15's three empty states, each with exactly one action.
///
/// Which one holds is [InboxProvider]'s decision, not this widget's: the rule
/// fixes an order and says the first match wins, and a screen that re-derived
/// it from three booleans would be a second place for that order to live. This
/// draws the state it is handed, and there is no branch here that can produce a
/// fourth one or a blank.
///
/// INB-24: these may be drawn on a locked screen, because every line below says
/// only what the app can and cannot see. None of them names a conversation, a
/// sender, or an app the user has messages *from* — the *Nothing yet* state
/// names included apps, which is a list the user chose and which exists before
/// any message does.
class InboxEmptyStates extends StatelessWidget {
  const InboxEmptyStates({
    required this.state,
    required this.onSeeIncludedApps,
    required this.onClearFilter,
    super.key,
  });

  final InboxEmptyState state;

  /// *Nothing yet*'s one action: the included-apps list (INB-20).
  final VoidCallback onSeeIncludedApps;

  /// *Nothing in this filter*'s one action: back to `All` (INB-14).
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    // These sentences name apps, and a name drawn here has to be the same name
    // the chip row above it draws — so it comes from INB-1's one chain, with
    // the package manager's answer in hand rather than from the stored label
    // alone. *Nothing in this filter* is reached with the chips still on
    // screen, which is exactly where the two could be seen to disagree.
    return SourceAppFaces(
      packages: _named(),
      builder:
          (BuildContext context, Map<String, SourceAppIdentity> identities) =>
              switch (state.kind) {
                InboxEmptyKind.none => const SizedBox.shrink(),
                InboxEmptyKind.nothingYet => _Body(
                  title: l10n.inboxEmptyNothingYetTitle,
                  lines: <String>[
                    // Where no included app has a label to name, the fallback
                    // says the same thing without one rather than printing an
                    // empty list.
                    if (state.namedApps.isEmpty)
                      l10n.inboxEmptyNothingYet
                    else
                      l10n.inboxEmptyNothingYetApps(
                        joinLabels(l10n, <String>[
                          // INB-1's chain, ending in the package: a row the
                          // listener wrote without a label is named by its
                          // package, never by a gap in a sentence that claims
                          // to name apps.
                          for (final SourceApp a in state.namedApps)
                            sourceAppLabel(
                              package: a.package,
                              identity: identities[a.package],
                              app: a,
                            ),
                        ]),
                        state.otherAppCount,
                      ),
                    l10n.inboxEmptyNothingYetNoHistory,
                    // CAP-12: only where a gap longer than a minute actually
                    // exists, so a rebind at boot never makes the app claim it
                    // missed something.
                    if (state.hasCaptureGap) l10n.inboxEmptyNothingYetAccessGap,
                  ],
                  actionLabel: l10n.inboxEmptyNothingYetAction,
                  onAction: onSeeIncludedApps,
                ),
                InboxEmptyKind.nothingInFilter => _Body(
                  title: l10n.inboxEmptyFilterTitle,
                  lines: <String>[
                    l10n.inboxEmptyFilter(_selectedLabels(l10n, identities)),
                  ],
                  actionLabel: l10n.inboxEmptyFilterAction,
                  onAction: onClearFilter,
                ),
                // Area SRCH owns this one: there is no search yet, so the
                // provider cannot reach it. The branch exists so the screen has
                // no fourth state and no blank — the words searched and any
                // narrowing in force arrive with the search that produced them.
                InboxEmptyKind.noResults => _Body(
                  title: l10n.inboxEmptyNoResultsTitle,
                  lines: const <String>[],
                  actionLabel: l10n.inboxEmptyNoResultsClearSearch,
                  onAction: onClearFilter,
                ),
              },
    );
  }

  /// Exactly the packages this state's own sentence names, and no others.
  ///
  /// INB-20: the app never enumerates installed packages. Two of the four
  /// states name none at all and ask nothing.
  List<String> _named() => switch (state.kind) {
    InboxEmptyKind.nothingYet => <String>[
      for (final SourceApp a in state.namedApps) a.package,
    ],
    InboxEmptyKind.nothingInFilter => state.filteredPackages,
    InboxEmptyKind.none || InboxEmptyKind.noResults => const <String>[],
  };

  /// The selected apps, named (INB-15).
  ///
  /// A selected package with no `apps` row is named by its package — INB-1's
  /// last fallback, and the only honest name the app holds for it — rather
  /// than dropped from a sentence that claims to name what is selected. The
  /// chain decides that, here as everywhere else.
  String _selectedLabels(
    AppLocalizations l10n,
    Map<String, SourceAppIdentity> identities,
  ) {
    final Map<String, SourceApp> byPackage = <String, SourceApp>{
      for (final SourceApp a in state.filteredApps) a.package: a,
    };
    return joinLabels(l10n, <String>[
      for (final String p in state.filteredPackages)
        sourceAppLabel(package: p, identity: identities[p], app: byPackage[p]),
    ]);
  }
}

/// INB-15's app lists, in the language's own grammar.
///
/// `gen-l10n` has no list formatter, so the shapes a list can take are
/// message-file lines; a one-item list is the item itself and needs none.
/// *Nothing yet* never asks for more than three — it names up to three and
/// counts the rest — but a filter selection has no such cap, and a fourth
/// selected app may not silently vanish from a sentence that claims to name
/// what is selected. Beyond three the two-item join nests, which is clumsier
/// than a real list formatter and is still every language's own conjunction
/// rather than a comma this file picked (LANG-2).
String joinLabels(AppLocalizations l10n, List<String> labels) =>
    switch (labels.length) {
      0 => '',
      1 => labels[0],
      2 => l10n.listTwo(labels[0], labels[1]),
      3 => l10n.listThree(labels[0], labels[1], labels[2]),
      _ => l10n.listTwo(labels[0], joinLabels(l10n, labels.sublist(1))),
    };

class _Body extends StatelessWidget {
  const _Body({
    required this.title,
    required this.lines,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final List<String> lines;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        // Scrollable so the longest of these states still fits at the 1.3x
        // text scale INB-23 renders at, on a phone, in every language.
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: Metrics.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            for (final String line in lines) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                line,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 20),
            // Exactly one, always (INB-15).
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
