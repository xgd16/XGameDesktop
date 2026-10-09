import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../core/typography.dart';
import 'nav.dart';
import 'widgets.dart';

/// Key on the panel root, so tests can measure exactly where the menu landed.
const contextMenuKey = Key('ContextMenuPanel');

/// One row of a [showContextMenu] menu.
sealed class ContextMenuEntry {
  const ContextMenuEntry();
}

/// An actionable row: leading icon, label, optional right-aligned hint.
class ContextMenuAction extends ContextMenuEntry {
  const ContextMenuAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
    this.shortcut,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  /// Destructive actions read in the danger color.
  final bool danger;

  /// Right-aligned hint, set in the telemetry face.
  final String? shortcut;
}

/// Hairline separating groups of actions.
class ContextMenuDivider extends ContextMenuEntry {
  const ContextMenuDivider();
}

/// Opens [entries] as a floating menu for a pointer click at [position]
/// (a global coordinate — what `TapUpDetails.globalPosition` hands you).
///
/// The panel's corner nearest the pointer is pinned to [position]: it grows
/// down-right from the cursor, and flips up/left when it would leave the
/// window, the way a native menu does. Nothing is drawn over the cursor's own
/// pixel until the flip, so the menu always reads as attached to the click.
///
/// The returned future completes once the menu has closed.
Future<void> showContextMenu(
  BuildContext context, {
  required Offset position,
  required List<ContextMenuEntry> entries,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ContextMenuLayer(
      anchor: position,
      entries: entries,
      onClosed: () {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

const _menuWidth = 208.0;
const _panelPadding = 5.0;
const _windowMargin = 8.0;

/// A row is 34 px under a mouse and a finger-sized 44 on a touch screen.
double get _rowHeight => touchScreen ? 44 : 34;

class _ContextMenuLayer extends StatefulWidget {
  const _ContextMenuLayer({
    required this.anchor,
    required this.entries,
    required this.onClosed,
  });

  final Offset anchor;
  final List<ContextMenuEntry> entries;
  final VoidCallback onClosed;

  @override
  State<_ContextMenuLayer> createState() => _ContextMenuLayerState();
}

class _ContextMenuLayerState extends State<_ContextMenuLayer>
    with SingleTickerProviderStateMixin {
  static const _enterDuration = Duration(milliseconds: 140);
  static const _exitDuration = Duration(milliseconds: 90);

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _enterDuration);
  final _panelKey = GlobalKey();

  /// The menu takes the keyboard while it is open: arrow keys walk the rows,
  /// Enter runs one, Esc closes.
  final _focusNode = FocusNode(debugLabel: 'ContextMenu');

  /// Panel top-left, once measured. Null only for the first (invisible) frame.
  Offset? _origin;
  Alignment _scaleOrigin = Alignment.topLeft;
  Size? _window;
  bool _closing = false;

  /// Index into [widget.entries] highlighted by the keyboard, if any.
  int? _active;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = MediaQuery.sizeOf(context);
    if (_window == null) {
      _window = window;
    } else if (_window != window) {
      // The panel is pinned in window coordinates; a resize would leave it
      // floating away from its anchor. Native menus close instead.
      _window = window;
      _dismiss();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Positions the panel from its own measured size — it must be laid out once
  /// before the flip and the scale origin can be decided.
  void _measure() {
    if (!mounted || _origin != null) return;
    if (_focusNode.canRequestFocus) _focusNode.requestFocus();
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final window = MediaQuery.sizeOf(context);
    final origin = _place(widget.anchor, size, window);
    setState(() {
      _origin = origin;
      // Scale about the corner closest to the cursor: the menu grows out of
      // the click instead of appearing at it.
      _scaleOrigin = Alignment(
        ((widget.anchor.dx - origin.dx) / size.width).clamp(0.0, 1.0) * 2 - 1,
        ((widget.anchor.dy - origin.dy) / size.height).clamp(0.0, 1.0) * 2 - 1,
      );
    });
    _controller.forward();
  }

  static Offset _place(Offset anchor, Size menu, Size window) {
    var x = anchor.dx;
    var y = anchor.dy;
    if (x + menu.width + _windowMargin > window.width) x = anchor.dx - menu.width;
    if (y + menu.height + _windowMargin > window.height) y = anchor.dy - menu.height;
    x = x.clamp(_windowMargin, math.max(_windowMargin, window.width - menu.width - _windowMargin));
    y = y.clamp(_windowMargin, math.max(_windowMargin, window.height - menu.height - _windowMargin));
    return Offset(x, y);
  }

  void _dismiss() {
    if (_closing) return;
    setState(() => _closing = true);
    _controller.duration = _exitDuration;
    _controller.reverse().whenComplete(() {
      if (mounted) widget.onClosed();
    });
  }

  void _activate(ContextMenuAction action) {
    if (_closing || !action.enabled) return;
    action.onTap();
    _dismiss();
  }

  List<int> get _actionable => [
        for (var i = 0; i < widget.entries.length; i++)
          if (widget.entries[i] case ContextMenuAction(enabled: true)) i,
      ];

  int? _step(int delta) {
    final all = _actionable;
    if (all.isEmpty) return null;
    final current = _active;
    if (current == null) return delta > 0 ? all.first : all.last;
    final at = all.indexOf(current);
    if (at < 0) return all.first;
    return all[(at + delta) % all.length];
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _active = _step(1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _active = _step(-1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      final all = _actionable;
      if (all.isEmpty) return KeyEventResult.ignored;
      _activate(widget.entries[_active ?? all.first] as ContextMenuAction);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The same walk the arrow keys do, for the pad. The menu is one column, so
  /// left and right mean nothing — they are still eaten, or the focus would
  /// wander off to whatever is behind the menu.
  Object? _onDirection(FocusDirectionIntent intent) {
    switch (intent.direction) {
      case TraversalDirection.up:
        setState(() => _active = _step(-1));
      case TraversalDirection.down:
        setState(() => _active = _step(1));
      case TraversalDirection.left:
      case TraversalDirection.right:
        break;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final window = MediaQuery.sizeOf(context);
    final maxHeight = math.max(_rowHeight + 2 * _panelPadding,
        window.height - 2 * _windowMargin);

    final panel = ConstrainedBox(
      // Measured through this key: the panel's own size decides the flip and
      // the corner the entrance grows from.
      key: _panelKey,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Actions(
        // Outside the Focus on purpose: intents are looked up from the focused
        // node's context upwards.
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _dismiss();
              return true;
            },
          ),
          FocusDirectionIntent: CallbackAction<FocusDirectionIntent>(
            onInvoke: _onDirection,
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: _buildPanel(c),
        ),
      ),
    );

    final origin = _origin;
    return Stack(
      children: [
        Positioned.fill(child: _barrier()),
        if (origin == null)
          // Measured once, invisible: the panel is laid out off-screen so the
          // first painted frame already sits at its final place.
          Positioned(
            left: -10000,
            top: -10000,
            child: IgnorePointer(
              child: Opacity(opacity: 0, child: panel),
            ),
          )
        else
          Positioned(
            left: origin.dx,
            top: origin.dy,
            child: IgnorePointer(
              ignoring: _closing,
              child: FadeTransition(
                opacity: _controller,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(
                      CurvedAnimation(parent: _controller, curve: Motion.outCubic)),
                  alignment: _scaleOrigin,
                  child: panel,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Full-window catcher: any press outside the menu closes it, the wheel
  /// closes it rather than scrolling the grid underneath.
  Widget _barrier() {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) _dismiss();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _dismiss(),
          onSecondaryTapDown: (_) => _dismiss(),
        ),
      ),
    );
  }

  Widget _buildPanel(AppColors c) {
    // A whisper of the palette's accent over the raised surface: the menu sits
    // in the same light as the rest of the app instead of reading as a stock
    // gray popup. Thinned for the frost, so the menu reads as a sheet of glass
    // floating over the wallpaper rather than a solid card on top of it.
    final panelColor = Color.alphaBlend(
            c.accent.withValues(alpha: 0.05), c.surfaceHover)
        .withValues(alpha: 0.58);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        // The drop shadow is painted outside the frost's clip — inside it, the
        // rounded corners would cut the shadow off at the panel's own edge.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.50),
              blurRadius: 28,
              spreadRadius: -6,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Frosted(
          radius: 12,
          blur: 22,
          child: Container(
            key: contextMenuKey,
            width: _menuWidth,
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.borderStrong),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: _panelPadding, vertical: _panelPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.entries.length; i++)
                    switch (widget.entries[i]) {
                      ContextMenuDivider() => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Container(height: 1, color: c.border),
                        ),
                      ContextMenuAction action => _MenuRow(
                          key: ValueKey(i),
                          action: action,
                          active: i == _active,
                          onActivate: _activate,
                        ),
                    },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    super.key,
    required this.action,
    required this.active,
    required this.onActivate,
  });

  final ContextMenuAction action;
  final bool active;
  final void Function(ContextMenuAction) onActivate;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovering = false;
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final action = widget.action;
    final tint = action.danger ? c.danger : c.accent;
    final highlighted = action.enabled && (widget.active || _hovering);

    final Color label;
    if (!action.enabled) {
      label = c.textMuted;
    } else if (action.danger) {
      label = c.danger;
    } else {
      label = c.textPrimary;
    }

    return MouseRegion(
      cursor: action.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() {
        _hovering = false;
        _pressing = false;
      }),
      child: GestureDetector(
        onTapDown: action.enabled ? (_) => setState(() => _pressing = true) : null,
        onTapUp: action.enabled ? (_) => setState(() => _pressing = false) : null,
        onTapCancel: action.enabled ? () => setState(() => _pressing = false) : null,
        onTap: action.enabled ? () => widget.onActivate(action) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Motion.outCubic,
          height: _rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: !action.enabled
                ? Colors.transparent
                : _pressing
                    ? tint.withValues(alpha: 0.22)
                    : highlighted
                        ? tint.withValues(alpha: 0.13)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                action.icon,
                size: 15,
                color: !action.enabled
                    ? c.textMuted
                    : action.danger
                        ? c.danger
                        : highlighted
                            ? c.accent
                            : c.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: label),
                ),
              ),
              if (action.shortcut case final shortcut?)
                Text(shortcut,
                    style: TelemetryText.number(11, c.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
