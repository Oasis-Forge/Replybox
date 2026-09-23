import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/message.dart';
import '../providers/inbox_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import 'message_time.dart';
import 'source_app.dart';

/// One row of the conversation list (INB-1).
///
/// Presentational: every decision it draws — the order, the initials, the
/// unread count, whether the preview names a sender — was already made in
/// [InboxRow]. What is decided here is only what a screen may decide: which
/// message-file line a non-text message shows (INB-3, INB-11, INB-12), and
/// which of INB-1's label fallbacks the package resolved to.
///
/// INB-24: nothing in this file writes a title, a sender, a message or a
/// package anywhere but to the screen. There is no logging in it, in any build.
class ConversationRow extends StatelessWidget {
  const ConversationRow({
    required this.row,
    required this.now,
    required this.onTap,
    super.key,
  });

  final InboxRow row;

  /// The instant the list was drawn at, so every row in one frame agrees about
  /// what "today" is (INB-1).
  final DateTime now;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String locale = Localizations.localeOf(context).toString();
    final String time = formatRowTime(row.time, now, locale);

    return SourceAppFace(
      package: row.conversation.package,
      builder: (BuildContext context, SourceAppIdentity? identity) {
        final String appLabel = sourceAppLabel(
          package: row.conversation.package,
          identity: identity,
          app: row.app,
        );
        // INB-2 and INB-12: an unnamed conversation and a raw one are both
        // titled with the source app's name. Neither is a title the app
        // invented — it is the only name it has.
        final bool named = !row.isUnnamed && !row.isRaw;
        final String title = named ? row.conversation.title : appLabel;
        // "The app icon alone with no initials" (INB-2, INB-12). Taken from the
        // same condition as the title, because initials taken from a title the
        // row is not drawing are initials for a name nobody can see: a stored
        // title of one zero-width space survives `trim()` and would otherwise
        // put one invisible character in the circle.
        final String initials = named ? row.initials : '';
        final String preview = conversationPreview(l10n, row);
        final String rowLabel = l10n.semanticsConversationRow(
          title,
          appLabel,
          preview,
          time,
        );

        return Semantics(
          container: true,
          button: true,
          // INB-23: the badge is drawn by INB-1 and is part of what the row
          // says, so it is said. It cannot carry its own node — the row
          // excludes its children's semantics below — so the count joins the
          // row's own label instead of being dropped with them.
          label: row.hasUnread
              ? l10n.semanticsConversationRowUnread(
                  rowLabel,
                  l10n.semanticsUnreadCount(row.unreadCount),
                )
              : rowLabel,
          // The row reads as one thing. Its parts each carry their own label
          // for anywhere they are drawn on their own, but a screen reader
          // stepping through a list wants the row, not five nodes.
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              // INB-23's floor on the row itself, which is also what gives
              // INB-6's revealed Delete control its 48dp (it is drawn the full
              // height of the row).
              constraints: const BoxConstraints(minHeight: Metrics.minTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Metrics.gutter,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SourceAppAvatar(identity: identity, initials: initials),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: row.hasUnread
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // A time stays left to right inside a mirrored
                              // row (INB-23, LANG-5).
                              Text(
                                time,
                                // The row mirrors; the clock inside it does
                                // not (INB-23, LANG-5).
                                textDirection: TextDirection.ltr,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          ..._notes(context, l10n, identity),
                          const SizedBox(height: 2),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  preview,
                                  // INB-1: one line, truncated with an
                                  // ellipsis, never wrapped.
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontStyle: _previewIsNotice(row)
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                              ),
                              if (row.hasUnread) ...<Widget>[
                                const SizedBox(width: 8),
                                _UnreadBadge(row: row),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The lines a row carries about itself rather than about its newest message.
  ///
  /// Both are rules that would otherwise be silence: a conversation that
  /// arrived without a name (INB-2) and an app that is no longer installed
  /// (INB-16). Neither is inferred — the second is drawn only for a package the
  /// manifest declares and the package manager answered `gone` for, because for
  /// every other package the app cannot tell and says less rather than guessing.
  List<Widget> _notes(
    BuildContext context,
    AppLocalizations l10n,
    SourceAppIdentity? identity,
  ) {
    final List<String> notes = <String>[
      // INB-12: a raw conversation is titled with the app's name by design, so
      // it is not a conversation whose name went missing and does not carry
      // INB-2's line. The thread says the same, from the same condition
      // (`thread_notice.dart`) — one conversation may not say two things.
      if (row.isUnnamed && !row.isRaw) l10n.conversationUnnamed,
      if (identity?.presence == PackagePresence.gone) l10n.sourceAppGone,
    ];
    if (notes.isEmpty) return const <Widget>[];
    final TextStyle? style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    return <Widget>[
      const SizedBox(height: 2),
      for (final String note in notes)
        Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    ];
  }
}

/// Whether the preview is the app talking about a message rather than the
/// message itself (INB-3, INB-11, INB-12's incompleteness is a thread line, not
/// this one).
bool _previewIsNotice(InboxRow row) {
  final MessageKind? kind = row.newestMessage?.kind;
  // No message at all is the app talking too: the line under the title is
  // `conversationNoMessages` and not something anybody wrote.
  if (kind == null) return true;
  return kind != MessageKind.text && kind != MessageKind.raw;
}

/// The one line INB-1 puts under the title.
///
/// The order of the branches is the order the rules stack: a hidden message is
/// hidden whatever else it is (INB-3), a raw conversation never reads like a
/// chat (INB-12), an attachment is a placeholder and never stored words
/// (INB-11), and only a text message is drawn as text — prefixed with the
/// sender in a group conversation and not in a one-to-one (INB-1).
String conversationPreview(AppLocalizations l10n, InboxRow row) {
  final Message? message = row.newestMessage;
  // The row is here and holds nothing to preview: every message in it is
  // soft-deleted (DEL-1), or `last_message_at` sits past everything stored
  // (`repository.dart` documents that it can). A title, a time and a blank
  // second line is a gap with no name on it, and the app says what it cannot
  // show rather than drawing the gap (product principle 3, INB-1).
  if (message == null) return l10n.conversationNoMessages;

  final String body = switch (message.kind) {
    // Never the system's marker text and never the emptied sender (INB-3).
    MessageKind.hidden => l10n.messageHidden,
    MessageKind.raw => rawPreview(l10n, message),
    MessageKind.image => l10n.messageImage,
    MessageKind.voice => l10n.messageVoice,
    MessageKind.video => l10n.messageVideo,
    MessageKind.file => l10n.messageFile,
    MessageKind.other => l10n.messageOther,
    MessageKind.text => message.text ?? '',
  };

  // INB-12: a raw row's preview is the notification's own title and text, and
  // nothing is prefixed to it — there is no sender to name, only a
  // notification.
  if (message.kind == MessageKind.raw) return body;

  return row.previewNamesSender
      ? l10n.conversationPreviewWithSender(message.sender, body)
      : body;
}

/// INB-12: the notification's title and text joined by the message file's
/// separator — or whichever of the two is non-empty, with no separator drawn.
///
/// Capture keeps the two in separate columns for exactly this: the join is a
/// message-file line, so it is the current language's and not the one that
/// happened to be set the day the notification arrived (LANG-2). The
/// notification's title is in `sender` (CAP-21) because that is the only other
/// column CAP-15 keeps.
String rawPreview(AppLocalizations l10n, Message message) {
  final String title = message.sender;
  final String text = message.text ?? '';
  if (title.isEmpty) return text;
  if (text.isEmpty) return title;
  return l10n.rawPreviewJoin(title, text);
}

/// INB-5's count, drawn only when it is not zero (INB-1).
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.row});

  final InboxRow row;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String locale = Localizations.localeOf(context).toString();
    final String label = row.unreadOverflows
        ? AppLocalizations.of(context).unreadCountOverflow
        : formatUnreadCount(row.unreadCount, locale);
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: ShapeDecoration(
        color: scheme.primary,
        shape: const StadiumBorder(),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          // A number stays left to right inside a mirrored row (INB-23).
          textDirection: TextDirection.ltr,
          // Fixed with the badge, which is a shape and not a paragraph: at 1.3x
          // the digits would push the count off the row's trailing edge.
          textScaler: TextScaler.noScaling,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
