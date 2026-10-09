// ignore_for_file: avoid_print
// Dev-only: verify volume enumeration. Run: dart run tool/vol_probe.dart
import 'package:xgame_desktop/native/volumes.dart';

void main() {
  for (final v in listFixedVolumes()) {
    print('${v.letter} [${v.label}] total=${(v.totalBytes / 1073741824).toStringAsFixed(1)}GB used=${(v.usedBytes / 1073741824).toStringAsFixed(1)}GB (${v.usedPct.toStringAsFixed(0)}%)');
  }
}
