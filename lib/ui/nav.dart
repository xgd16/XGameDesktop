import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native/window_shell.dart';

/// Asks the focused widget to move its own highlight instead of the focus:
/// the menu's rows, the telemetry panel's scroll area. Arrow keys and the
/// pad's stick both go through this, so the two always behave the same.
///
/// Returning true from the action means "handled, do not move the focus".
class FocusDirectionIntent extends Intent {
  const FocusDirectionIntent(this.direction);

  final TraversalDirection direction;
}

/// Whether this machine has a touch screen. Cached: the answer cannot change
/// while the app runs, and the UI asks on every build.
bool get touchScreen => WindowShell.hasTouch;

/// A finger-sized hit box around a small control. The visuals keep their size
/// and only the area that answers a press grows — the same reason Windows'
/// own chrome grows its buttons in tablet mode. A mouse sees exactly what it
/// saw before.
class TouchTarget extends StatelessWidget {
  const TouchTarget({
    super.key,
    required this.child,
    this.minSize = const Size(44, 44),
  });

  final Widget child;
  final Size minSize;

  @override
  Widget build(BuildContext context) {
    if (!touchScreen) return child;
    // Center shrink-wraps the child, so the control keeps its own size while
    // the box around it grows to the minimum.
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minSize.width,
        minHeight: minSize.height,
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
  }
}

/// The pointer's hover highlight, and who is allowed to show it.
///
/// Hover and focus both paint the highlight sheet, so a mouse left resting on
/// one tile while the pad's selection sits on another reads as two selections
/// at once. Rings belong to whoever is steering: the pad, the keyboard and a
/// finger drop the hover when they take the highlight, and the pointer takes
/// it back the moment it actually moves again — a stationary pointer is not
/// asking for anything.
class HoverGate {
  HoverGate._();

  /// Every bump means "let go of the hover now". A counter rather than a bool
  /// because the drop has to happen on each takeover, not once per state.
  static final ValueNotifier<int> drops = ValueNotifier<int>(0);

  static void drop() => drops.value++;
}

/// What a [Tappable] is doing right now, for the builder to style from.
@immutable
class TapState {
  const TapState({
    required this.hovering,
    required this.focused,
    required this.pressing,
  });

  final bool hovering;
  final bool focused;
  final bool pressing;

  /// Either pointer or keyboard/pad is on this control.
  bool get highlighted => hovering || focused;
}

/// The app's one interactive control: tap, right-click, long-press, hover,
/// press, focus, and Enter / pad-A activation.
///
/// Everything clickable used to be a bare GestureDetector, which a keyboard
/// and a pad cannot reach at all. This is the same thing with a focus node and
/// an ActivateIntent action attached, so a mouse, a finger, a keyboard and a
/// controller all land in the same callback.
class Tappable extends StatefulWidget {
  const Tappable({
    super.key,
    required this.builder,
    this.onTap,
    this.onSecondaryTap,
    this.onLongPress,
    this.onFocusChange,
    this.enabled = true,
    this.focusable = true,
    this.autofocus = false,
    this.cursor = SystemMouseCursors.click,
    this.tooltip,
    this.focusNode,
  });

  final Widget Function(BuildContext context, TapState state) builder;

  final VoidCallback? onTap;

  /// A right-click, and — because a finger has no right button — a long press.
  final void Function(Offset globalPosition)? onSecondaryTap;

  /// A long press that means something else than the context menu.
  final void Function(Offset globalPosition)? onLongPress;

  final ValueChanged<bool>? onFocusChange;

  final bool enabled;

  /// False keeps the control out of the keyboard/pad order (window buttons).
  final bool focusable;

  final bool autofocus;
  final MouseCursor cursor;
  final String? tooltip;

  /// Supplied when the caller has to be able to aim the focus by hand — the
  /// app grid keeps one node per tile. Otherwise the control owns its own.
  final FocusNode? focusNode;

  @override
  State<Tappable> createState() => _TappableState();
}

class _TappableState extends State<Tappable> {
  /// Owned when the caller did not bring one, rather than letting
  /// FocusableActionDetector make its own: a touch tap has to be able to move
  /// the focus itself — a finger has no Tab key, and the pad's B needs
  /// something to go back from.
  FocusNode? _owned;

  bool _hovering = false;
  bool _focused = false;
  bool _pressing = false;

  /// The kind of the pointer that went down last. The long-press callbacks do
  /// not carry one, and only a finger should get the long-press meaning — a
  /// mouse already has a right button for that.
  PointerDeviceKind? _downKind;

  FocusNode get _node => widget.focusNode ?? (_owned ??= FocusNode());

  @override
  void initState() {
    super.initState();
    HoverGate.drops.addListener(_dropHover);
  }

  @override
  void dispose() {
    HoverGate.drops.removeListener(_dropHover);
    _owned?.dispose();
    super.dispose();
  }

  /// The pad, the keyboard or a finger took the highlight: the fill the mouse
  /// happened to be resting in goes with it, until the pointer moves again.
  void _dropHover() {
    if (_hovering) setState(() => _hovering = false);
  }

  void _activate() {
    if (widget.enabled) widget.onTap?.call();
  }

  static bool _isFinger(PointerDeviceKind? kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final node = _node;
    final state = TapState(
      hovering: _hovering,
      focused: _focused,
      pressing: _pressing,
    );

    Widget child = MouseRegion(
      cursor: enabled ? widget.cursor : SystemMouseCursors.basic,
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      // Movement is what brings the hover back after [HoverGate] dropped it:
      // onEnter alone would leave a pointer that never left the control —
      // parked exactly where the pad took the highlight from — unlit forever.
      onHover: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) {
          setState(() {
            _hovering = false;
            _pressing = false;
          });
        }
      },
      child: FocusableActionDetector(
        enabled: enabled,
        autofocus: widget.autofocus,
        focusNode: node,
        // Focus, not "focus highlight": whether a ring is drawn is this
        // widget's business, and it has to answer a finger the same way it
        // answers a pad.
        onFocusChange: (value) {
          if (_focused != value) setState(() => _focused = value);
          widget.onFocusChange?.call(value);
        },
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled
              ? (details) {
                  _downKind = details.kind;
                  setState(() => _pressing = true);
                  if (_isFinger(details.kind) && widget.focusable) {
                    node.requestFocus();
                  }
                }
              : null,
          onTapUp:
              enabled ? (_) => setState(() => _pressing = false) : null,
          onTapCancel:
              enabled ? () => setState(() => _pressing = false) : null,
          onTap: enabled ? _activate : null,
          onLongPressStart: enabled && widget.onLongPress != null
              ? (details) {
                  // The kind is checked when it fires, not when the callback is
                  // installed: the recognizer has to be in the arena from the
                  // pointer's first frame or the very first long press is lost.
                  if (_isFinger(_downKind)) {
                    widget.onLongPress!(details.globalPosition);
                  }
                }
              : null,
          onSecondaryTapUp: enabled && widget.onSecondaryTap != null
              ? (details) => widget.onSecondaryTap!(details.globalPosition)
              : null,
          child: widget.builder(context, state),
        ),
      ),
    );

    if (!widget.focusable) {
      // Excluded rather than merely skipped: a control the pad must not land
      // on (the window buttons) may still take a mouse click.
      child = ExcludeFocus(child: child);
    }
    if (widget.tooltip case final tooltip?) {
      child = Tooltip(message: tooltip, child: child);
    }
    return child;
  }
}

/// Brings [context]'s box into view inside whatever scrollable holds it.
/// Traversal does this on its own; this is for focus the app moves by hand.
void revealFocus(BuildContext context) {
  Scrollable.ensureVisible(
    context,
    alignment: 0.5,
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
  );
}
