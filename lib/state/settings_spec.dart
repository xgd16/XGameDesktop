import '../data/config_store.dart';

/// One persisted setting: the key it lives under in the `config` table, the
/// label that goes in the row's `name`, and the `value_type` it is stored as.
class SettingSpec {
  const SettingSpec(this.key, this.name, this.type);

  /// The row's primary key.
  final String key;

  /// The row's human label — what a person reading the table sees.
  final String name;

  /// How the row's value is written and read back.
  final ConfigValueType type;

  @override
  String toString() => '$key (${type.wire})';
}

/// Every setting the app persists, and where it sits in the `config` table.
///
/// This catalogue is the one place a setting's key and type are written down:
/// the loader, the saver and the one-time import of the old `settings.json`
/// all read from it, so a key cannot drift apart between them.
abstract final class Settings {
  // ---- appearance ----

  /// The active colour palette, by name rather than by index — see
  /// [ConfigValueType.enumeration].
  static const palette =
      SettingSpec('appearance.palette', '主题颜色', ConfigValueType.enumeration);

  /// The file name of the background copy inside the data directory. Only a
  /// picture is copied; anything live is referenced where it lies.
  static const backgroundImage = SettingSpec(
      'appearance.background.image', '背景图片副本', ConfigValueType.string);

  /// Where a video, a page or a scene package background lives. A scene's
  /// package is hundreds of megabytes and a page needs the folder around it, so
  /// those are never copied.
  static const backgroundSource = SettingSpec(
      'appearance.background.source', '背景来源路径', ConfigValueType.string);

  /// Which of the four kinds of background is in use — see `BackgroundSource`.
  static const backgroundKind = SettingSpec(
      'appearance.background.kind', '背景类型', ConfigValueType.enumeration);

  /// How far the scrim is drawn over the background, 0 – 0.9.
  static const backgroundDim = SettingSpec(
      'appearance.background.dim', '背景暗化', ConfigValueType.number);

  /// The gaussian blur radius over the background, 0 – 24 px.
  static const backgroundBlur = SettingSpec(
      'appearance.background.blur', '背景模糊', ConfigValueType.number);

  /// How the background fills the window — see `BackgroundFit`.
  static const backgroundFit = SettingSpec(
      'appearance.background.fit', '背景填充方式', ConfigValueType.enumeration);

  /// Whether the current background came from Wallpaper Engine.
  static const backgroundFromWe = SettingSpec(
      'appearance.background.we.enabled', '背景取自 Wallpaper Engine',
      ConfigValueType.boolean);

  /// `项目目录|播放文件`, lower-cased. Titles repeat across the workshop, so
  /// this, not the label, is what tells two wallpapers apart.
  static const backgroundWeId = SettingSpec(
      'appearance.background.we.id', 'Wallpaper Engine 壁纸标识',
      ConfigValueType.string);

  /// `标题 · 类型` of the adopted wallpaper, for the settings page to show.
  static const backgroundWeLabel = SettingSpec(
      'appearance.background.we.label', 'Wallpaper Engine 壁纸名称',
      ConfigValueType.string);

  // ---- launch ----

  /// Whether the app opens straight into immersive fullscreen.
  static const immersiveOnLaunch = SettingSpec(
      'launch.immersive', '沉浸式启动', ConfigValueType.boolean);

  /// Whether Windows launches the app at sign-in.
  static const launchOnStartup = SettingSpec(
      'launch.autoStart', '开机自启动', ConfigValueType.boolean);

  /// Whether immersive lays the window under the taskbar and clears the
  /// taskbar's own background.
  static const taskbarBlend = SettingSpec(
      'launch.taskbarBlend', '任务栏融合', ConfigValueType.boolean);

  // ---- monitoring ----

  /// Which utilization sampling the probe reports: 0 = standard, 1 =
  /// Task-Manager style.
  static const usageMode = SettingSpec(
      'monitor.usageMode', '监控采样口径', ConfigValueType.integer);

  /// How often the device history is collected, in seconds. One of
  /// `SettingsProvider.sampleIntervalChoices`; anything else is ignored on
  /// the way in and reads as the default.
  static const sampleSeconds = SettingSpec(
      'monitor.sampleSeconds', '设备信息采集间隔', ConfigValueType.integer);

  // ---- scene wallpaper ----

  /// The rate the scene renderer is asked for: 15, 30 or 60.
  static const sceneFps =
      SettingSpec('scene.fps', '场景壁纸帧率', ConfigValueType.integer);

  // ---- power ----

  /// The low-power profile: true, false, or — when the row is absent — no
  /// choice at all, which leaves the decision to the battery.
  static const lowPower =
      SettingSpec('power.lowPower', '低功耗档', ConfigValueType.boolean);

  /// Every spec, in the order they are written and read back.
  static const all = <SettingSpec>[
    palette,
    backgroundImage,
    backgroundSource,
    backgroundKind,
    backgroundDim,
    backgroundBlur,
    backgroundFit,
    backgroundFromWe,
    backgroundWeId,
    backgroundWeLabel,
    immersiveOnLaunch,
    launchOnStartup,
    taskbarBlend,
    usageMode,
    sampleSeconds,
    sceneFps,
    lowPower,
  ];
}

/// Writes a setting through its [SettingSpec], so a caller never restates the
/// key, the label or the type.
extension SettingWrite on ConfigStore {
  /// Stores [value] in the row [spec] describes.
  ConfigEntry write(SettingSpec spec, Object? value) =>
      put(spec.key, spec.name, spec.type, value);
}

/// Reads a setting through its [SettingSpec].
extension SettingRead on ConfigStore {
  /// The value of the row [spec] describes, or null when it is unset or
  /// unreadable.
  Object? valueOf(SettingSpec spec) => read(spec.key, spec.type);

  /// The constant of [values] the row [spec] names, or null when the row is
  /// unset or names a constant this build does not have — a palette that was
  /// renamed, say, which then falls back to the caller's default.
  E? enumValueOf<E extends Enum>(SettingSpec spec, List<E> values) =>
      enumOf(spec.key, values);
}
