import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import 'nav.dart';
import 'widgets.dart';

/// The soft keyboard, and the reason search works from a couch: a finger or a
/// pad can reach every letter, a mouse never needs it.
///
/// It floats over the lower half of the app grid — the results stay visible
/// above it — and it takes the keyboard focus while it is up, so A types,
/// B closes, and the arrows walk the keys. It is the app's only text entry
/// that is not a physical keyboard, so it is styled like everything else
/// rather than like a system IME.
class SoftKeyboard extends StatefulWidget {
  const SoftKeyboard({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClose,
    this.onExitUp,
  });

  final TextEditingController controller;

  /// Called with the new text after every key.
  final ValueChanged<String> onChanged;

  final VoidCallback onClose;

  /// Called when the pad walks off the top row: the search field is the only
  /// thing above the keys, so that is where the highlight goes.
  final VoidCallback? onExitUp;

  @override
  State<SoftKeyboard> createState() => SoftKeyboardState();
}

class SoftKeyboardState extends State<SoftKeyboard> {
  static const _rows = <List<String>>[
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
    ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
  ];

  /// The bottom row, in [_rows]'s shadow: space, backspace, clear, hide.
  static const _bottom = <String>['空格', '退格', '清空', '收起'];

  /// One node per key, in the layout's own shape. The pad's highlight is
  /// walked here by hand rather than by the framework's directional
  /// traversal: that one consults every focusable node in the window — the
  /// telemetry column included — and remembers the moves it made, so a
  /// reversal can hand the highlight back to the search field instead of the
  /// next key.
  late final List<List<FocusNode>> _keys = [
    for (final row in _rows)
      [for (final key in row) FocusNode(debugLabel: 'kb$key')],
    [for (final key in _bottom) FocusNode(debugLabel: 'kb$key')],
  ];

  /// True while the pad's highlight sits on a key.
  bool get hasFocus => _position != null;

  /// Puts the highlight on the first key — the way into the keyboard.
  void focusFirstKey() => _keys.first.first.requestFocus();

  (int, int)? get _position {
    for (var row = 0; row < _keys.length; row++) {
      final keys = _keys[row];
      for (var column = 0; column < keys.length; column++) {
        if (keys[column].hasFocus) return (row, column);
      }
    }
    return null;
  }

  /// Walks the highlight one key in [direction]. The left, right and bottom
  /// edges hold; the top edge hands the highlight back to the search field.
  void move(TraversalDirection direction) {
    final at = _position;
    if (at == null) {
      focusFirstKey();
      return;
    }
    var (row, column) = at;
    switch (direction) {
      case TraversalDirection.up:
        if (row == 0) {
          widget.onExitUp?.call();
          return;
        }
        row -= 1;
      case TraversalDirection.down:
        row = math.min(row + 1, _keys.length - 1);
      case TraversalDirection.left:
        column = math.max(column - 1, 0);
      case TraversalDirection.right:
        column = math.min(column + 1, _keys[row].length - 1);
    }
    // The rows are not all the same length, so the column is clamped to the
    // one nearest the key the move came from.
    final target = _keys[row][math.min(column, _keys[row].length - 1)];
    if (!identical(target, FocusManager.instance.primaryFocus)) {
      target.requestFocus();
    }
  }

  @override
  void dispose() {
    for (final row in _keys) {
      for (final node in row) {
        node.dispose();
      }
    }
    super.dispose();
  }

  void _type(String text) {
    widget.controller.text += text;
    widget.controller.selection =
        TextSelection.collapsed(offset: widget.controller.text.length);
    widget.onChanged(widget.controller.text);
  }

  void _backspace() {
    final text = widget.controller.text;
    if (text.isEmpty) return;
    widget.controller.text = text.substring(0, text.length - 1);
    widget.controller.selection =
        TextSelection.collapsed(offset: widget.controller.text.length);
    widget.onChanged(widget.controller.text);
  }

  void _clear() {
    if (widget.controller.text.isEmpty) return;
    widget.controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // B closes the keyboard before it means anything else: the pad's back
    // button is the one thing that has to work while typing. Directions are
    // the keyboard's own business too — see [move].
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            widget.onClose();
            return true;
          },
        ),
        FocusDirectionIntent: CallbackAction<FocusDirectionIntent>(
          onInvoke: (intent) {
            move(intent.direction);
            return true;
          },
        ),
      },
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 492),
          child: Frosted(
            radius: 16,
            blur: 20,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
              decoration: BoxDecoration(
                color: c.frost,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.borderStrong),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var r = 0; r < _rows.length; r++)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _rows[r].length; i++)
                          _Key(
                            label: _rows[r][i],
                            width: 40,
                            focusNode: _keys[r][i],
                            onTap: () => _type(_rows[r][i].toLowerCase()),
                          ),
                      ],
                    ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Key(
                        label: '空格',
                        width: 148,
                        focusNode: _keys.last[0],
                        onTap: () => _type(' '),
                      ),
                      _Key(
                        icon: Icons.backspace_outlined,
                        width: 96,
                        focusNode: _keys.last[1],
                        onTap: _backspace,
                      ),
                      _Key(
                        icon: Icons.clear_all_rounded,
                        width: 96,
                        focusNode: _keys.last[2],
                        onTap: _clear,
                      ),
                      _Key(
                        icon: Icons.keyboard_hide_outlined,
                        width: 96,
                        focusNode: _keys.last[3],
                        onTap: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '手柄：A 输入 · B 收起 · 方向键移动 　 触屏：直接点按',
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.onTap,
    required this.focusNode,
    this.label,
    this.icon,
    this.width = 40,
  });

  final VoidCallback onTap;
  final FocusNode focusNode;
  final String? label;
  final IconData? icon;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tappable(
      onTap: onTap,
      focusNode: focusNode,
      builder: (context, state) => AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.outCubic,
        width: width,
        height: 40,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: state.pressing
              ? c.accent.withValues(alpha: 0.25)
              : state.highlighted
                  ? c.surfaceHover
                  : c.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: state.focused ? c.accent : c.border),
        ),
        alignment: Alignment.center,
        child: icon != null
            ? Icon(icon,
                size: 16,
                color: state.highlighted ? c.textPrimary : c.textSecondary)
            : Text(
                label!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: state.highlighted ? c.textPrimary : c.textSecondary,
                ),
              ),
      ),
    );
  }
}
