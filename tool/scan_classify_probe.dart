// ignore_for_file: avoid_print
// Prints how ShellApps.scan classifies the real Start Menu and desktop on this
// machine:  dart run tool/scan_classify_probe.dart
import 'package:xgame_desktop/native/win32_api.dart';
import 'package:xgame_desktop/native/shell_apps.dart';

void main() {
  print('user desktop:   ${userDesktopPath()}');
  print('public desktop: ${publicDesktopPath()}');
  final apps = ShellApps.scan();
  final desktop = apps.where((a) => a.hasDesktop).toList();
  final hidden = apps
      .where((a) => !a.hasDesktop && !a.isDev && !a.isSystem)
      .toList();
  final dev = apps.where((a) => a.isDev).toList();
  final system = apps.where((a) => a.isSystem).toList();
  print('total=${apps.length} desktop=${desktop.length} '
      'hidden=${hidden.length} dev=${dev.length} system=${system.length}');

  void dump(String title, List<AppEntry> list, {bool showPath = false}) {
    print('\n-- $title (${list.length}) --');
    for (final a in list) {
      print('  ${a.name}${showPath ? '    <- ${a.path}' : ''}');
    }
  }

  dump('desktop', desktop, showPath: true);
  dump('dev', dev, showPath: true);
  dump('system', system);
  dump('hidden', hidden);
}
