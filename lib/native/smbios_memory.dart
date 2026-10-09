import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'win32_api.dart';

class MemoryModuleInfo {
  MemoryModuleInfo({
    required this.sizeMb,
    required this.speedMts,
    required this.configuredSpeedMts,
    required this.typeName,
    required this.manufacturer,
    required this.partNumber,
  });

  final int sizeMb; // 0 = empty slot
  final int speedMts; // maximum capable speed, MT/s
  final int configuredSpeedMts; // current configured speed, MT/s
  final String typeName; // 'DDR4', 'DDR5', …
  final String manufacturer;
  final String partNumber;
}

/// Reads RAM module info straight from the SMBIOS table (Type 17,
/// Memory Device) via GetSystemFirmwareTable — static data, read once.
List<MemoryModuleInfo> readMemoryModules() {
  final provider = 0x52534D42; // 'RSMB'
  final size = getSystemFirmwareTable(provider, 0, nullptr, 0);
  if (size == 0) return const [];
  final buf = calloc<Uint8>(size);
  try {
    if (getSystemFirmwareTable(provider, 0, buf, size) != size) {
      return const [];
    }
    // RawSMBIOSData header: UsedCalling(1) Major(1) Minor(1) DmiRev(1)
    // Length(4) then the table bytes.
    final data = ByteData.sublistView(buf.asTypedList(size));
    final tableLen = data.getUint32(4, Endian.little);
    final table = Uint8List.sublistView(buf.asTypedList(size), 8,
        8 + tableLen);
    return _parseType17(table);
  } catch (_) {
    return const [];
  } finally {
    calloc.free(buf);
  }
}

List<MemoryModuleInfo> _parseType17(Uint8List table) {
  final modules = <MemoryModuleInfo>[];
  var i = 0;
  while (i + 4 <= table.length) {
    final type = table[i];
    final length = table[i + 1];

    if (type == 127 && length == 4) break; // end-of-table marker
    if (length < 4) break;

    if (type == 17 && length >= 0x1B) {
      // Type 17 offsets from the structure start: 0Ch size, 12h memory type,
      // 15h speed (MT/s), 17h manufacturer string, 1Ah part-number string,
      // 20h configured clock speed (SMBIOS 2.6+). String index 0 means
      // "no string" and must not be used to index the string table.
      final bd = ByteData.sublistView(table, i, i + length);
      final sizeKb = bd.getUint16(0x0C, Endian.little);
      final typeByte = table[i + 0x12];
      final speed = bd.getUint16(0x15, Endian.little);
      var configured = 0;
      if (length >= 0x22) {
        configured = bd.getUint16(0x20, Endian.little);
      }
      final strings = _readStrings(table, i + length);
      // strings[0] is a null placeholder — string number N is strings[N].
      String s(int index) =>
          index <= 0 || index >= strings.length ? '' : (strings[index] ?? '');

      modules.add(MemoryModuleInfo(
        sizeMb: _decodeSizeMb(sizeKb),
        speedMts: _plausibleSpeed(speed),
        configuredSpeedMts: _plausibleSpeed(configured),
        typeName: _memoryTypeName(typeByte),
        manufacturer: s(bd.getUint8(0x17)),
        partNumber: s(bd.getUint8(0x1A)),
      ));
    }

    // Skip past data + string block (double NUL terminated).
    var j = i + length;
    var stringsEnded = false;
    while (j + 1 < table.length) {
      if (table[j] == 0 && table[j + 1] == 0) {
        stringsEnded = true;
        j += 2;
        break;
      }
      j++;
    }
    if (!stringsEnded) break;
    i = j;
  }
  return modules;
}

int _decodeSizeMb(int kb) {
  if (kb == 0) return 0;
  if (kb & 0x8000 != 0) return (kb & 0x7FFF) ~/ 1024; // KB granularity
  return kb; // MB
}

// Filter sentinel values (0xFFFF / 0 = unknown).
int _plausibleSpeed(int v) => (v == 0 || v == 0xFFFF) ? 0 : v;

String _memoryTypeName(int t) => switch (t) {
      0x12 => 'DDR',
      0x13 => 'DDR2',
      0x18 => 'DDR3',
      0x1A => 'DDR4',
      0x1B => 'LPDDR3',
      0x1C => 'LPDDR2',
      0x1D => 'LPDDR4',
      0x22 => 'DDR5',
      0x23 => 'LPDDR5',
      _ => '',
    };

List<String?> _readStrings(Uint8List table, int start) {
  final strings = <String?>[null]; // 1-based; index 0 = "not set"
  final sb = <int>[];
  var i = start;
  while (i < table.length) {
    final b = table[i++];
    if (b == 0) {
      strings.add(sb.isEmpty ? null : String.fromCharCodes(sb));
      sb.clear();
      // A single NUL right away means the empty-string terminator only if
      // the next byte is also NUL — handled by the walker above.
      if (i < table.length && table[i] == 0) break;
      continue;
    }
    sb.add(b);
  }
  return strings;
}

/// Human summary for the UI, e.g. "DDR4 · 3200 MT/s · 2 条".
String memoryModulesSummary(List<MemoryModuleInfo> modules) {
  final populated = modules.where((m) => m.sizeMb > 0).toList();
  if (populated.isEmpty) return '';

  final speeds = populated
      .map((m) =>
          m.configuredSpeedMts != 0 ? m.configuredSpeedMts : m.speedMts)
      .where((s) => s > 0)
      .toSet()
      .toList()
    ..sort();
  final speedText =
      speeds.isEmpty ? '' : speeds.length == 1 ? '${speeds.first} MT/s' : speeds.join(' / ');

  final types = populated.map((m) => m.typeName).where((t) => t.isNotEmpty).toSet();
  final typeText = types.isEmpty ? '' : types.first;

  final count = populated.length;
  final totalGb = populated.fold<int>(0, (sum, m) => sum + m.sizeMb) ~/ 1024;

  final parts = [
    if (typeText.isNotEmpty) typeText,
    if (speedText.isNotEmpty) speedText,
    '$count 条',
  ];
  final summary = parts.join(' · ');
  return totalGb > 0 ? summary : summary;
}
