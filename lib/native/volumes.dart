import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'win32_api.dart';

class VolumeInfo {
  VolumeInfo({
    required this.letter,
    required this.label,
    required this.totalBytes,
    required this.freeBytes,
  });

  final String letter; // e.g. 'C:'
  final String label; // volume label, '' when unnamed
  final int totalBytes;
  final int freeBytes;

  int get usedBytes => totalBytes > freeBytes ? totalBytes - freeBytes : 0;
  double get usedPct => totalBytes > 0 ? usedBytes / totalBytes * 100 : 0;
}

/// Enumerates fixed local volumes with their usage (via
/// GetDiskFreeSpaceExW). CD-ROM / network / removable drives are excluded.
List<VolumeInfo> listFixedVolumes() {
  final buf = calloc<Uint16>(512);
  final volumes = <VolumeInfo>[];
  try {
    final len = getLogicalDriveStrings(511, buf);
    if (len == 0 || len > 511) return volumes;
    final driveStrings =
        Uint16List.view(buf.asTypedList(len).buffer, 0, len).toList();
    // Null-separated "C:\", "D:\", ... terminated by an empty string.
    var start = 0;
    for (var i = 0; i < driveStrings.length; i++) {
      if (driveStrings[i] != 0) continue;
      if (i == start) break; // double NUL — end of list
      final drive = String.fromCharCodes(driveStrings.sublist(start, i));
      start = i + 1;

      if (getDriveType(drive) != driveTypeFixed) continue;
      final info = getVolumeInformation(drive);
      final space = getDiskFreeSpace(drive);
      if (space == null) continue;
      volumes.add(VolumeInfo(
        letter: drive.substring(0, 2),
        label: info.label,
        totalBytes: space.total,
        freeBytes: space.free,
      ));
    }
  } catch (_) {
    // Best effort — a missing drive list just hides the section.
  } finally {
    calloc.free(buf);
  }
  return volumes;
}

/// The same list with only the free space re-read.
///
/// A volume's letter, label and total size do not change while the app runs,
/// and reading them costs a drive-type check, a volume-information call with
/// five native allocations, and a full drive-string enumeration — per drive,
/// per call. The 1 Hz telemetry poll only needs [VolumeInfo.freeBytes].
List<VolumeInfo> refreshVolumeUsage(List<VolumeInfo> volumes) {
  final out = <VolumeInfo>[];
  for (final volume in volumes) {
    final space = getDiskFreeSpace('${volume.letter}\\');
    if (space == null) {
      // The drive went away; keep the last known numbers rather than dropping
      // the row, so an unplugged USB stick does not make the panel jump.
      out.add(volume);
      continue;
    }
    out.add(VolumeInfo(
      letter: volume.letter,
      label: volume.label,
      totalBytes: space.total,
      freeBytes: space.free,
    ));
  }
  return out;
}
