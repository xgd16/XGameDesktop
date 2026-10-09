import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bgra_png.dart';
import 'win32_api.dart';

/// Preferred size requested from the shell. The grid draws icons at 44 logical
/// px, which is 66 physical px on a 150% display, so 48 px is not enough to
/// stay crisp; 96 px covers that with headroom.
const int kIconRequestSize = 96;

/// What Windows' desktop draws, and the size [kIconRequestSize] falls back to
/// for icons that cannot be rendered larger (see [_loadBestPixels]).
const int _desktopIconSize = 48;

/// Part of the cache key: bump it and every icon is re-rendered instead of
/// being served from PNGs written by an older pipeline.
const int _cacheVersion = 6;

/// COM is per-thread; each isolate that extracts icons sets it up once.
bool _comReady = false;

/// Extracts an app icon to a PNG file and returns its path, or null when
/// extraction fails. Runs on a background isolate; results are cached on
/// disk keyed by (path, size, pipeline version) so startup stays fast.
String? extractIconToCache(String sourcePath, String cacheDir, int size) {
  _ensureCom();
  final key = _fnv1a64('v$_cacheVersion|${sourcePath.toLowerCase()}|$size');
  final cachePath = '$cacheDir\\$key.png';
  if (File(cachePath).existsSync()) return cachePath;

  final pixels = _loadBestPixels(sourcePath, size);
  if (pixels == null) return null;
  final png = encodeBgraPng(pixels);
  if (png == null) return null;
  // Once per worker isolate, not once per icon.
  if (!_cacheDirReady) {
    Directory(cacheDir).createSync(recursive: true);
    _cacheDirReady = true;
  }
  // No flush: these are cache files, and an fsync per icon is the kind of
  // durability a regenerable PNG does not need.
  File(cachePath).writeAsBytesSync(png);
  return cachePath;
}

bool _cacheDirReady = false;

void _ensureCom() {
  if (_comReady) return;
  _comReady = true;
  coInitialize();
}

/// Picks the largest frame the shell renders faithfully.
///
/// For applications that ship no large icon frame — 7-Zip and other older
/// tools — a big request comes back hollow: a hairline outline around a
/// shrunken logo, which on the dark grid reads as broken rather than sharp.
/// Such a result is detected by its ink coverage and rejected in favour of the
/// 48 px frame Windows itself draws on the desktop.
IconPixels? _loadBestPixels(String path, int size) {
  final large = _loadPixels(path, size);
  if (large == null) return _loadPixels(path, _desktopIconSize);
  if (size <= _desktopIconSize) return large;
  // The comparison below prefers the small frame only when it carries
  // substantially more ink: `ink(large) >= ink(small) * 0.6`, and a ratio tops
  // out at 1.0. So past 0.6 the large frame cannot lose, and the whole second
  // extraction — another run of the shell-image pipeline — is skipped.
  final largeInk = _inkRatio(large);
  if (largeInk >= 0.6) return large;
  final small = _loadPixels(path, _desktopIconSize);
  if (small == null) return large;
  return largeInk >= _inkRatio(small) * 0.6 ? large : small;
}

/// Fraction of pixels carrying any ink. Transparent-black — the shell's empty
/// canvas — counts as nothing.
double _inkRatio(IconPixels px) {
  var ink = 0;
  for (final p in px.bgra) {
    if (((p >> 24) & 0xFF) > 8 || (p & 0xFFFFFF) != 0) ink++;
  }
  return ink / (px.width * px.height);
}

IconPixels? _loadPixels(String path, int size) {
  // The shell's own pipeline first: it follows .lnk/.url targets, honours
  // per-app icon overrides and hands back the icon's real frame rather than a
  // 32 px system-image-list bitmap.
  final bitmap = shellItemImageHandle(path, size);
  if (bitmap != 0) {
    try {
      final px = hBitmapToPixels(bitmap);
      if (px != null && !_isBlank(px.bgra)) return px;
    } finally {
      deleteGdiObject(bitmap);
    }
  }

  // Fallbacks for the shortcuts the shell item pipeline cannot route.
  final lower = path.toLowerCase();
  if (!lower.endsWith('.lnk') && !lower.endsWith('.url')) {
    final hicon = extractIconHandle(path, size);
    if (hicon != 0) {
      try {
        final px = hiconToBgra(hicon);
        if (px != null) return px;
      } finally {
        destroyIcon(hicon);
      }
    }
  }
  final shellIcon = shGetFileIcon(path);
  if (shellIcon == null) return null;
  try {
    return hiconToBgra(shellIcon.$1);
  } finally {
    destroyIcon(shellIcon.$1);
  }
}

/// An all-zero bitmap means the shell handed back a surface with neither
/// colour nor alpha; encoding it would paint a black square.
bool _isBlank(Uint32List bgra) {
  for (final p in bgra) {
    if (p != 0) return false;
  }
  return true;
}

int _fnv1a64(String input) {
  var hash = 0xcbf29ce484222325;
  for (final code in utf8.encode(input)) {
    hash ^= code;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash;
}
