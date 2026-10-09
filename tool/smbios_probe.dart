// ignore_for_file: avoid_print
// Dev-only: verify SMBIOS Type 17 parsing. Run: dart run tool/smbios_probe.dart
import 'package:xgame_desktop/native/smbios_memory.dart';

void main() {
  final modules = readMemoryModules();
  for (final m in modules) {
    print('size=${m.sizeMb}MB speed=${m.speedMts} configured=${m.configuredSpeedMts} '
        'type=${m.typeName} vendor=${m.manufacturer} part=${m.partNumber}');
  }
  print('summary: ${memoryModulesSummary(modules)}');
}
