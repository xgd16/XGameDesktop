import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../native/shell_apps.dart';
import '../state/apps_provider.dart';
import 'context_menu.dart';
import 'nav.dart';
import 'widgets.dart';

const _tileRadius = 14.0;

/// The per-app context menu, shared by the card's right-click / long-press and
/// the pad's Start button (which aims at the focused card's center).
void showAppMenu(BuildContext context, AppEntry app, Offset position) {
  final apps = context.read<AppsProvider>();
  final pinned = apps.isPinned(app);
  showContextMenu(
    context,
    position: position,
    entries: [
      ContextMenuAction(
        label: '打开',
        icon: Icons.play_arrow_rounded,
        onTap: () {
          if (!apps.launch(app)) appToast(context, '无法启动 ${app.name}');
        },
      ),
      ContextMenuAction(
        label: pinned ? '取消固定' : '固定到首页',
        icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
        onTap: () => pinned ? apps.unpin(app) : apps.pin(app),
      ),
      if (pinned) ...[
        ContextMenuAction(
          label: '上移',
          icon: Icons.keyboard_arrow_up_rounded,
          onTap: () => apps.movePin(app, -1),
        ),
        ContextMenuAction(
          label: '下移',
          icon: Icons.keyboard_arrow_down_rounded,
          onTap: () => apps.movePin(app, 1),
        ),
      ],
      // A Steam game's path is a steam:// URL — there is no file to locate
      // and nothing sensible to copy.
      if (!app.isGame) ...[
        const ContextMenuDivider(),
        ContextMenuAction(
          label: '打开文件位置',
          icon: Icons.folder_open_rounded,
          onTap: () {
            if (!apps.openLocation(app)) appToast(context, '无法打开文件位置');
          },
        ),
        ContextMenuAction(
          label: '复制路径',
          icon: Icons.content_copy_rounded,
          onTap: () {
            Clipboard.setData(ClipboardData(text: app.path));
            appToast(context, '已复制路径');
          },
        ),
      ],
    ],
  );
}

/// The card's little feedback line — shared with the game tiles, which launch
/// through the same provider and fail the same way.
void appToast(BuildContext context, String message) {
  final c = AppColors.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1400),
      backgroundColor: c.surfaceHover,
      content: Text(message, style: TextStyle(color: c.textPrimary)),
    ),
  );
}

/// A quiet launcher tile: transparent at rest, gains a subtle surface fill
/// and an accent hairline when the pointer is on it or the pad's highlight
/// has reached it, and presses down when clicked.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.app, this.enterDelay, this.focusNode});

  final AppEntry app;

  /// The grid's node for this slot; the pane aims the pad's highlight with it.
  final FocusNode? focusNode;

  /// Staggered delay for the grid's boot-up wave. Null once that wave is over
  /// (or for tiles built later by scrolling) — the card is then at rest from
  /// its first frame instead of replaying the fade.
  final Duration? enterDelay;

  void _launch(BuildContext context) {
    final apps = context.read<AppsProvider>();
    if (!apps.launch(app)) appToast(context, '无法启动 ${app.name}');
  }

  void _showMenu(BuildContext context, Offset position) {
    showAppMenu(context, app, position);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final pinned = context.watch<AppsProvider>().isPinned(app);

    return Entrance(
      delay: enterDelay ?? Duration.zero,
      animate: enterDelay != null,
      child: Tappable(
        focusNode: focusNode,
        onTap: () => _launch(context),
        onSecondaryTap: (position) => _showMenu(context, position),
        // A finger has no right button: holding the tile is how it asks for
        // the same menu. The mouse keeps its right-click and nothing else.
        onLongPress: (position) => _showMenu(context, position),
        builder: (context, state) => AnimatedScale(
          scale: state.pressing ? 0.96 : (state.hovering ? 1.05 : 1.0),
          duration: Motion.fast,
          curve: Motion.outCubic,
          child: Stack(
            children: [
              // The highlight pane: the wallpaper keeps showing through the
              // tile, instead of being covered by an opaque chip. One value
              // drives the fade and the fill, so the sheet arrives as a single
              // thing; at rest none of it is in the tree, because a backdrop
              // read per tile is real work every frame. The blur joins only
              // where it is the point — the pad or the keyboard sitting on the
              // tile — and the mouse gets the fill alone, however long it
              // rests there.
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: state.highlighted ? 1 : 0),
                    duration: Motion.base,
                    curve: Motion.outCubic,
                    builder: (context, t, _) {
                      if (t < 0.02) return const SizedBox.shrink();
                      return Frosted(
                        radius: _tileRadius,
                        blur: state.focused ? 16 * t : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.frost.withValues(alpha: c.frost.a * t),
                            borderRadius: BorderRadius.circular(_tileRadius),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              AnimatedContainer(
                duration: Motion.base,
                curve: Motion.outCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_tileRadius),
                  border: Border.all(
                    color: state.highlighted ? c.accent : Colors.transparent,
                    width: state.focused ? 1.6 : 1,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
                // Both slots are fixed-height: an icon box and a two-line label
                // box. Sizing them to their content let one-line names push their
                // icon down and two-line names pull theirs up, which read as a
                // ragged, non-gridded wall.
                child: Column(
                  children: [
                    SizedBox(
                      height: 52,
                      width: 52,
                      child: Center(child: _buildIcon(c, state)),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 30,
                      width: double.infinity,
                      child: Text(
                        app.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.25,
                          color: state.highlighted
                              ? c.textPrimary
                              : c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // The pin sits in the corner only while the app is pinned: the
              // badge is how the home row explains itself.
              if (pinned)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Icon(Icons.push_pin, size: 11, color: c.accent),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(AppColors c, TapState state) {
    final iconFile = app.iconFile;
    return AnimatedSwitcher(
      duration: Motion.base,
      switchInCurve: Motion.outCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: iconFile != null
          ? Image.file(
              File(iconFile),
              key: ValueKey(iconFile),
              width: 44,
              height: 44,
              fit: BoxFit.contain,
              // Icons are cached at 96 px and drawn at 44 (66 physical on a
              // 150% display); mipmapped bilinear is the filter that suits that
              // downscale, and it is the cheaper one per tile.
              cacheWidth: 96,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => _letterTile(c, state),
            )
          : _letterTile(c, state),
    );
  }

  Widget _letterTile(AppColors c, TapState state) {
    final char = app.name.characters.first.toUpperCase();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: c.accentDim,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: c.accent,
        ),
      ),
    );
  }
}
