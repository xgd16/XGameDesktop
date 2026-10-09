import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../native/shell_apps.dart';
import '../state/apps_provider.dart';
import 'app_card.dart' show appToast, showAppMenu;
import 'nav.dart';
import 'widgets.dart';

/// A Steam game on the cover wall: the portrait art fills the cell and the
/// name sits under it, the way a console library draws. The cover comes from
/// Steam's own cache; when the machine has none — an older Steam, a game
/// Steam never drew a portrait for — it is fetched once from Steam's CDN and
/// kept in the data dir, and offline the tile stays on its letter block.
class GameCard extends StatefulWidget {
  const GameCard({
    super.key,
    required this.app,
    this.enterDelay,
    this.focusNode,
  });

  final AppEntry app;

  /// The grid's node for this slot; the pane aims the pad's highlight with it.
  final FocusNode? focusNode;

  /// Staggered delay for the grid's boot-up wave, same contract as AppCard.
  final Duration? enterDelay;

  @override
  State<GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<GameCard> {
  bool _askedForCover = false;

  @override
  void initState() {
    super.initState();
    _askForCover();
  }

  @override
  void didUpdateWidget(GameCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.app.path != oldWidget.app.path) _askForCover();
  }

  /// One ask per mount; [AppsProvider.fetchGameCover] deduplicates the rest.
  void _askForCover() {
    if (_askedForCover || widget.app.iconFile != null) return;
    _askedForCover = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cover = await context.read<AppsProvider>().fetchGameCover(
            widget.app,
          );
      if (cover != null && mounted) setState(() {});
    });
  }

  void _launch(BuildContext context) {
    final apps = context.read<AppsProvider>();
    if (!apps.launch(widget.app)) appToast(context, '无法启动 ${widget.app.name}');
  }

  void _showMenu(BuildContext context, Offset position) {
    showAppMenu(context, widget.app, position);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final pinned = context.watch<AppsProvider>().isPinned(widget.app);

    return Entrance(
      delay: widget.enterDelay ?? Duration.zero,
      animate: widget.enterDelay != null,
      child: Tappable(
        focusNode: widget.focusNode,
        onTap: () => _launch(context),
        onSecondaryTap: (position) => _showMenu(context, position),
        onLongPress: (position) => _showMenu(context, position),
        builder: (context, state) => AnimatedScale(
          scale: state.pressing ? 0.96 : (state.hovering ? 1.04 : 1.0),
          duration: Motion.fast,
          curve: Motion.outCubic,
          child: Stack(
            children: [
              // The same highlighted sheet AppCard grows: faint frost over the
              // wallpaper, one fade driving it — and the same rule for the
              // blur: only the pad or the keyboard sitting on the card gets
              // one, never the mouse.
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: state.highlighted ? 1 : 0),
                    duration: Motion.base,
                    curve: Motion.outCubic,
                    builder: (context, t, _) {
                      if (t < 0.02) return const SizedBox.shrink();
                      return Frosted(
                        radius: 12,
                        blur: state.focused ? 16 * t : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.frost.withValues(alpha: c.frost.a * t),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Container(
                // The cover is clipped inside; the ring rides the outer box.
                margin: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: state.highlighted ? c.accent : Colors.transparent,
                    width: state.focused ? 1.6 : 1,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 4),
                child: Column(
                  children: [
                    Expanded(child: _buildCover(c)),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 26,
                      width: double.infinity,
                      child: Text(
                        widget.app.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.15,
                          color: state.highlighted
                              ? c.textPrimary
                              : c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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

  Widget _buildCover(AppColors c) {
    final cover = widget.app.iconFile;
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: cover != null
          ? Image.file(
              File(cover),
              key: ValueKey(cover),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              cacheWidth: 320,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => _letterBlock(c),
            )
          : _letterBlock(c),
    );
  }

  /// A quiet stand-in with the game's initial — the shape of a portrait
  /// cover, so the wall stays a wall while the art is missing.
  Widget _letterBlock(AppColors c) {
    final char = widget.app.name.characters.first.toUpperCase();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: c.accentDim,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w600,
          color: c.accent,
        ),
      ),
    );
  }
}
