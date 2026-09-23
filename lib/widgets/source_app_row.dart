/// One row of the included-apps list (INB-21).
///
/// Presentational and stateless: every value it draws comes from
/// [IncludedApp], every string from the message files, and every mutation goes
/// back out through a callback. It resolves nothing and asks the phone nothing
/// — [identity] is handed in already resolved, because INB-20 forbids
/// enumerating installed packages and a widget that did its own lookups would
/// be one refactor away from doing exactly that.
library;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/apps_provider.dart';
import '../services/services.dart';
import 'source_app.dart';

/// INB-23: every control this section names has a tap target of at least 48dp
/// on its shorter side.
const double kMinTapTarget = 48;

/// What went wrong on this row, as a value rather than as the exception that
/// caused it.
///
/// The exception is not a parameter of this widget and never will be:
/// `Repository` composes its failures out of the `Message` it was writing and
/// the SQLite error, so a row that drew `error.toString()` would put a sender's
/// name and a message's text on screen and, the moment an error handler caught
/// it, into a crash report (INB-24). An enum cannot carry either.
enum SourceAppRowFailure {
  /// The write did not land, so the row on disk is as it was and the switch is
  /// back where it started (INB-22).
  write,

  /// The row moved on disk and CAP-1's filter never heard it. Nothing on screen
  /// is wrong, which is exactly why INB-22 says it has to be told: until the
  /// next launch or resume re-mirrors, the listener is still working from the
  /// old set — dropping this package's notifications before the queue where the
  /// switch went on, and capturing from it where the switch went off.
  captureFilter,
}

class SourceAppRow extends StatelessWidget {
  const SourceAppRow({
    required this.app,
    required this.identity,
    required this.onEnabledChanged,
    this.onRemoveMessages,
    this.failure,
    this.onRetryCaptureFilter,
    super.key,
  });

  final IncludedApp app;

  /// What the package manager said about this package, or null while the
  /// lookup is still in flight. Null and [PackagePresence.unknown] draw the
  /// same row: INB-16 says the app never claims an app is gone unless it can
  /// see that it is, and "not asked yet" is not seeing it.
  final SourceAppIdentity? identity;

  /// INB-22: the switch moving is the whole confirmation. No dialog stands
  /// after it, so this fires straight through.
  final ValueChanged<bool> onEnabledChanged;

  /// INB-22's separate, explicit action on the same row. Null where there is
  /// nothing stored to remove, in which case the control is not drawn at all
  /// rather than drawn dead.
  final VoidCallback? onRemoveMessages;

  /// What just failed on this row, or null where nothing has (INB-22).
  ///
  /// Held here rather than derived: which row a failure belongs to is the
  /// state layer's answer (`StateFailure.package`), and a row that worked it
  /// out from the switch it is drawing would be guessing.
  final SourceAppRowFailure? failure;

  /// Mirrors the enabled set down to CAP-1's filter again, for the one failure
  /// that has something to retry. Drawn only beside
  /// [SourceAppRowFailure.captureFilter]: a refused write left nothing to
  /// retry but the switch itself, which is already there.
  final VoidCallback? onRetryCaptureFilter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    // INB-1's fallback chain, from the one place that holds it: the package
    // manager's label for a package inside INB-16's `<queries>` declaration,
    // then the label the listener stored on the `apps` row (INB-20), then the
    // package name. A second copy here was a second place for it to be one
    // branch out of date, and it was — it had no presence check and no
    // emptiness check, so a stored label of `''` drew a row with no name and a
    // switch labelled with nothing.
    final String label = sourceAppLabel(
      package: app.package,
      identity: identity,
      app: app.row,
    );

    // INB-16: only a package the manifest declares can be told apart, and only
    // `gone` is evidence of an uninstall. `unknown` — every app that reached
    // this list by posting rather than by shipping in it — says nothing.
    final bool gone = identity?.presence == PackagePresence.gone;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // INB-1's icon, from the one widget that draws it. An icon that
              // could not be drawn never changes what the row says about the
              // app being installed: they are two facts.
              //
              // This row used to draw its own `Icons.apps_outlined` fallback,
              // so an app whose icon did not resolve wore one glyph in the
              // inbox and a different one here. INB-1 has one generic source
              // icon, and `source_app.dart` states which it is and why.
              SourceAppIconImage(identity: identity, size: _iconSize),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: theme.textTheme.bodyLarge,
                      // INB-23: package names stay left to right inside a
                      // mirrored layout. The chain's last fallback *is* the
                      // package, so comparing against what it returned asks the
                      // one chain rather than re-running its branches.
                      textDirection: label == app.package
                          ? TextDirection.ltr
                          : null,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // INB-21: either the number of conversations stored from
                      // it, or that nothing has arrived yet.
                      app.hasCaptured
                          ? l10n.includedAppsConversations(
                              app.conversationCount,
                            )
                          : l10n.includedAppsNothingYet,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (gone) ...<Widget>[
                      const SizedBox(height: 2),
                      // INB-16/INB-21: a row for an app no longer installed
                      // says so, and keeps a working switch below.
                      Text(
                        l10n.includedAppsNotInstalled,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Merged rather than nested, so a screen reader reads one node —
              // the label from the message files plus the switch's own state —
              // instead of announcing the row's app name twice (INB-23).
              MergeSemantics(
                child: Semantics(
                  label: l10n.semanticsAppSwitch(label),
                  // The explainer is the screen's standing line; repeating it
                  // into every switch's hint is what a screen reader would read
                  // aloud on every row, so it is said once, above (INB-22).
                  child: Switch(
                    value: app.enabled,
                    onChanged: onEnabledChanged,
                  ),
                ),
              ),
            ],
          ),
          // INB-22: on the row it happened to, not as a screen-wide banner —
          // the failure is about this app's messages and about nothing else on
          // the list. The capture-filter line stands until something actually
          // mirrors the set down again, because the disagreement it names
          // stands until then too.
          if (failure != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(56, 4, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _failureLine(l10n),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  if (failure == SourceAppRowFailure.captureFilter &&
                      onRetryCaptureFilter != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        // INB-23's floor, and a minimum rather than a height so
                        // a longer language's word still fits at 1.3x text.
                        minimumSize: const Size(kMinTapTarget, kMinTapTarget),
                        alignment: AlignmentDirectional.centerStart,
                      ),
                      onPressed: onRetryCaptureFilter,
                      child: Text(l10n.retry),
                    ),
                ],
              ),
            ),
          if (onRemoveMessages != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(56, 0, 0, 0),
              child: Semantics(
                label: l10n.semanticsRemoveMessages(label),
                button: true,
                excludeSemantics: true,
                // The excluded subtree takes the button's own tap action with
                // it, so it is declared here: without it a screen reader reads
                // this control and has no way to press it (INB-23).
                onTap: onRemoveMessages,
                child: TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(kMinTapTarget, kMinTapTarget),
                    alignment: AlignmentDirectional.centerStart,
                  ),
                  onPressed: onRemoveMessages,
                  child: Text(l10n.includedAppsRemoveMessages),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One line from the message files for each failure, and no other source.
  ///
  /// The capture-filter line differs by direction because what it costs the
  /// user differs by direction (INB-22): switched on, the listener goes on
  /// dropping this package's notifications and those messages are gone rather
  /// than late; switched off, it goes on storing them. [IncludedApp.enabled] is
  /// read back from the row on disk, which is the half of the pair that did
  /// move, so it is what the sentence is about.
  String _failureLine(AppLocalizations l10n) => switch (failure!) {
    SourceAppRowFailure.write => l10n.changeFailed,
    SourceAppRowFailure.captureFilter =>
      app.enabled
          ? l10n.includedAppsSwitchOnNotLive
          : l10n.includedAppsSwitchOffNotLive,
  };
}

/// The icon's box on this row. Larger than the inbox's badge because this list
/// is about the apps themselves and nothing else on the row competes with it;
/// what it draws inside the box is [SourceAppIconImage]'s business.
const double _iconSize = 40;
