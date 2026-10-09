import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/theme.dart';
import '../data/app_database.dart';
import '../data/config_store.dart';
import '../native/autostart.dart';
import '../native/wallpaper_engine.dart';
import 'app_power.dart';
import 'legacy_settings_import.dart';
import 'live_surfaces.dart';
import 'settings_spec.dart';
import 'wallpaper_gate.dart';

/// How the background image is drawn into the window.
enum BackgroundFit { cover, contain, tile }

const backgroundFitLabels = {
  BackgroundFit.cover: '填充',
  BackgroundFit.contain: '适应',
  BackgroundFit.tile: '平铺',
};

/// What is behind the scrim.
enum BackgroundSource {
  /// A picture — a copy in the data dir, or the package artwork.
  image,

  /// A video wallpaper, played from where it lies.
  video,

  /// A web wallpaper: the author's page running in a browser.
  web,

  /// A scene wallpaper: its package drawn by the built-in renderer.
  scene,
}

/// Persisted app settings: the active color palette, and the background image
/// with its scrim/blur/fit — either picked by hand or taken from one of
/// Wallpaper Engine's wallpapers.
///
/// They live in the `config` table of the profile's SQLite database, one typed
/// row per setting (see [Settings] for the catalogue and [ConfigStore] for the
/// table). Each setter writes its row — or, for the sliders, schedules that
/// write — so there is no settings object to keep in sync with a file.
class SettingsProvider extends ChangeNotifier {
  /// [dataDir] lets tests read and write a temp folder instead of the real
  /// profile.
  SettingsProvider({Directory? dataDir}) : _dataDirOverride = dataDir;

  final Directory? _dataDirOverride;

  static Directory get _defaultDir {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$base\\XGameDesktop');
  }

  Directory get dataDir => _dataDirOverride ?? _defaultDir;

  /// The pre-SQLite settings file. Read once, by [importLegacySettings], the
  /// first time this profile's database is opened; never written, so it stays
  /// as a way back.
  File get _legacyFile => File('${dataDir.path}\\settings.json');

  /// Wallpapers are kept as copies inside the data dir, so the picture stays
  /// put when the original file is moved, renamed or deleted.
  static const _backgroundPrefix = 'background';

  PaletteId palette = PaletteId.violet;

  /// Opens straight into immersive fullscreen, the way a console launcher
  /// boots — no framed window flash first.
  bool immersiveOnLaunch = false;

  /// Whether Windows launches the app at sign-in: the scheduled task the
  /// settings switch and the installer's checkbox share. Flipping it
  /// rewrites the task at once — see [setLaunchOnStartup].
  bool launchOnStartup = false;

  /// Whether immersive lays the window under the taskbar and clears the
  /// taskbar's background, so the app's own background runs underneath — one
  /// continuous surface instead of a bar sitting on the page. Off, the window
  /// stops above the taskbar and the bar keeps its normal look.
  bool immersiveTaskbarBlend = true;

  /// Which utilization sampling the monitoring backend reports:
  /// 0 = standard (busy-time share / vendor APIs), 1 = Windows-Task-Manager
  /// style (frequency-weighted PDH utility / busiest GPU Engine counter).
  /// Hot-switchable at runtime; see HwprobeService.setUsageMode.
  int usageSensorMode = 0;

  /// How often the device history is collected. The choices are what the
  /// settings page offers and what the recorder is allowed to keep; three
  /// seconds is fine enough that a spike lasts a few points and coarse enough
  /// that a week of them still fits a chart.
  static const sampleIntervalChoices = [1, 2, 3, 5, 10, 30];

  int sampleIntervalSeconds = 3;

  /// The rates the scene wallpaper may be drawn at, low to high. The default
  /// is the background budget the renderer's page ships with; 60 is there for
  /// the machines that can afford it.
  static const sceneFpsChoices = [15, 30, 60];

  /// Scene wallpaper render rate. A scene draws bloom, particles and god rays
  /// continuously, so this is the dial between "alive" and "cheap" — the GPU
  /// cost is very close to linear in it.
  int sceneFps = 30;

  /// The low-power profile: null = whoever knows best (a battery means a
  /// handheld, and a handheld is the machine this is for), true = on, false =
  /// off. Persisted, so an explicit choice survives a restart; null stays null
  /// — and null is a missing row, not a row holding something falsey.
  bool? lowPower;

  /// Whether this machine reports a battery — a handheld or a laptop. Fed in by
  /// the shell, which is the only layer that knows about both the hardware
  /// probe and these settings.
  bool handheld = false;

  /// Whether the profile is in force right now: an explicit choice always wins,
  /// and an unstated one follows the battery.
  bool get lowPowerOn => lowPower ?? handheld;

  /// What the low-power profile holds the wallpaper's blur to, in the same
  /// units as [backgroundBlur]. A full-window gaussian at 24 px is the single
  /// most expensive thing a still wallpaper asks of the GPU, and past a few
  /// pixels the extra blur stops being visible.
  static const lowPowerBlurCap = 8.0;

  /// What the low-power profile holds a scene wallpaper's rate to.
  static const lowPowerSceneFpsCap = 15;

  /// The blur actually drawn with — the setting, held to the cap under the
  /// profile.
  double get effectiveBackgroundBlur =>
      lowPowerOn && backgroundBlur > lowPowerBlurCap
          ? lowPowerBlurCap
          : backgroundBlur;

  /// The rate actually handed to the scene renderer.
  int get effectiveSceneFps =>
      lowPowerOn && sceneFps > lowPowerSceneFpsCap
          ? lowPowerSceneFpsCap
          : sceneFps;

  String? backgroundPath;

  /// Whether [backgroundPath] is a copied picture, a video played in place, a
  /// page run in place, or a scene package drawn in place.
  BackgroundSource backgroundSource = BackgroundSource.image;

  double backgroundDim = 0.6;
  double backgroundBlur = 0;
  BackgroundFit backgroundFit = BackgroundFit.cover;

  /// True while the current background came from Wallpaper Engine.
  bool backgroundIsWallpaperEngine = false;

  /// `标题 · 类型` of the adopted Wallpaper Engine wallpaper.
  String? backgroundLabel;

  /// `项目目录|播放文件`（小写）of the adopted Wallpaper Engine wallpaper.
  /// Titles repeat across the workshop — two different wallpapers can carry
  /// the same one — so this, not the label, is what tells them apart.
  String? backgroundWeId;

  /// The identity of [wallpaper]: stable across rescans and switches.
  static String weIdentity(WallpaperEngineWallpaper wallpaper) =>
      '${wallpaper.projectDir}|${wallpaper.primaryFile}'.toLowerCase();

  /// Whether [wallpaper] is the one the background currently comes from.
  bool isWeApplied(WallpaperEngineWallpaper wallpaper) =>
      backgroundIsWallpaperEngine &&
      backgroundPath != null &&
      (backgroundWeId == weIdentity(wallpaper) ||
          // Saves from before the identity existed only kept the label.
          (backgroundWeId == null &&
              backgroundLabel == '${wallpaper.title} · ${wallpaper.typeLabel}'));

  /// Test seam: replaces the registry-based lookup. Return null to stand in
  /// for a machine without Wallpaper Engine.
  WallpaperEngineLibrary? Function()? wallpaperEngineLocator;

  /// Wallpaper Engine's wallpapers, the applied one first. Empty when WE is
  /// not installed — the app never needs it, and never needs it running.
  List<WallpaperEngineWallpaper> weWallpapers = const [];

  /// The file WE currently has applied, when its config says so.
  String? weCurrentFile;

  /// Whether a Wallpaper Engine installation was found at all (as opposed to
  /// one that is installed but has no wallpapers).
  bool weFound = false;

  /// The open profile database, and the typed view of its `config` table. Both
  /// are opened on first use — a test that only sets a value never needs the
  /// file read back — and released by [dispose].
  AppDatabase? _db;
  ConfigStore? _config;

  bool _loaded = false;
  bool _applied = false;
  bool _closed = false;
  bool _storedLaunchOnStartup = false;
  Timer? _saveTimer;

  bool get hasBackground => backgroundPath != null;

  /// True once the settings have been read — or found absent. Until then the
  /// palette and the wallpaper are still the defaults, which is why the opening
  /// screen waits on it: showing the shell a beat early would pop the wallpaper
  /// in behind the grid.
  bool get applied => _applied;

  /// The Wallpaper Engine installation, or null.
  WallpaperEngineLibrary? weLibrary() =>
      (wallpaperEngineLocator ?? WallpaperEngineLibrary.locate)();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final config = _store();
      // An unknown name — a palette this build does not have — reads as null
      // and falls back, rather than throwing the way an index would.
      palette =
          config.enumValueOf(Settings.palette, PaletteId.values) ?? palette;

      // A video, a page or a scene package is referenced where it lies —
      // workshop videos run to hundreds of megabytes, a page needs the folder
      // around it, and a scene package is read in place by the renderer. A
      // picture is a copy inside the data dir.
      final kind = config.enumValueOf(
              Settings.backgroundKind, BackgroundSource.values) ??
          BackgroundSource.image;
      final live = kind == BackgroundSource.video ||
          kind == BackgroundSource.web ||
          kind == BackgroundSource.scene;
      final source = config.valueOf(Settings.backgroundSource) as String?;
      if (live && source != null && source.isNotEmpty && File(source).existsSync()) {
        backgroundPath = source;
        backgroundSource = kind;
      } else {
        final name = config.valueOf(Settings.backgroundImage) as String?;
        if (name != null && name.isNotEmpty) {
          final copy = File('${dataDir.path}\\$name');
          if (copy.existsSync()) backgroundPath = copy.path;
        }
      }
      if (config.valueOf(Settings.immersiveOnLaunch) case final bool immersive) {
        immersiveOnLaunch = immersive;
      }
      if (config.valueOf(Settings.launchOnStartup) case final bool launch) {
        launchOnStartup = launch;
        _storedLaunchOnStartup = true;
      }
      if (config.valueOf(Settings.taskbarBlend) case final bool blend) {
        immersiveTaskbarBlend = blend;
      }
      if (config.valueOf(Settings.usageMode) case final int mode) {
        usageSensorMode = mode;
      }
      if (config.valueOf(Settings.sampleSeconds) case final int seconds
          when sampleIntervalChoices.contains(seconds)) {
        sampleIntervalSeconds = seconds;
      }
      if (config.valueOf(Settings.sceneFps) case final int fps
          when SettingsProvider.sceneFpsChoices.contains(fps)) {
        sceneFps = fps;
      }
      // A missing row means the user never chose: the profile then follows the
      // battery, which the shell reports once the probe is up.
      if (config.valueOf(Settings.lowPower) case final bool lowPower) {
        this.lowPower = lowPower;
      }
      if (config.valueOf(Settings.backgroundDim) case final double dim) {
        backgroundDim = dim.clamp(0.0, 0.9);
      }
      if (config.valueOf(Settings.backgroundBlur) case final double blur) {
        backgroundBlur = blur.clamp(0.0, 24.0);
      }
      if (config.enumValueOf(Settings.backgroundFit, BackgroundFit.values)
          case final BackgroundFit fit) {
        backgroundFit = fit;
      }
      backgroundIsWallpaperEngine = backgroundPath != null &&
          config.valueOf(Settings.backgroundFromWe) == true;
      final weId = config.valueOf(Settings.backgroundWeId) as String?;
      backgroundWeId =
          backgroundIsWallpaperEngine && weId != null && weId.isNotEmpty
              ? weId
              : null;
      final label = config.valueOf(Settings.backgroundWeLabel) as String?;
      if (label != null && label.isNotEmpty) backgroundLabel = label;
    } catch (_) {
      // First run or unreadable settings — keep defaults.
    }
    // The stored preference is the one source of truth; bring Windows's
    // auto-start task back in step (the executable may have moved, or the
    // task may have been deleted by hand). A schtasks spawn has no business
    // delaying the shell, so this runs behind it; a data-dir override means
    // a test — nothing outside the temp folder is ever touched.
    if (_dataDirOverride == null) {
      unawaited(_syncAutoStart());
    }
    _syncEconomy();
    _applied = true;
    notifyListeners();
  }

  /// The config store, opening the database the first time it is asked for.
  ///
  /// A profile that has never run the import still has everything its old
  /// `settings.json` knew; `once` records that it ran, in the database itself,
  /// so from here on the table is the only source.
  ConfigStore _store() {
    final open = _config;
    if (open != null) return open;
    final db = AppDatabase.open(dataDir);
    try {
      final config = db.configStore();
      db.once(AppDatabase.settingsImportFlag,
          () => importLegacySettings(config, _legacyFile));
      _db = db;
      return _config = config;
    } catch (_) {
      // Nothing keeps the connection if the first use of it failed — a caller
      // may try again, and a second connection is not what it should get.
      db.close();
      rethrow;
    }
  }

  void setPalette(PaletteId id) {
    if (id == palette) return;
    palette = id;
    notifyListeners();
    _save();
  }

  /// Re-reads Wallpaper Engine's wallpapers and its current selection. A few
  /// folder listings and small JSON files — no process is touched, so this
  /// works with Wallpaper Engine closed.
  ///
  /// [force] re-reads the registry and walks every library folder; without it,
  /// an unchanged library (roots untouched since the last scan) is served from
  /// the memo, and the registry answer lives for a minute. The page's refresh
  /// button passes true, the visit-time call does not.
  void refreshWallpaperEngine({bool force = false}) {
    if (force) WallpaperEngineLibrary.forgetDiscovery();
    final library = weLibrary();
    weFound = library != null;
    if (library == null) {
      if (weWallpapers.isEmpty && weCurrentFile == null) return;
      weWallpapers = const [];
      weCurrentFile = null;
      notifyListeners();
      return;
    }
    if (force) library.forgetScan();
    // One parse of config.json feeds both the list (which puts the current
    // wallpaper first) and the "currently applied" label.
    final current = library.currentFile();
    weCurrentFile = current;
    weWallpapers = library.wallpapers(currentFile: current);
    notifyListeners();
  }

  /// Adopts [wallpaper] as the app background: a video wallpaper is played
  /// where it lies, a web wallpaper's page is run in place, a scene package is
  /// drawn in place by the built-in renderer, a picture is copied as it is, and
  /// everything else contributes the artwork the package reader (or the
  /// author's preview) could turn up.
  ///
  /// Returns false when nothing usable could be read.
  Future<bool> useWallpaperEngine(WallpaperEngineWallpaper wallpaper) async {
    final library = weLibrary();
    if (library == null) return false;

    final label = '${wallpaper.title} · ${wallpaper.typeLabel}';
    final weId = weIdentity(wallpaper);
    // Already the background: do not copy the same picture again. The identity
    // decides, not the label — different wallpapers can share a title, and a
    // label match alone would quietly refuse to switch between them.
    if (isWeApplied(wallpaper)) {
      return true;
    }

    if (wallpaper.isVideo && LiveSurfaces.video) {
      final video = wallpaper.videoFile;
      if (video != null && File(video).existsSync()) {
        return _adoptInPlace(video, BackgroundSource.video,
            label: label, weId: weId);
      }
    }
    if (wallpaper.isWeb && LiveSurfaces.web) {
      final page = wallpaper.webFile;
      if (page != null && File(page).existsSync()) {
        return _adoptInPlace(page, BackgroundSource.web,
            label: label, weId: weId);
      }
    }
    if (wallpaper.isScene && LiveSurfaces.scene) {
      final pkg = wallpaper.scenePkg;
      if (pkg != null && File(pkg).existsSync()) {
        return _adoptInPlace(pkg, BackgroundSource.scene,
            label: label, weId: weId);
      }
    }

    final box = _stillBox();
    final still = await library.resolveStill(
      wallpaper,
      cacheDir: dataDir.path,
      boxWidth: box.$1,
      boxHeight: box.$2,
    );
    if (still == null) return false;
    if (!_adopt(still.path,
        fromWallpaperEngine: true, label: label, weId: weId)) {
      return false;
    }
    // The decoded frame stays on disk: it is keyed by its source, so switching
    // back to this wallpaper reuses it instead of decoding it again. The cache
    // is capped by [_pruneStills].
    if (still.isFrame || still.kind == 'scene-artwork') _pruneStills();
    return true;
  }

  /// Keeps the still cache bounded: the newest [_stillsKept] staged frames.
  /// They are multi-megabyte PNGs, and a cache that grows with every wallpaper
  /// ever tried is a leak with extra steps.
  static const _stillsKept = 8;

  void _pruneStills() {
    try {
      final staged = <File>[];
      for (final entry in dataDir.listSync()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last.toLowerCase();
        if (name.startsWith('we-frame-') || name.startsWith('we-scene-')) {
          staged.add(entry);
        }
      }
      if (staged.length <= _stillsKept) return;
      staged.sort((a, b) =>
          b.statSync().modified.compareTo(a.statSync().modified));
      for (final file in staged.skip(_stillsKept)) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  /// Adopts [source] as the background: the file is copied into the data dir,
  /// replacing any previous copy. Returns false when it cannot be read.
  bool setBackgroundFrom(String source) =>
      _adopt(source, fromWallpaperEngine: false);

  /// Adopts a video, a page or a scene package where it lies, without copying:
  /// Wallpaper Engine videos are far too large for the profile folder, and a
  /// page or a scene needs the files next to it.
  bool _adoptInPlace(String source, BackgroundSource kind,
      {required String label, required String weId}) {
    try {
      if (!File(source).existsSync()) return false;
      _deleteBackgroundCopies();
      backgroundPath = source;
      backgroundSource = kind;
      backgroundIsWallpaperEngine = true;
      backgroundWeId = weId;
      backgroundLabel = label;
      // A live wallpaper just came in mid-run: its gate (the fullscreen probe
      // half of it) starts here rather than waiting for the next launch.
      WallpaperGate.start();
      notifyListeners();
      _save();
      return true;
    } catch (_) {
      return false;
    }
  }

  void clearBackground() {
    if (backgroundPath == null) {
      if (backgroundIsWallpaperEngine || backgroundLabel != null) {
        backgroundIsWallpaperEngine = false;
        backgroundWeId = null;
        backgroundLabel = null;
        backgroundSource = BackgroundSource.image;
        _save();
      }
      return;
    }
    backgroundPath = null;
    backgroundSource = BackgroundSource.image;
    backgroundIsWallpaperEngine = false;
    backgroundWeId = null;
    backgroundLabel = null;
    notifyListeners();
    _deleteBackgroundCopies();
    _save();
  }

  /// One decoded frame is worth rendering at the window's own size; clamp it
  /// so a tiny window still gets a crisp frame and a huge one stays sane.
  (int, int) _stillBox() {
    var width = 1920;
    var height = 1080;
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final size = views.first.physicalSize;
        if (size.width >= 320 && size.height >= 200) {
          width = size.width.round();
          height = size.height.round();
        }
      }
    } catch (_) {
      // No view yet (early startup) — the default box is fine.
    }
    const maxSide = 2560;
    final longest = width > height ? width : height;
    if (longest > maxSide) {
      final scale = maxSide / longest;
      width = (width * scale).round();
      height = (height * scale).round();
    }
    return (width.clamp(1280, maxSide), height.clamp(720, maxSide));
  }

  bool _adopt(String source,
      {required bool fromWallpaperEngine, String? label, String? weId}) {
    try {
      final src = File(source);
      if (!src.existsSync()) return false;
      dataDir.createSync(recursive: true);
      final copy = File('${dataDir.path}\\$_backgroundPrefix'
          '${DateTime.now().millisecondsSinceEpoch}${_extension(source)}');
      // A native copy: the bytes never pass through the Dart heap, so adopting
      // a multi-megabyte wallpaper does not allocate it twice and hand the GC
      // megabytes of garbage at the exact moment the UI is busy swapping it in.
      src.copySync(copy.path);
      // Only now is the old copy expendable: a copy that failed above left the
      // previous background in place.
      _deleteBackgroundCopies(keep: copy.path);
      backgroundPath = copy.path;
      backgroundSource = BackgroundSource.image;
      backgroundIsWallpaperEngine = fromWallpaperEngine;
      backgroundWeId = fromWallpaperEngine ? weId : null;
      backgroundLabel = label;
      notifyListeners();
      _save();
      return true;
    } catch (_) {
      return false;
    }
  }

  void setImmersiveOnLaunch(bool value) {
    if (value == immersiveOnLaunch) return;
    immersiveOnLaunch = value;
    notifyListeners();
    _save();
  }

  void setImmersiveTaskbarBlend(bool value) {
    if (value == immersiveTaskbarBlend) return;
    immersiveTaskbarBlend = value;
    notifyListeners();
    _save();
  }

  /// Flips the auto-start preference and brings the scheduled task with it,
  /// so the switch applies the moment it moves. Returns false — leaving
  /// everything as it was — when Windows refuses the change (the task's
  /// highest run level needs the elevation the runner itself carries).
  /// Under a data-dir override (the tests) the machine is never touched and
  /// the preference alone flips.
  Future<bool> setLaunchOnStartup(bool value) async {
    if (value == launchOnStartup) return true;
    if (_dataDirOverride != null || await AutoStart.setEnabled(value)) {
      launchOnStartup = value;
      _storedLaunchOnStartup = true;
      notifyListeners();
      _save();
      return true;
    }
    return false;
  }

  /// Makes the task agree with [launchOnStartup]: an enabled preference
  /// re-registers it (refreshing the path after a move), a disabled one
  /// removes a leftover task. On the preference's first sighting — the table
  /// never said anything — the machine's actual state is adopted instead, so
  /// the installer's optional auto-start task survives its first launch
  /// rather than being undone by a default.
  Future<void> _syncAutoStart() async {
    try {
      if (!_storedLaunchOnStartup && await AutoStart.exists()) {
        launchOnStartup = true;
        _storedLaunchOnStartup = true;
        _save();
        notifyListeners();
      }
      if (launchOnStartup) {
        await AutoStart.setEnabled(true);
      } else if (await AutoStart.exists()) {
        await AutoStart.setEnabled(false);
      }
    } catch (_) {}
  }

  void setUsageSensorMode(int mode) {
    if (mode == usageSensorMode) return;
    usageSensorMode = mode;
    notifyListeners();
    _save();
  }

  /// Switches the collection rate of the device history. A value outside
  /// [sampleIntervalChoices] is refused here rather than clamped: the switch
  /// only offers the choices, and a stored value this build does not know
  /// reads back as the default at load.
  void setSampleInterval(int seconds) {
    if (!sampleIntervalChoices.contains(seconds) ||
        seconds == sampleIntervalSeconds) {
      return;
    }
    sampleIntervalSeconds = seconds;
    notifyListeners();
    _save();
  }

  void setSceneFps(int fps) {
    if (!sceneFpsChoices.contains(fps) || fps == sceneFps) return;
    sceneFps = fps;
    notifyListeners();
    _save();
  }

  /// Switches the low-power profile: null hands the decision back to the
  /// battery, true and false are the user's own word.
  void setLowPower(bool? value) {
    if (value == lowPower) return;
    lowPower = value;
    _syncEconomy();
    notifyListeners();
    _save();
  }

  /// The shell's report of whether this machine has a battery. Not persisted —
  /// it is a fact about the machine, not a preference — and only a nudge to
  /// [lowPower] when the user never said anything.
  void setHandheld(bool value) {
    if (value == handheld) return;
    handheld = value;
    _syncEconomy();
    notifyListeners();
  }

  /// Publishes the profile's verdict to the leaves that follow it (see
  /// [AppPower]).
  void _syncEconomy() => AppPower.economy.value = lowPowerOn;

  void setBackgroundDim(double value) {
    final next = value.clamp(0.0, 0.9);
    if (next == backgroundDim) return;
    backgroundDim = next;
    notifyListeners();
    _saveDebounced();
  }

  void setBackgroundBlur(double value) {
    final next = value.clamp(0.0, 24.0);
    if (next == backgroundBlur) return;
    backgroundBlur = next;
    notifyListeners();
    _saveDebounced();
  }

  void setBackgroundFit(BackgroundFit value) {
    if (value == backgroundFit) return;
    backgroundFit = value;
    notifyListeners();
    _save();
  }

  /// Keeps the source extension (a .jpg stays a .jpg — the decoder needs it),
  /// and falls back to .png for anything unusual.
  static String _extension(String path) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final dot = path.lastIndexOf('.');
    if (dot <= slash) return '.png';
    final ext = path.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext) ? ext : '.png';
  }

  void _deleteBackgroundCopies({String? keep}) {
    if (!dataDir.existsSync()) return;
    final kept = keep?.toLowerCase();
    try {
      for (final entry in dataDir.listSync()) {
        final name = entry.uri.pathSegments.last.toLowerCase();
        if (entry is File &&
            name.startsWith(_backgroundPrefix) &&
            entry.path.toLowerCase() != kept) {
          entry.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// Sliders fire on every pointer move; the table only needs the final value.
  void _saveDebounced() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), _save);
  }

  /// Writes a pending debounced value immediately (used on app exit).
  void saveNow() {
    if (_saveTimer != null) _save();
  }

  /// Flushes every setting into the `config` table.
  ///
  /// All of them, every time, rather than tracking which one moved: seventeen
  /// upserts in one transaction cost less than the bookkeeping would, and a
  /// setting that is assigned directly — a field rather than a setter, as the
  /// tests and the load path do — cannot be forgotten. A row whose value did
  /// not actually change keeps its `update_time`, so the flush leaves no trace
  /// on the settings it did not touch.
  void _save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_closed) return;
    try {
      final config = _store();
      config.writeAll(() {
        final isCopy = backgroundSource == BackgroundSource.image;
        final name =
            isCopy ? backgroundPath?.split(RegExp(r'[\\/]')).last : null;
        config.write(Settings.palette, palette);
        config.write(Settings.immersiveOnLaunch, immersiveOnLaunch);
        config.write(Settings.launchOnStartup, launchOnStartup);
        config.write(Settings.taskbarBlend, immersiveTaskbarBlend);
        config.write(Settings.usageMode, usageSensorMode);
        config.write(Settings.sampleSeconds, sampleIntervalSeconds);
        config.write(Settings.sceneFps, sceneFps);
        // The low-power profile is three-valued, and the third value — "the
        // user never chose" — is a missing row rather than one holding a
        // falsey stand-in.
        final lowPower = this.lowPower;
        if (lowPower == null) {
          config.remove(Settings.lowPower.key);
        } else {
          config.write(Settings.lowPower, lowPower);
        }
        _writeText(Settings.backgroundImage, name);
        config.write(Settings.backgroundKind, backgroundSource);
        _writeText(Settings.backgroundSource, isCopy ? null : backgroundPath);
        config.write(Settings.backgroundDim, backgroundDim);
        config.write(Settings.backgroundBlur, backgroundBlur);
        config.write(Settings.backgroundFit, backgroundFit);
        config.write(
            Settings.backgroundFromWe, backgroundIsWallpaperEngine);
        _writeText(Settings.backgroundWeId, backgroundWeId);
        _writeText(Settings.backgroundWeLabel, backgroundLabel);
      });
    } catch (_) {}
  }

  /// A text setting holds either a value or no row at all: the empty string was
  /// never a meaningful path, wallpaper id or label here, and "no row" is what
  /// the reader looks for.
  void _writeText(SettingSpec spec, String? value) {
    final config = _config!;
    if (value == null || value.isEmpty) {
      config.remove(spec.key);
    } else {
      config.write(spec, value);
    }
  }

  @override
  void dispose() {
    // Idempotent: the database goes with the provider, and a caller that
    // releases its settings early — a test, or a screen torn down by hand —
    // must not turn a second release into an error.
    if (_closed) return;
    _closed = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    _db?.close();
    _db = null;
    _config = null;
    super.dispose();
  }
}
