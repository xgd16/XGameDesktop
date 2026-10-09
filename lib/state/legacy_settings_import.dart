import 'dart:convert';
import 'dart:io';

import '../core/theme.dart';
import '../data/config_store.dart';
import 'settings_provider.dart';
import 'settings_spec.dart';

/// Copies a pre-SQLite `settings.json` into the `config` table.
///
/// That file was one JSON object, a key per setting, with no type recorded
/// anywhere: `palette` and `fit` were indices into a Dart enum, `dim` and
/// `blur` were numbers, `kind` was an enum's name. This runs once — on the
/// first launch that finds no database at all — and never again: from then on
/// the table is the only place settings come from, and the file is left on disk
/// untouched as a way back.
///
/// A value that is missing, of the wrong type, or out of range is simply not
/// imported; the loader then falls back to its default for that setting, which
/// is what the old reader did with the same input.
void importLegacySettings(ConfigStore config, File file) {
  final json = _readLegacyJson(file);
  if (json == null) return;

  // An index into PaletteId — stored by name now, so that reordering the enum
  // cannot repoint it.
  if (json['palette'] case final int index
      when index >= 0 && index < PaletteId.values.length) {
    config.write(Settings.palette, PaletteId.values[index]);
  }

  if (json['immersive'] case final bool value) {
    config.write(Settings.immersiveOnLaunch, value);
  }
  if (json['launchOnStartup'] case final bool value) {
    config.write(Settings.launchOnStartup, value);
  }
  if (json['taskbarBlend'] case final bool value) {
    config.write(Settings.taskbarBlend, value);
  }
  if (json['usageMode'] case final int value) {
    config.write(Settings.usageMode, value);
  }
  if (json['sceneFps'] case final int value) {
    config.write(Settings.sceneFps, value);
  }
  // Absent, or not a bool, meant "the user never chose" — and that is exactly
  // what a missing row means now.
  if (json['lowPower'] case final bool value) {
    config.write(Settings.lowPower, value);
  }

  // A picture was kept as a copy, named by its file name; a video, a page or a
  // scene package was referenced where it lies.
  if (json['background'] case final String value when value.isNotEmpty) {
    config.write(Settings.backgroundImage, value);
  }
  if (json['source'] case final String value when value.isNotEmpty) {
    config.write(Settings.backgroundSource, value);
  }
  if (json['kind'] case final String name) {
    for (final kind in BackgroundSource.values) {
      if (kind.name == name) config.write(Settings.backgroundKind, kind);
    }
  }
  if (json['fit'] case final int index
      when index >= 0 && index < BackgroundFit.values.length) {
    config.write(Settings.backgroundFit, BackgroundFit.values[index]);
  }
  if (json['dim'] case final num value) {
    config.write(Settings.backgroundDim, value.toDouble());
  }
  if (json['blur'] case final num value) {
    config.write(Settings.backgroundBlur, value.toDouble());
  }
  if (json['weSource'] case final bool value) {
    config.write(Settings.backgroundFromWe, value);
  }
  if (json['weId'] case final String value when value.isNotEmpty) {
    config.write(Settings.backgroundWeId, value);
  }
  if (json['weLabel'] case final String value when value.isNotEmpty) {
    config.write(Settings.backgroundWeLabel, value);
  }
}

/// The old settings object, or null when there is no file or it does not hold
/// one. Neither is worth failing a launch over.
Map<String, Object?>? _readLegacyJson(File file) {
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}
