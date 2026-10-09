import 'dart:io';

import 'win32_api.dart';

/// The coarse bucket an entry lands in, used by the grid's filter chips.
/// Anything not recognizably one of the others is an everyday app — a wrong
/// "应用" costs nothing, a wrong "游戏" hides a tool from its shelf.
enum AppCategory { app, game, dev, system }

class AppEntry {
  AppEntry({
    required this.name,
    required this.path,
    this.isSystem = false,
    this.isDev = false,
    this.hasDesktop = false,
    this.isGame = false,
    this.iconFile,
    this.category = AppCategory.app,
  });

  String name;
  String path;

  /// True for shortcuts that belong to Windows itself — Administrative Tools,
  /// Accessories, System Tools, PowerShell, File Explorer and friends — rather
  /// than to an app the user installed.
  final bool isSystem;

  /// True for developer tooling — Visual Studio's command prompts, the Windows
  /// Kits debuggers and so on — which would otherwise drown the everyday grid.
  final bool isDev;

  /// True when this app also has a shortcut on the desktop, i.e. it is one the
  /// user actually reaches for. Set while scanning.
  bool hasDesktop;

  /// True for entries that are not shortcuts at all but Steam's own installed
  /// games: their path is a `steam://rungameid` URL, their `iconFile` is cover
  /// art rather than an extracted icon, and the icon pipeline skips them.
  bool isGame;

  String? iconFile;

  /// The category the scan assigned. Games are recognized by the Start Menu
  /// folder they live in (launcher and publisher folders), so a game installed
  /// bare into the Programs root reads as an app — an honest miss beats a
  /// false hit.
  AppCategory category;
}

/// Scans Start Menu shortcuts (all users + current user) and launches them.
class ShellApps {
  ShellApps._();

  /// Start Menu folders holding Windows' own components. The shell localizes
  /// these folder names, so English and Chinese spellings are both listed.
  static const _systemFolders = {
    'accessibility', 'ease of access', '轻松使用', '辅助功能', '辅助工具', '轻松访问',
    'accessories', 'windows accessories', '附件', 'windows 附件',
    'administrative tools', 'windows administrative tools', '管理工具', 'windows 管理工具',
    'maintenance', '维护',
    'system tools', '系统工具',
    'windows system', 'windows 系统',
    'windows powershell',
    'windows ease of access', 'windows 轻松使用',
  };

  /// Windows components that sit at the Programs root on some systems instead
  /// of inside one of the folders above.
  static const _systemNames = {
    'file explorer', '文件资源管理器',
    'microsoft edge',
    'administrative tools', '管理工具',
    'windows update', 'windows 更新',
    'windows security', 'windows 安全中心',
    'windows fax and scan', 'windows 传真和扫描',
    'windows media player', 'windows media player legacy',
    'remote desktop connection', '远程桌面连接',
    'character map', '字符映射表',
    'steps recorder', '步骤记录器',
    'quick assist', '快速助手',
    'snipping tool', '截图工具', '剪取工具',
    'internet explorer',
  };

  /// Start Menu folders that never hold an app shortcut worth listing.
  static const _startMenuSkip = {'startmenu', 'startup', '启动'};

  /// Start Menu folders holding developer tooling.
  static const _devFolders = {
    'visual studio tools', 'windows kits',
  };

  /// Start Menu folders that hold games — the ones game launchers and
  /// publishers create. Both spellings, the way [_systemFolders] does; the
  /// shell localizes folder names, so a Chinese Windows writes 腾讯游戏 where
  /// an English one writes Tencent Games.
  static const _gameFolders = {
    'steam', 'steam 游戏文件夹',
    'epic games', 'epic games launcher', 'epic',
    'riot games',
    'origin', 'ea games', 'electronic arts',
    'ubisoft', 'ubisoft connect',
    'gog.com', 'gog galaxy',
    'battle.net', 'blizzard entertainment', '暴雪娱乐',
    '腾讯游戏', 'tencent games', 'wegame', 'we games',
    '网易游戏', 'netease games',
    '米哈游', 'mihoyo', 'hoyoverse',
    'xbox games',
    'games', '游戏',
  };

  /// Visual Studio itself, its installer and Blend — spelled out so that
  /// "Visual Studio Code", a normal app, never matches.
  static final _devIdePattern =
      RegExp(r'^visual studio( (installer|\d{4}))?$');

  static const _devNames = {
    'blend for visual studio',
    'debuggable package manager',
    'windows app cert kit',
  };

  static bool _isSystemEntry(String name, List<String> folders) {
    if (folders.any(_systemFolders.contains)) return true;
    final n = name.trim().toLowerCase();
    return _systemNames.contains(n) || n.startsWith('windows powershell');
  }

  static bool _isDevEntry(String name, List<String> folders) {
    if (folders.any(_devFolders.contains)) return true;
    final n = name.trim().toLowerCase();
    return _devNames.contains(n) ||
        _devIdePattern.hasMatch(n) ||
        n.startsWith('developer command prompt') ||
        n.startsWith('developer powershell');
  }

  /// The launcher clients' own shortcuts — they sit in the same folder as
  /// their games but open a store/library, so they read as apps.
  static const _launcherNames = {
    'steam', 'steam support center',
    'epic games launcher',
    'wegame',
    'ubisoft connect', 'ubisoft connect launcher',
    'gog galaxy', 'gog.com',
    'battle.net',
    'origin',
  };

  /// Games are known by their company: the launcher/publisher folder the
  /// shortcut sits in. The [folders] are the walk's lowercased path segments.
  /// The folder's own housekeeping — the client, its support center,
  /// uninstallers, Wallpaper Engine riding in Steam's folder — is not a game.
  static bool _isGameEntry(String name, List<String> folders) {
    if (!folders.any(_gameFolders.contains)) return false;
    final n = name.trim().toLowerCase();
    if (n.contains('卸载') || n.contains('uninstall')) return false;
    if (n.startsWith('wallpaper engine')) return false;
    return !_launcherNames.contains(n);
  }

  /// System and dev flags decide first — a tool inside a "Games" folder is
  /// still a tool — then the game folders, and everything else is an app.
  static AppCategory _categorize(String name, List<String> folders) {
    if (_isSystemEntry(name, folders)) return AppCategory.system;
    if (_isDevEntry(name, folders)) return AppCategory.dev;
    if (_isGameEntry(name, folders)) return AppCategory.game;
    return AppCategory.app;
  }

  /// Returns deduplicated .lnk/.url entries sorted by name, each flagged with
  /// the category it belongs to and whether the desktop also has a shortcut
  /// for it. Runs on a background isolate.
  static List<AppEntry> scan() {
    final dirs = <String>[];
    final allUsers = Platform.environment['ALLUSERSPROFILE'];
    final appData = Platform.environment['APPDATA'];
    if (allUsers != null) {
      dirs.add('$allUsers\\Microsoft\\Windows\\Start Menu\\Programs');
    }
    if (appData != null) {
      // The user's own folder wins dedup conflicts — scan it first.
      dirs.insert(0, '$appData\\Microsoft\\Windows\\Start Menu\\Programs');
    }

    final seen = <String>{};
    final entries = <AppEntry>[];
    for (final dir in dirs) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final (file, folders) in _walk(root, const [], _startMenuSkip)) {
        final name = _baseName(file);
        final base = name.substring(0, name.length - 4);
        final key = base.toLowerCase();
        if (!seen.add(key)) continue;
        if (base.isEmpty || base.startsWith('.')) continue;
        entries.add(AppEntry(
          name: base,
          path: file.path,
          isSystem: _isSystemEntry(base, folders),
          isDev: _isDevEntry(base, folders),
          category: _categorize(base, folders),
        ));
      }
    }
    _applyDesktop(entries);
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  /// Marks the Start Menu entries the desktop also holds and appends the
  /// shortcuts that exist only on the desktop, so the grid can lead with what
  /// the user actually keeps in front of them. Folders on the desktop count
  /// too — the shortcuts tucked into them are just as much the user's.
  static void _applyDesktop(List<AppEntry> entries) {
    final dirs = [userDesktopPath(), publicDesktopPath()];
    final byKey = <String, AppEntry>{};
    for (final entry in entries) {
      byKey.putIfAbsent(_nameKey(entry.name), () => entry);
    }
    for (final dir in dirs) {
      if (dir == null) continue;
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final (file, _) in _walk(root, const [], const {})) {
        final name = _baseName(file);
        final base = name.substring(0, name.length - 4);
        if (base.isEmpty || base.startsWith('.')) continue;
        final key = _nameKey(base);
        final known = byKey[key];
        if (known != null) {
          known.hasDesktop = true;
          continue;
        }
        final entry = AppEntry(
          name: base,
          path: file.path,
          isSystem: _isSystemEntry(base, const []),
          isDev: _isDevEntry(base, const []),
          hasDesktop: true,
        );byKey[key] = entry;
        entries.add(entry);
      }
    }
  }

  /// Comparison key for "the same app" across Start Menu and desktop
  /// shortcuts: case-insensitive, without Windows' " - 快捷方式" suffix or a
  /// trailing ".exe" some shortcuts keep.
  static String _nameKey(String base) {
    var key = base.trim().toLowerCase();
    for (final suffix in const [' - 快捷方式', ' - shortcut']) {
      if (key.endsWith(suffix)) {
        key = key.substring(0, key.length - suffix.length).trim();
      }
    }
    if (key.endsWith('.exe')) key = key.substring(0, key.length - 4).trim();
    return key;
  }

  static Iterable<(File, List<String>)> _walk(
      Directory dir, List<String> folders, Set<String> skip) sync* {
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final child in children) {
      final name = _baseName(child).toLowerCase();
      if (child is Directory) {
        if (skip.contains(name)) continue;
        yield* _walk(child, [...folders, name], skip);
      } else if (child is File) {
        if (name.endsWith('.lnk') || name.endsWith('.url')) yield (child, folders);
      }
    }
  }

  /// Basename of an entry's path — not `uri.pathSegments.last`, whose last
  /// segment is empty for directories (their URI ends with a slash).
  static String _baseName(FileSystemEntity entity) {
    final path = entity.path.replaceAll('/', '\\');
    return path.substring(path.lastIndexOf('\\') + 1);
  }

  /// Launches via the shell (resolves .lnk targets, working dirs, UAC).
  static bool launch(String path) => shellExecuteOpen(path);

  /// Opens Explorer with the shortcut selected. Returns false when the shell
  /// refused to start.
  ///
  /// The `/select,"…"` text goes through the shell verbatim: Explorer parses
  /// its own command line, so a runtime that re-quotes arguments (Dart's
  /// `Process.start` escapes the quotes) leaves it with a path it cannot
  /// resolve, and it lands in some default folder instead.
  static bool openLocation(String path) =>
      shellExecuteOpen('explorer.exe', parameters: '/select,"$path"');
}
