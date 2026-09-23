import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/inbox_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import 'source_app.dart';

/// INB-14's chip row: `All` pinned at the leading edge and one chip per source
/// app with at least one conversation the list can show.
///
/// Membership and order are [InboxProvider]'s (newest message descending, then
/// package ascending), including the two exceptions that keep a chip in the row
/// after its app's last conversation goes — a selected chip, and one whose last
/// conversation is inside a pending Undo. This draws what it is given.
///
/// `All` is pinned here rather than in the provider because it is not a chip
/// about an app: it is selected exactly when no app chip is, which is a fact
/// about the filter and not a row in a list.
class AppFilterChips extends StatelessWidget {
  const AppFilterChips({
    required this.chips,
    required this.filterIsEmpty,
    required this.onToggle,
    required this.onClear,
    super.key,
  });

  final List<InboxChip> chips;

  /// `All` is selected exactly when no app chip is (INB-14).
  final bool filterIsEmpty;

  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (chips.isEmpty) return const SizedBox.shrink();

    // No fixed height. A chip is a box around a word, and at the 1.3x text
    // scale INB-23 renders at, a row pinned to 56dp is a row the chips have
    // outgrown — which is an overflow, and INB-23 counts an overflow as a
    // failure. A horizontally scrolling `ListView` needs a bounded height, so
    // this scrolls a `Row` instead and takes its height from the chips: the
    // whole row is one chip per app and is built in one pass either way.
    // Full width, and that is what pins `All` (INB-14, INB-23).
    //
    // A horizontal `SingleChildScrollView` sizes itself to its content, so with
    // three chips in it the whole scroll view was 452 of the phone's 1080
    // pixels wide — and the `Column` it sits in centres what it is given. The
    // device drill of 23 September 2026 measured the row dead centre with equal
    // gaps either side, which is a row with nothing to mirror: INB-23 asks the
    // leading `All` to move to the other edge in a right-to-left language, and
    // a centred row looks the same in both. Given the whole width the viewport
    // lays its content out from its own leading edge instead, which is the
    // left in a left-to-right language and the right in a right-to-left one,
    // and it still scrolls the moment the chips outgrow it.
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        // It starts at the leading edge — which is the right-hand edge in a
        // right-to-left language, so `All` is pinned where the language puts
        // "first" (INB-23, LANG-5).
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Metrics.gutter,
          vertical: 4,
        ),
        child: Row(
          children: <Widget>[
            FilterChip(
              // INB-23's semantic label, on the node the chip actually builds.
              // See `_AppChip` below for why it is annotated here and not
              // around the whole chip.
              label: Semantics(
                label: l10n.semanticsFilterChipAll,
                excludeSemantics: true,
                child: Text(l10n.filterAll),
              ),
              selected: filterIsEmpty,
              // Tapping `All` while it is already selected is not a way to
              // deselect every app: there is no state with no chip selected.
              onSelected: filterIsEmpty ? (bool _) {} : (bool _) => onClear(),
            ),
            for (final InboxChip chip in chips) ...<Widget>[
              const SizedBox(width: 8),
              _AppChip(chip: chip, onToggle: onToggle),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppChip extends StatelessWidget {
  const _AppChip({required this.chip, required this.onToggle});

  final InboxChip chip;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return SourceAppFace(
      package: chip.package,
      builder: (BuildContext context, SourceAppIdentity? identity) {
        final String label = sourceAppLabel(
          package: chip.package,
          identity: identity,
          app: chip.app,
        );
        return FilterChip(
          avatar: SourceAppIconImage(identity: identity, size: 18),
          // INB-23 asks each chip for "a semantic label from the message
          // files", and `FilterChip.tooltip` is not one: it wraps the chip in a
          // `Tooltip`, which changes nothing a screen reader announces — that
          // stays the visible label — and adds a long-press popup nothing asked
          // for. So the line is annotated where the chip's own node is built,
          // in place of the visible text. Not around the whole chip: the chip
          // is a semantic boundary that carries the tap action and `selected`,
          // and an `excludeSemantics` above it would take a reader's way of
          // activating the chip with it.
          label: Semantics(
            label: AppLocalizations.of(context).semanticsFilterChip(label),
            excludeSemantics: true,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          selected: chip.selected,
          // Multi-select: this toggles one package and leaves the rest of the
          // selection alone (INB-14).
          onSelected: (bool _) => onToggle(chip.package),
        );
      },
    );
  }
}
