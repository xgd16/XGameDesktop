import 'dart:io';

/// Per-user auto-start for an app that runs elevated.
///
/// The runner is requireAdministrator (windows/runner/CMakeLists.txt), and
/// Windows refuses to auto-elevate at sign-in: a Run-key entry would sit
/// there doing nothing, which is why the installer deletes such entries.
/// What works is a scheduled task at highest run level — registered once with
/// an admin token, silent at every logon after. The app itself always runs
/// elevated, so it can register and remove the task directly, with no extra
/// UAC prompt.
///
/// The task name and definition are the installer's
/// (tool/installer/XGameDesktop.nsi, the optional 开机自动启动 checkbox): both
/// sides manage the same task, so the uninstaller's deletion covers whatever
/// the app created, and re-running the installer's checkbox overwrites
/// cleanly.
class AutoStart {
  AutoStart._();

  /// Must match the installer's ${AppName} — one task, two managers.
  static const _taskName = 'XGameDesktop';

  /// The command the task runs: the executable, quoted — a path with spaces
  /// must arrive at the scheduler as one token.
  static String get _taskCommand => '"${Platform.resolvedExecutable}"';

  /// Whether the auto-start task exists (whatever it currently points at).
  static Future<bool> exists() async =>
      await _schtasks(['/query', '/tn', _taskName]) == 0;

  /// Registers the task, or removes it. False when Windows refused — the
  /// caller keeps the old state. Removing an absent task succeeds.
  static Future<bool> setEnabled(bool on) async {
    if (!on) {
      if (!await exists()) return true;
      return await _schtasks(['/delete', '/f', '/tn', _taskName]) == 0;
    }
    // /f overwrites, so re-registering after the executable moved also
    // refreshes the stored path.
    return await _schtasks([
      '/create',
      '/f',
      '/tn',
      _taskName,
      '/tr',
      _taskCommand,
      '/sc',
      'onlogon',
      '/rl',
      'highest',
    ]) == 0;
  }

  /// schtasks answers through its exit code; its output is localized noise.
  static Future<int> _schtasks(List<String> args) async {
    try {
      return (await Process.run('schtasks', args)).exitCode;
    } catch (_) {
      return -1;
    }
  }
}
