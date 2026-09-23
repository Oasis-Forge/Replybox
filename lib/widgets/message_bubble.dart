import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/initials.dart';
import '../models/message.dart';
import 'date_separator.dart';

/// One message in a thread (INB-3, INB-9, INB-11, INB-12, INB-17).
///
/// Everything this draws is capture-side. **No element states or implies that a
/// message was delivered, seen or read by anyone else** (INB-17): there is no
/// tick, no "delivered", no read receipt and no place to put one, because the
/// app holds no receipt from the source app to show. The only state drawn is
/// the send state of a message *this* app has composed (INB-9), which is a fact
/// about this phone and not about the other person.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    required this.showsSender,
    super.key,
  });

  final Message message;

  /// INB-8: an inbound message shows its sender's name in a group conversation
  /// and not in a one-to-one. The provider decides it; an outbound message and
  /// one whose direction could not be decided never show one (INB-9).
  final bool showsSender;

  @override
  Widget build(BuildContext context) {
    // INB-12: a raw message is a full-width note with its arrival time, never
    // a bubble attributed to a sender.
    if (message.kind == MessageKind.raw) {
      return _RawNote(message: message);
    }

    final ThemeData theme = Theme.of(context);

    // LANG-5: `AlignmentDirectional` rather than left/right, so the side an
    // outbound message sits on mirrors with the language and nothing here has
    // to know which way round it is (INB-9, INB-23).
    final AlignmentDirectional alignment = switch (message.direction) {
      Direction.outbound => AlignmentDirectional.centerEnd,
      Direction.inbound => AlignmentDirectional.centerStart,
      // INB-9's third direction: the notification's history did not say who
      // wrote this line, so it is drawn with no side and no sender rather than
      // guessed into one.
      Direction.unknown => AlignmentDirectional.center,
    };

    final bool outbound = message.direction == Direction.outbound;
    final Color background = outbound
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final Color foreground = outbound
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: MergeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              // INB-9 says an outbound message carries no initials circle. The
              // circle it is contrasted with is this one, and it is drawn only
              // beside a message that names a sender — a group conversation's
              // inbound lines (INB-8). Decorative: the name is written beside
              // it, so reading the letters out again would say it twice.
              if (showsSender) ...<Widget>[
                ExcludeSemantics(child: _SenderAvatar(name: message.sender)),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (showsSender)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              message.sender,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        // The body and the stamp share a line, and the bubble
                        // is as wide as the two of them need. A stamp aligned
                        // to the end of a `Column` instead would stretch every
                        // bubble to the maximum width, because an `Align`
                        // fills the bounded constraint it is handed.
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            Flexible(
                              child: _Body(
                                message: message,
                                foreground: foreground,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Stamp(message: message, foreground: foreground),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Exposed for the thread's own use: nothing outside this file should have to
  /// know which kinds carry words and which carry a line from the message
  /// files.
  static String bodyText(AppLocalizations l10n, Message message) =>
      switch (message.kind) {
        // INB-11: a message whose kind is not text renders as a placeholder
        // from the message files and never as stored words (CAP-9, LANG-2).
        MessageKind.image => l10n.messageImage,
        MessageKind.voice => l10n.messageVoice,
        MessageKind.video => l10n.messageVideo,
        MessageKind.file => l10n.messageFile,
        MessageKind.other => l10n.messageOther,
        // INB-3: the phone hid this message's contents. Never the system's
        // marker text and never the emptied sender (CAP-8).
        MessageKind.hidden => l10n.messageHidden,
        MessageKind.text || MessageKind.raw => message.text ?? '',
      };
}

/// The body line, and the icon that says which kind of thing arrived.
///
/// INB-11: the placeholder carries no size, no duration, no filename and no
/// thumbnail — CAP-15 keeps none of them, so there is nothing to draw even if
/// the layout had room for it.
class _Body extends StatelessWidget {
  const _Body({required this.message, required this.foreground});

  final Message message;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool placeholder = message.kind != MessageKind.text;

    // INB-9: while `pending` the text draws at the theme's disabled-text
    // colour, and it is never drawn as sent.
    final bool pending = message.sendState == SendState.pending;
    final Color colour = pending
        ? theme.disabledColor
        : (placeholder ? theme.colorScheme.onSurfaceVariant : foreground);

    final TextStyle? style = theme.textTheme.bodyMedium?.copyWith(
      color: colour,
      fontStyle: placeholder ? FontStyle.italic : FontStyle.normal,
    );

    final IconData? icon = _icon(message.kind);
    final Text text = Text(MessageBubble.bodyText(l10n, message), style: style);
    if (icon == null) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 2, end: 6),
          child: Icon(icon, size: 16, color: colour),
        ),
        Flexible(child: text),
      ],
    );
  }

  static IconData? _icon(MessageKind kind) => switch (kind) {
    MessageKind.image => Icons.photo_outlined,
    MessageKind.voice => Icons.mic_none_outlined,
    MessageKind.video => Icons.videocam_outlined,
    MessageKind.file => Icons.insert_drive_file_outlined,
    MessageKind.other => Icons.help_outline,
    MessageKind.hidden => Icons.visibility_off_outlined,
    MessageKind.text || MessageKind.raw => null,
  };
}

/// The message's own arrival time, or what stands in its place (INB-8, INB-9).
class _Stamp extends StatelessWidget {
  const _Stamp({required this.message, required this.foreground});

  final Message message;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // INB-9: while `pending` a clock glyph stands **in place of** the time.
    // Drawing a time would be drawing the moment the user pressed send as
    // though the message had arrived somewhere.
    if (message.sendState == SendState.pending) {
      return Icon(
        Icons.schedule_outlined,
        size: 12,
        color: theme.disabledColor,
      );
    }

    final bool failed = message.sendState == SendState.failed;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (failed)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: Icon(
              Icons.error_outline,
              size: 12,
              color: theme.colorScheme.error,
            ),
          ),
        Text(
          // INB-3: a hidden message carries the notification's post time as its
          // arrival time, which is already what `sentAt` holds for it (CAP-8) —
          // so the list and the thread never print two times for one message.
          threadMessageTime(context, message.sentAt),
          style: theme.textTheme.labelSmall?.copyWith(
            color: failed
                ? theme.colorScheme.error
                : foreground.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

/// INB-8's sender circle: up to two initials from the sender's first two words.
///
/// The initials come from the shared `initialsOf` (`models/initials.dart`), the
/// same one INB-1's leading circle uses. This used to be a private copy of it,
/// on the argument that reaching into the *list's* row object for a string
/// function would tie the thread to the list — a fair objection to the old
/// home, and no argument at all for a second implementation. The copy outlived
/// its original: the 23 September 2026 drill's correction (the first *letter*,
/// so a phone number contributes no initials instead of `(1`) landed on
/// `InboxRow` alone, and this circle went on drawing `(1` one screen deeper.
/// The rule now sits in `models/`, which a provider and a widget may both
/// import, so neither surface has to own it.
class _SenderAvatar extends StatelessWidget {
  const _SenderAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        initialsOf(name),
        // Not scaled with the text scale, for the same reason INB-1's leading
        // circle is not (`source_app.dart`): the circle is a fixed 28dp shape
        // and two initials at 1.3x would spill out of a box that cannot grow
        // (INB-23).
        textScaler: TextScaler.noScaling,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// INB-12: a raw message is a full-width note with its arrival time, under the
/// standing line the notice already drew — never a bubble attributed to a
/// sender, so nobody concludes the app lost the words.
///
/// The notification's title is in `sender` and its text in `text`, kept apart
/// at capture so no join is baked into stored data (CAP-21, LANG-2). Here they
/// are two lines rather than INB-12's ` — ` join, which is the *list's* one-line
/// preview; a note has room to draw them as the notification drew them, and
/// whichever of the two is empty is simply not drawn.
class _RawNote extends StatelessWidget {
  const _RawNote({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String title = message.sender;
    final String text = message.text ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: MergeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (title.isNotEmpty)
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (text.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: title.isEmpty ? 0 : 2),
                  child: Text(text, style: theme.textTheme.bodyMedium),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  threadMessageTime(context, message.sentAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
