import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// What a screen draws where a read failed and there is nothing to draw.
///
/// It exists because the alternative is worse than a sentence: a failed load
/// leaves an empty list, and an empty list is a blank white screen with nothing
/// on it to read, to tap, or to explain itself (product principle 3, RUN-1).
///
/// **It never prints the exception, in any build.** `Repository` composes its
/// failures out of the `Message` it was writing and the SQLite error, so a
/// screen that drew `error.toString()` would put a sender's name and a
/// message's text on screen — and, the moment that widget is caught by an error
/// handler, into a crash report. INB-24 forbids exactly that. So this takes a
/// line from the message files and nothing else: the exception is not a
/// parameter of this widget, which is the only way to be sure it cannot be
/// rendered by a later edit.
///
/// The body scrolls, so the longest of these lines still fits at the 1.3x text
/// scale INB-23 renders at, on a phone, in every language.
class FailureNotice extends StatelessWidget {
  const FailureNotice({required this.message, this.onRetry, super.key});

  /// A line from the message files. Never an exception, never a code, never a
  /// value read out of the database (INB-24).
  final String message;

  /// Runs the read again. Null where there is nothing useful to retry, in which
  /// case no control is drawn rather than a dead one.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: Metrics.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton.tonal(
                onPressed: onRetry,
                child: Text(l10n.retry, textAlign: TextAlign.center),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
