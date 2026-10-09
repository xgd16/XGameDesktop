import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../core/typography.dart';
import '../native/gamepad.dart';
import '../native/hwprobe_bindings.dart';
import '../native/hwprobe_service.dart';
import '../native/wallpaper_engine.dart';
import '../native/win32_api.dart' as native;
import '../state/live_surfaces.dart';
import '../state/settings_provider.dart';
import 'background_layer.dart';
import 'brand_mark.dart';
import 'nav.dart';
import 'widgets.dart';

/// The settings page, arranged like a console's system settings: a left rail
/// of section names — the only place the labels live, with an accent tick
/// tracking where you are — and, on the right, one scrolling column of full-
/// width rows, what a setting is on the left and its control at the right
/// edge. The wallpaper and how it is drawn lead the page; the preview card is
/// the same [AppBackground] the window uses, so everything applies as it is
/// changed.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.onClose,
    this.pickImage,
    this.onEnterImmersive,
    this.gamepad,
    this.hwprobe,
    this.focusNode,
  });

  final VoidCallback onClose;

  /// Test seam: the native dialog otherwise.
  final String? Function()? pickImage;

  /// Enters immersive fullscreen now; the button is hidden when null.
  final VoidCallback? onEnterImmersive;

  /// Shown as the pad's live status; the page works without one (the tests
  /// build it on its own).
  final GamepadService? gamepad;

  /// Hot-applies the usage-mode choice to the monitoring backend; the page
  /// works without one (the tests build it on its own).
  final HwprobeService? hwprobe;

  /// The page's own focus scope, supplied by the shell so it can hand the
  /// pad's highlight to the page the moment it opens. Give it a
  /// [FocusScopeNode]: everything inside the page then moves within the page,
  /// and closing it hands the highlight back to what had it before.
  final FocusNode? focusNode;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _sectionLabels = <String>[
    '背景',
    '主题颜色',
    '通用',
    '沉浸模式',
    '手柄与触屏',
    '硬件监控',
    '关于',
  ];

  /// The box the sections scroll within; section tops are measured against it.
  final _viewportKey = GlobalKey();
  final _scroll = ScrollController();

  late final _sectionKeys =
      List<GlobalKey>.generate(_sectionLabels.length, (_) => GlobalKey());

  int _activeSection = 0;

  @override
  void initState() {
    super.initState();
    // Reads the registry and Wallpaper Engine's config: once per visit, not
    // on every rebuild of the page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<SettingsProvider>().refreshWallpaperEngine();
        _updateActiveSection();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _pick() {
    final path = (widget.pickImage ?? native.pickImageFile)();
    if (!mounted || path == null) return;
    final settings = context.read<SettingsProvider>();
    if (!settings.setBackgroundFrom(path)) {
      _toast('无法读取这张图片');
    }
  }

  Future<void> _useWe(WallpaperEngineWallpaper wallpaper) async {
    final settings = context.read<SettingsProvider>();
    final ok = await settings.useWallpaperEngine(wallpaper);
    if (!mounted) return;
    _toast(ok ? '已使用「${wallpaper.title}」' : '无法读取这个壁纸');
  }

  void _toast(String message) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1800),
        backgroundColor: c.surfaceHover,
        content: Text(message, style: TextStyle(color: c.textPrimary)),
      ),
    );
  }

  void _jumpToSection(int index) {
    setState(() => _activeSection = index);
    final ctx = _sectionKeys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: Motion.base,
      curve: Motion.outCubic,
      alignment: 0.0,
    );
  }

  bool _onScroll(ScrollNotification n) {
    // The wallpaper list scrolls inside its own box; only the page itself
    // moves the anchor.
    if (n.depth == 0) _updateActiveSection();
    return false;
  }

  /// The rail's tick follows the reading position: the last section whose top
  /// has crossed the upper part of the viewport — or simply the last one once
  /// the page has run out of scroll.
  void _updateActiveSection() {
    if (!mounted || !_scroll.hasClients) return;
    final viewportBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;

    int active;
    if (_scroll.position.extentAfter < 4) {
      active = _sectionKeys.length - 1;
    } else {
      active = 0;
      for (var i = 0; i < _sectionKeys.length; i++) {
        final ctx = _sectionKeys[i].currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) continue;
        if (box.localToGlobal(Offset.zero, ancestor: viewportBox).dy <= 150) {
          active = i;
        }
      }
    }
    if (active != _activeSection) setState(() => _activeSection = active);
  }

  Widget _section(int index, AppColors c, SettingsProvider settings) {
    switch (index) {
      case 0:
        return _BackgroundSection(
          settings: settings,
          onPick: _pick,
          onUseWe: _useWe,
        );
      case 1:
        return _PaletteRow(settings: settings);
      case 2:
        return _GeneralSection(
          settings: settings,
          onSetFailed: _toast,
        );
      case 3:
        return _ImmersiveSection(
          settings: settings,
          onEnter: widget.onEnterImmersive,
        );
      case 4:
        return _InputSection(gamepad: widget.gamepad);
      case 5:
        return _MonitoringSection(
          settings: settings,
          hwprobe: widget.hwprobe,
        );
      default:
        return _About(c: c, settings: settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final settings = context.watch<SettingsProvider>();
    return Actions(
      // The pad's B (and Esc) closes the page, after every control inside has
      // had its chance to claim the key.
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            widget.onClose();
            return true;
          },
        ),
      },
      // One traversal group for the page: with it open, the grid behind must
      // stay out of the arrow keys' reach. The scope around it does the same
      // for the pad's own moves.
      child: FocusTraversalGroup(
        policy: _PageTraversalPolicy(),
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Material(
            color: c.bg,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 20, 30, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: c.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      PageCloseButton(
                        key: const Key('settingsClose'),
                        tooltip: '关闭设置 (Esc)',
                        onTap: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(height: 1, color: c.border),
                  Expanded(
                    // Top-aligned: the sections hang from the header rule rather
                    // than floating in the middle of a tall window.
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1060),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Rail(
                              labels: _sectionLabels,
                              active: _activeSection,
                              onTap: _jumpToSection,
                            ),
                            Container(
                              width: 1,
                              margin: const EdgeInsets.only(top: 10),
                              color: c.border,
                            ),
                            Expanded(
                              child: SizedBox.expand(
                                key: _viewportKey,
                                child: NotificationListener<
                                    ScrollNotification>(
                                  onNotification: _onScroll,
                                  child: SingleChildScrollView(
                                    controller: _scroll,
                                    padding: const EdgeInsets.only(
                                        left: 30, top: 8, right: 4, bottom: 44),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (var i = 0;
                                            i < _sectionLabels.length;
                                            i++)
                                          KeyedSubtree(
                                            key: _sectionKeys[i],
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                  top: i == 0 ? 2 : 34),
                                              child: _section(i, c, settings),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
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
        ),
      ),
    );
  }
}

/// The section index. The labels live here and nowhere else — like a console's
/// settings menu, the content column shows only the settings themselves and
/// the tick says which section they belong to.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.labels,
    required this.active,
    required this.onTap,
  });

  final List<String> labels;
  final int active;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 164,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          for (var i = 0; i < labels.length; i++)
            _RailItem(
              label: labels[i],
              active: i == active,
              onTap: () => onTap(i),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Pointer-only: the pad walks the page's controls in reading order, where
    // everything is already reachable, and seven rail stops interleaved into
    // that walk would only get in the way. The tick is a location marker, the
    // tap a jump.
    return Tappable(
      focusable: false,
      onTap: onTap,
      builder: (context, state) => TouchTarget(
        minSize: const Size(0, 38),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.outCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: state.highlighted ? c.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: Motion.base,
                curve: Motion.outCubic,
                width: 3,
                height: 15,
                decoration: BoxDecoration(
                  color: active ? c.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 11),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? c.textPrimary : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A console-style setting row: what the setting is on the left, its control
/// at the right edge — legible from a couch, and every control lands on the
/// same edge for the pad's walk.
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, this.control});

  final String label;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13.5, color: c.textPrimary),
            ),
          ),
          if (control != null) ...[
            const SizedBox(width: 16),
            control!,
          ],
        ],
      ),
    );
  }
}

/// Rows of one section, parted by hairlines.
class _RowGroup extends StatelessWidget {
  const _RowGroup({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Container(height: 1, color: c.border),
          rows[i],
        ],
      ],
    );
  }
}

/// The quiet explanatory line under a row group.
class _HelperText extends StatelessWidget {
  const _HelperText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, height: 1.5, color: c.textMuted),
      ),
    );
  }
}

class _BackgroundSection extends StatelessWidget {
  const _BackgroundSection({
    required this.settings,
    required this.onPick,
    required this.onUseWe,
  });

  final SettingsProvider settings;
  final VoidCallback onPick;
  final Future<void> Function(WallpaperEngineWallpaper) onUseWe;

  @override
  Widget build(BuildContext context) {
    final controls = _BackgroundControls(
      settings: settings,
      onPick: onPick,
      onUseWe: onUseWe,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PreviewCard(settings: settings, fixedAspect: true),
              const SizedBox(height: 20),
              controls,
            ],
          );
        }
        // The card stretches to the controls column's height: the wallpaper
        // covers the window whatever its shape, so the preview crops like the
        // real thing instead of leaving dead space under a fixed 16:9 card.
        // IntrinsicHeight gives the row a height inside the scroll view —
        // the controls alone size it, the card then fills it.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: _PreviewCard(settings: settings)),
              const SizedBox(width: 26),
              Expanded(flex: 4, child: controls),
            ],
          ),
        );
      },
    );
  }
}

/// 16:9 card showing exactly what the window shows: the same layer, with the
/// current blur and scrim. Beside the controls it stretches to the row's
/// height instead — [fixedAspect] is for the stacked narrow layout, where
/// nothing else sets a height.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.settings, this.fixedAspect = false});

  final SettingsProvider settings;

  /// Lock the card to 16:9; without it the card fills whatever box the row
  /// hands it.
  final bool fixedAspect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget child = AppBackground(
      // A scene gets a second renderer for this little card otherwise;
      // the still shows what the window shows soon enough.
      sceneStill: true,
      placeholder: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 22, color: c.textMuted),
          const SizedBox(height: 8),
          Text('未设置背景图',
              style: TextStyle(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
    if (fixedAspect) {
      child = AspectRatio(aspectRatio: 16 / 9, child: child);
    }
    return Container(
      decoration: BoxDecoration(
        color: c.borderStrong,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: child,
      ),
    );
  }
}

class _BackgroundControls extends StatelessWidget {
  const _BackgroundControls({
    required this.settings,
    required this.onPick,
    required this.onUseWe,
  });

  final SettingsProvider settings;
  final VoidCallback onPick;
  final Future<void> Function(WallpaperEngineWallpaper) onUseWe;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            GhostButton(
              label: '选择图片',
              icon: Icons.folder_open_rounded,
              tone: GhostButtonTone.accent,
              onTap: onPick,
            ),
            const SizedBox(width: 10),
            GhostButton(
              label: '清除背景',
              icon: Icons.close_rounded,
              onTap: settings.hasBackground ? settings.clearBackground : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _WallpaperEnginePicker(settings: settings, onUse: onUseWe),
        const SizedBox(height: 18),
        Row(
          children: [
            SizedBox(
              width: 46,
              child: Text('填充',
                  style: TextStyle(fontSize: 12, color: c.textMuted)),
            ),
            Segmented<BackgroundFit>(
              value: settings.backgroundFit,
              options: [
                for (final fit in BackgroundFit.values)
                  (fit, backgroundFitLabels[fit]!),
              ],
              onChanged: settings.setBackgroundFit,
            ),
          ],
        ),
        // A scene draws at a fixed rate, so the rate is the cost dial. The
        // other live kinds set their own pace: a video plays at its own fps
        // and a web page answers to its author.
        if (settings.backgroundSource == BackgroundSource.scene &&
            LiveSurfaces.scene) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 46,
                child: Text('帧率',
                    style: TextStyle(fontSize: 12, color: c.textMuted)),
              ),
              Segmented<int>(
                value: settings.sceneFps,
                options: [
                  for (final fps in SettingsProvider.sceneFpsChoices)
                    (fps, '$fps'),
                ],
                onChanged: settings.setSceneFps,
              ),
              const SizedBox(width: 10),
              Text('越低越省 GPU',
                  style: TextStyle(fontSize: 11, color: c.textMuted)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        _SliderRow(
          sliderKey: const Key('backgroundDim'),
          label: '暗化',
          value: settings.backgroundDim,
          max: 0.9,
          // TEMP-BISECT readout restored
          format: (v) => '${(v * 100).round()}%',
          // The dim rides the background's own signature: the scrim is baked
          // into the copy the window paints, so a commit per pointer move is a
          // whole-window bake per pointer move — the same spike the blur below
          // defers, for the same reason.
          commitOnEnd: true,
          onChanged: settings.setBackgroundDim,
        ),
        _SliderRow(
          sliderKey: const Key('backgroundBlur'),
          label: '模糊',
          value: settings.backgroundBlur,
          max: 24,
          format: (v) => '${v.round()} px',
          // The blur is a full-window gaussian: applying it per pointer move
          // re-rasterizes it for every pixel the thumb crosses, and the drag
          // reads as a GPU spike. The track and the readout still follow the
          // thumb; the picture itself picks the value up on release.
          commitOnEnd: true,
          onChanged: settings.setBackgroundBlur,
        ),
        const SizedBox(height: 14),
        Text(
          '图片会复制一份到应用数据目录，原图移动或删除都不影响。暗化用来把界面压在图片之上。',
          style: TextStyle(fontSize: 11.5, height: 1.5, color: c.textMuted),
        ),
      ],
    );
  }
}

/// Wallpaper Engine's wallpapers, the one it currently has applied first:
/// clicking a row makes it this app's background. Everything here comes from
/// files on disk, so Wallpaper Engine neither has to be running nor even
/// installed — without it the section just says so and the manual buttons
/// above keep working exactly as before.
class _WallpaperEnginePicker extends StatelessWidget {
  const _WallpaperEnginePicker({required this.settings, required this.onUse});

  final SettingsProvider settings;
  final Future<void> Function(WallpaperEngineWallpaper) onUse;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final list = settings.weWallpapers;
    final currentFile = settings.weCurrentFile?.toLowerCase();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wallpaper_rounded, size: 14, color: c.textSecondary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Wallpaper Engine',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
              ),
              if (list.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '${list.length} 张',
                  style: TelemetryText.number(11, c.textMuted),
                ),
              ],
              const Spacer(),
              GhostButton(
                key: const Key('weRefresh'),
                label: '刷新',
                icon: Icons.refresh_rounded,
                onTap: () => settings.refreshWallpaperEngine(force: true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            Text(
              settings.weFound
                  ? '没有找到壁纸。'
                  : '未检测到 Wallpaper Engine，用上面的按钮也能选图片。',
              style: TextStyle(fontSize: 11.5, color: c.textMuted),
            )
          else
            // A bounded height keeps the list scrolling inside the page
            // instead of stretching it; the rows are built lazily.
            SizedBox(
              height: (list.length * 46).clamp(0, 236).toDouble(),
              child: Scrollbar(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: list.length,
                  itemBuilder: (context, i) => _WallpaperRow(
                    key: ValueKey(list[i].projectDir),
                    wallpaper: list[i],
                    applied: settings.isWeApplied(list[i]),
                    weCurrent: currentFile != null &&
                        list[i].primaryFile.toLowerCase() == currentFile,
                    onTap: () => onUse(list[i]),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            '视频壁纸在应用里直接播放（静音循环），网页壁纸用内置浏览器跑作者的页面，'
            '场景壁纸由内置渲染器按包里的着色器和粒子实时绘制；三者都直接引用原文件，'
            '不复制。',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _WallpaperRow extends StatelessWidget {
  const _WallpaperRow({
    super.key,
    required this.wallpaper,
    required this.applied,
    required this.weCurrent,
    required this.onTap,
  });

  final WallpaperEngineWallpaper wallpaper;
  final bool applied;

  /// True for the wallpaper Wallpaper Engine itself currently has applied.
  final bool weCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final preview = wallpaper.previewPath;
    return Tappable(
      onTap: onTap,
      builder: (context, state) => TouchTarget(
        minSize: const Size(0, 44),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.outCubic,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: state.highlighted ? c.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: state.focused ? c.accent : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 46,
                  height: 30,
                  child: preview == null
                      ? ColoredBox(
                          color: c.borderStrong,
                          child: Icon(Icons.image_outlined,
                              size: 14, color: c.textMuted),
                        )
                      : Image.file(
                          File(preview),
                          fit: BoxFit.cover,
                          cacheWidth: 138,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              ColoredBox(color: c.borderStrong),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      wallpaper.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          wallpaper.typeLabel,
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                        if ((wallpaper.isVideo && LiveSurfaces.video) ||
                            (wallpaper.isWeb && LiveSurfaces.web) ||
                            (wallpaper.isScene && LiveSurfaces.scene)) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.play_arrow_rounded,
                              size: 12, color: c.accent),
                          const SizedBox(width: 1),
                          Text('动态',
                              style:
                                  TextStyle(fontSize: 11, color: c.accent)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (applied)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.accentDim,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('使用中',
                      style: TextStyle(fontSize: 10.5, color: c.accent)),
                )
              else if (weCurrent)
                Text('WE 当前',
                    style: TextStyle(fontSize: 10.5, color: c.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatefulWidget {
  const _SliderRow({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.max,
    required this.format,
    required this.onChanged,
    this.commitOnEnd = false,
  });

  final Key sliderKey;
  final String label;
  final double value;
  final double max;

  /// The readout for any value on the track — the row shows the thumb's
  /// position while a drag is in flight, which with [commitOnEnd] is ahead of
  /// what the provider holds.
  final String Function(double value) format;

  final ValueChanged<double> onChanged;

  /// Applies [onChanged] only when the drag (or a pad step) ends. For the
  /// treatments that re-rasterize the whole background per value — the blur —
  /// a per-pointer-move commit is a GPU spike for its own sake; the slider and
  /// the readout still track the thumb live through the row's own state.
  final bool commitOnEnd;

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  /// The slider's own node, held here so the row can show the pad's highlight:
  /// a slider paints nothing of its own when it is focused, and the ring the
  /// rest of the app draws for a focused control has to come from the row.
  final _focusNode = FocusNode(debugLabel: 'slider');

  /// The value under the thumb while a drag is in flight, when committing is
  /// deferred to the end of it. Null means the provider's value is the truth.
  double? _drag;

  double get _effective => _drag ?? widget.value;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_SliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The provider moved underneath a drag (a reset, another control on the
    // same value): the drag's local value is stale, so let go of it. Our own
    // commit only lands after the drag is over, so it never takes this path.
    if (_drag != null && widget.value != oldWidget.value) _drag = null;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _commit(double value) {
    if (_drag != null) setState(() => _drag = null);
    widget.onChanged(value.clamp(0.0, widget.max));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final value = _effective;
    final max = widget.max;
    // A pad adjusts the slider with left and right; up and down keep walking
    // the page (returning false lets the shell's traversal take over). A pad
    // step is a discrete event — it commits directly, the way a release does.
    return Actions(
      actions: {
        FocusDirectionIntent: CallbackAction<FocusDirectionIntent>(
          onInvoke: (intent) {
            final step = max / 20;
            switch (intent.direction) {
              case TraversalDirection.left:
                _commit(value - step);
              case TraversalDirection.right:
                _commit(value + step);
              case TraversalDirection.up:
              case TraversalDirection.down:
                return false;
            }
            return true;
          },
        ),
      },
      // Over the row rather than around it: the ring cannot shift the track.
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _focusNode.hasFocus ? c.accent : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(widget.label,
                  style: TextStyle(fontSize: 12, color: c.textMuted)),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: c.accent,
                  inactiveTrackColor: c.barTrack,
                  thumbColor: c.accent,
                  overlayColor: c.accentDim,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  trackShape: const RoundedRectSliderTrackShape(),
                  showValueIndicator: ShowValueIndicator.never,
                ),
                child: Slider(
                  key: widget.sliderKey,
                  focusNode: _focusNode,
                  value: value.clamp(0.0, max),
                  max: max,
                  onChangeStart:
                      widget.commitOnEnd ? (v) => setState(() => _drag = v) : null,
                  onChanged: (v) {
                    if (widget.commitOnEnd) {
                      setState(() => _drag = v);
                    } else {
                      widget.onChanged(v);
                    }
                  },
                  onChangeEnd: widget.commitOnEnd ? _commit : null,
                ),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                widget.format(value),
                textAlign: TextAlign.right,
                style: TelemetryText.number(13, c.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Immersive mode: the same desktop page, borderless across the whole desktop
/// and magnified to be readable from a couch. The first switch decides
/// whether the app boots into it; the button goes there now; the second
/// decides whether the taskbar above it keeps its own background or turns
/// clear so the app's shows through.
class _ImmersiveSection extends StatelessWidget {
  const _ImmersiveSection({required this.settings, this.onEnter});

  final SettingsProvider settings;
  final VoidCallback? onEnter;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowGroup(rows: [
          _SettingRow(
            label: '启动时直接进入沉浸模式',
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEnter != null) ...[
                  GhostButton(
                    label: '立即进入',
                    icon: Icons.fullscreen_rounded,
                    tone: GhostButtonTone.accent,
                    onTap: onEnter,
                  ),
                  const SizedBox(width: 12),
                ],
                _Toggle(
                  key: const Key('immersiveOnLaunch'),
                  value: settings.immersiveOnLaunch,
                  onChanged: settings.setImmersiveOnLaunch,
                ),
              ],
            ),
          ),
          _SettingRow(
            label: '任务栏融入背景',
            control: _Toggle(
              key: const Key('immersiveTaskbarBlend'),
              value: settings.immersiveTaskbarBlend,
              onChanged: settings.setImmersiveTaskbarBlend,
            ),
          ),
        ]),
        const _HelperText(
          '无边框铺满整个桌面，代替桌面壁纸和图标；还是这一页，整体放大一档，'
          '标题栏留下，窗口按钮让位。打开“任务栏融入背景”后，窗口垫到任务栏下面、'
          '任务栏变透明，应用的背景直接透出来；关闭则应用止步于任务栏上方，'
          '任务栏保持原样。按 F11 或 Esc 退出，手柄上是 View 键。',
        ),
      ],
    );
  }
}

/// General app behavior. Auto-start is applied the moment the switch moves —
/// the Run entry is written before the next sign-in — and a refused write
/// leaves the switch where it was, with [onSetFailed] saying so.
class _GeneralSection extends StatelessWidget {
  const _GeneralSection({required this.settings, required this.onSetFailed});

  final SettingsProvider settings;
  final void Function(String message) onSetFailed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowGroup(rows: [
          _SettingRow(
            label: '开机自动启动',
            control: _Toggle(
              key: const Key('launchOnStartup'),
              value: settings.launchOnStartup,
              onChanged: (value) async {
                final ok = await settings.setLaunchOnStartup(value);
                if (!ok && context.mounted) {
                  onSetFailed(value ? '无法设置开机自启动' : '无法取消开机自启动');
                }
              },
            ),
          ),
        ]),
        const _HelperText(
          '登录 Windows 后自动打开应用，开关拨动立即生效。实现是当前用户的计划任务，'
          '与应用自身的权限一致，过程中不会额外弹窗；卸载应用时会一并清除。',
        ),
        const SizedBox(height: 22),
        _RowGroup(rows: [
          _SettingRow(
            label: '掌机低功耗',
            control: Segmented<bool?>(
              value: settings.lowPower,
              options: const [
                (null, '自动'),
                (true, '开'),
                (false, '关'),
              ],
              onChanged: settings.setLowPower,
            ),
          ),
        ]),
        const _HelperText(
          '把“每一帧都在画”的几件事收一收：场景壁纸最高 15 帧、壁纸模糊最高 8px、'
          '开屏装配与看板数值缓动直接到位；被全屏应用盖住时读数也不再动画。'
          '自动＝检测到电池（掌机、笔记本）时打开，台式机上保持关闭。',
        ),
      ],
    );
  }
}

/// The usage-sampling choice: whose CPU/GPU utilization numbers the metrics
/// panel shows. The switch is wired straight into the monitoring backend, so
/// flipping it re-weights the readings within a second — no restart.
class _MonitoringSection extends StatelessWidget {
  const _MonitoringSection({required this.settings, this.hwprobe});

  final SettingsProvider settings;
  final HwprobeService? hwprobe;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowGroup(rows: [
          _SettingRow(
            label: '占用率按任务管理器口径',
            control: _Toggle(
              key: const Key('usageTaskManagerMode'),
              value: settings.usageSensorMode == usageModeTaskManager,
              onChanged: (v) {
                settings.setUsageSensorMode(
                    v ? usageModeTaskManager : usageModeStandard);
                hwprobe?.setUsageMode(settings.usageSensorMode);
              },
            ),
          ),
          _SettingRow(
            label: '设备信息采集间隔',
            control: Segmented<int>(
              value: settings.sampleIntervalSeconds,
              options: [
                for (final seconds in SettingsProvider.sampleIntervalChoices)
                  (seconds, '$seconds 秒'),
              ],
              onChanged: settings.setSampleInterval,
            ),
          ),
        ]),
        const _HelperText(
          '关闭：CPU/GPU 占用率取“忙碌时间占比”，与 HWiNFO 等工具一致。'
          '打开：CPU 按实际频率加权（睿频时偏高、降频时偏低），GPU 取最忙引擎，'
          '与 Windows 任务管理器一致。切换约一秒生效，无需重启；'
          '个别机器的性能计数器被安全软件破坏时，该口径的占用读数会显示不可用，'
          '温度、功耗、频率等不受影响。\n'
          '采集间隔是监控页记下设备读数（占用、温度、功耗、内存、磁盘、网络、风扇）'
          '的频率，改完下一次采集就按新间隔走；记录只留最近 7 天，更早的自动删掉。'
          '间隔越短曲线越细，一周的数据也越多。',
        ),
      ],
    );
  }
}

/// What the app does with a controller and a finger, and whether it can see
/// either right now. The mappings are the whole point: a pad user should not
/// have to guess what X does.
class _InputSection extends StatelessWidget {
  const _InputSection({required this.gamepad});

  final GamepadService? gamepad;

  static const _mappings = <(String, String)>[
    ('A', '启动 / 确认'),
    ('B', '返回 / 关闭浮层'),
    ('X', '回到应用图标区'),
    ('Y', '屏幕键盘'),
    ('View', '沉浸模式'),
    ('LB / RB', '切换 推荐 / 桌面'),
    ('LT / RT', '上下翻页'),
    ('方向键 / 左摇杆', '移动焦点'),
    ('Start', '打开设置页'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final connected = gamepad?.connected ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowGroup(rows: [
          _SettingRow(
            label: '手柄',
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(on: connected, color: c),
                const SizedBox(width: 8),
                Text(
                  connected ? '已连接' : '未检测到，插上就能用',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ],
            ),
          ),
          _SettingRow(
            label: '触屏',
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  touchScreen ? Icons.touch_app_outlined : Icons.mouse_outlined,
                  size: 14,
                  color: c.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  touchScreen ? '检测到' : '未检测到',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (key, label) in _mappings)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      key,
                      style: TextStyle(
                        fontFamily: 'Rajdhani',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: c.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(label,
                        style:
                            TextStyle(fontSize: 11.5, color: c.textSecondary)),
                  ],
                ),
              ),
          ],
        ),
        const _HelperText(
          '触屏：点按等于单击，长按应用图标打开右键菜单，拖动标题栏移动窗口，'
          '搜索框右侧的键盘按钮打开屏幕键盘；按钮的命中区域会自动放大到手指大小。',
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.on, required this.color});

  final bool on;
  final AppColors color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? color.ok : color.textMuted,
      ),
    );
  }
}

/// A small pill switch in the app's own idiom — the Material switch reads as
/// a different product.
class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tappable(
      onTap: () => onChanged(!value),
      builder: (context, state) => TouchTarget(
        minSize: const Size(0, 44),
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Motion.outCubic,
          width: 40,
          height: 22,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? c.accent : c.barTrack,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: state.focused
                  ? c.textPrimary
                  : value
                      ? c.accent
                      : c.border,
              width: state.focused ? 1.4 : 1,
            ),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? Colors.white : c.textMuted,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// One tile per palette, drawn as a thumbnail of the palette itself — its own
/// background carrying its own accent — so choosing a theme is reading the
/// theme, not a color dot's name.
class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final p in appPalettes)
          Tappable(
            onTap: () => settings.setPalette(p.id),
            builder: (context, state) {
              final selected = settings.palette == p.id;
              return TouchTarget(
                minSize: const Size(0, 44),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  curve: Motion.outCubic,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected
                        ? c.accentDim
                        : state.highlighted
                            ? c.surfaceHover
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: selected
                          ? p.accent
                          : state.focused
                              ? c.textPrimary
                              : c.border,
                      width: selected || state.focused ? 1.4 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 34,
                        height: 22,
                        decoration: BoxDecoration(
                          color: p.bg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: c.borderStrong),
                        ),
                        padding: const EdgeInsets.all(6),
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? c.textPrimary : c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _About extends StatelessWidget {
  const _About({required this.c, required this.settings});

  final AppColors c;
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // The app icon itself, drawn from the same geometry the .ico uses.
        const BrandMark(size: 44, tile: true),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('XGame Desktop',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      )),
                  const SizedBox(width: 10),
                  Text('1.0.0',
                      style: TelemetryText.number(12.5, c.textMuted)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      settings.dataDir.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GhostButton(
                    label: '打开目录',
                    icon: Icons.folder_outlined,
                    onTap: () {
                      try {
                        settings.dataDir.createSync(recursive: true);
                        native.shellExecuteOpen(settings.dataDir.path);
                      } catch (_) {}
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Up and down walk the page the way it reads: the sections hang one under the
/// other in the content column, and the geometric rule the rest of the window
/// uses only ever found the buttons down the right-hand side — a toggle or a
/// slider in the middle of a row was simply out of the pad's reach, and past
/// the last of them the highlight stopped at the bottom edge and would not
/// move at all. Left and right stay geometric, which is what a row of palette
/// tiles wants. The rail beside the column is not part of this walk: it is a
/// pointer's jump list, and its taps scroll, they do not take the highlight.
class _PageTraversalPolicy extends ReadingOrderTraversalPolicy {
  _PageTraversalPolicy();

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    switch (direction) {
      case TraversalDirection.down:
        return next(currentNode);
      case TraversalDirection.up:
        return previous(currentNode);
      case TraversalDirection.left:
      case TraversalDirection.right:
        return super.inDirection(currentNode, direction);
    }
  }
}
