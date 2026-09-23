import 'package:flutter/material.dart';

/// INB-6's swipe: it **reveals** one control, it does not perform one.
///
/// A `Dismissible` was the obvious reach and is the wrong shape. It acts when
/// the swipe passes a threshold, which makes the gesture itself the delete —
/// so a half-intended swipe destroys a conversation, and INB-18's count of
/// "clearing takes one tap" becomes a count of zero taps and one accident. The
/// rule says a swipe reveals a control at least 48dp on its shorter side and
/// the tap on that control is what deletes, with no confirmation and about five
/// seconds of Undo. So: the child slides, the control sits behind it, and
/// nothing happens until the control is tapped.
///
/// The direction mirrors with the language (INB-23, LANG-5): the child slides
/// towards the leading edge in a left-to-right language and towards the
/// trailing edge in a right-to-left one, and the control is revealed at the
/// trailing edge either way.
class SwipeToReveal extends StatefulWidget {
  const SwipeToReveal({
    required this.child,
    required this.action,
    required this.extent,
    required this.isOpen,
    required this.onOpenChanged,
    super.key,
  });

  final Widget child;

  /// The one control the swipe reveals, drawn the full height of the row and
  /// [extent] wide. INB-6: one control and nothing else.
  final Widget action;

  final double extent;

  /// Held by the list, not by this widget, so opening one row closes every
  /// other. Two open rows would put two Delete controls on screen at once,
  /// which is the state INB-6's "one control and nothing else" rules out.
  final bool isOpen;

  final ValueChanged<bool> onOpenChanged;

  @override
  State<SwipeToReveal> createState() => _SwipeToRevealState();
}

class _SwipeToRevealState extends State<SwipeToReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.isOpen ? 1 : 0,
  );

  @override
  void didUpdateWidget(SwipeToReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen != oldWidget.isOpen) {
      if (widget.isOpen) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Which way a drag has to go to open, in this language (LANG-5).
  double _sign(BuildContext context) =>
      Directionality.of(context) == TextDirection.rtl ? 1 : -1;

  void _onDragUpdate(DragUpdateDetails details) {
    _controller.value =
        (_controller.value +
                _sign(context) * details.primaryDelta! / widget.extent)
            .clamp(0, 1);
  }

  void _onDragEnd(DragEndDetails details) {
    // A flick decides on its own, whichever side of half it ended on: a fast
    // short swipe is a deliberate one, and making it fail because it stopped at
    // 40% is how a control becomes hard to reach.
    final double velocity =
        details.primaryVelocity! * _sign(context) / widget.extent;
    final bool open = velocity.abs() > 1
        ? velocity > 0
        : _controller.value > 0.5;
    if (open != widget.isOpen) {
      widget.onOpenChanged(open);
    } else if (open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double sign = _sign(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: Stack(
        children: <Widget>[
          // Sized to the child, so the control is exactly as tall as the row
          // and never a fixed height that stops matching it at 1.3x text
          // (INB-23).
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) =>
                  _controller.value == 0
                  // Nothing behind a closed row: a Delete control that is
                  // always there, merely covered, is one a screen reader finds
                  // on every row of the list.
                  ? const SizedBox.shrink()
                  : child!,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: SizedBox(width: widget.extent, child: widget.action),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) =>
                Transform.translate(
                  offset: Offset(sign * _controller.value * widget.extent, 0),
                  child: child,
                ),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
