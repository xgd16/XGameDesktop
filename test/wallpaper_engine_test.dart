import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgame_desktop/native/wallpaper_engine.dart';

import 'pkg_fixture.dart';
import 'we_fixture.dart';

void main() {
  late SteamTree tree;
  late Directory cache;

  setUp(() {
    tree = SteamTree();
    cache = Directory.systemTemp.createTempSync('xg_we_cache');
  });

  tearDown(() {
    tree.dispose();
    try {
      cache.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('按 Steam 库定位安装：config.json 在应用目录里', () {
    final w = tree.project('090', type: 'web', file: 'index.html');
    tree.select('${w.path}\\index.html');
    final lib = WallpaperEngineLibrary.locate(roots: [tree.root.path]);
    expect(lib, isNotNull);
    expect(lib!.installDir, tree.weDir.path);
    expect(lib.configPath, tree.config.path);
  });

  test('没有安装时返回空', () {
    final empty = Directory.systemTemp.createTempSync('xg_no_we');
    addTearDown(() => empty.deleteSync(recursive: true));
    expect(WallpaperEngineLibrary.locate(roots: [empty.path]), isNull);
  });

  test('监视器选择：优先最后操作过的那个', () {
    final a = tree.project('100', type: 'scene', file: 'scene.json', createPrimary: false,
        extraFiles: {'scene.pkg': 'x'});
    final b = tree.project('200', type: 'web', file: 'index.html');
    tree.selectAll(
      {'Monitor0': '${a.path}\\scene.pkg', 'Monitor1': '${b.path}\\index.html'},
      lastSelected: 'Monitor1',
    );
    expect(tree.library.currentFile(), '${b.path}\\index.html');

    // Without a last-used hint the primary monitor wins.
    tree.selectAll(
      {'Monitor0': '${a.path}\\scene.pkg', 'Monitor1': '${b.path}\\index.html'},
    );
    expect(tree.library.currentFile(), '${a.path}\\scene.pkg');
  });

  test('只有 Monitor2 时就用它', () {
    final w = tree.project('300', type: 'web', file: 'index.html');
    tree.select('${w.path}\\index.html', monitor: 'Monitor2');
    expect(tree.library.currentFile(), '${w.path}\\index.html');
  });

  test('用当前 Windows 用户名下的配置', () {
    final w = tree.project('310', type: 'web', file: 'index.html');
    // A second user object exists but only ours must be read.
    final config = {
      'someone-else': {
        'general': {
          'wallpaperconfig': {
            'selectedwallpapers': {
              'Monitor0': {'file': r'C:\elsewhere\other.html'},
            },
          },
        },
      },
      Platform.environment['USERNAME']: {
        'general': {
          'wallpaperconfig': {
            'selectedwallpapers': {
              'Monitor0': {'file': '${w.path}\\index.html'},
            },
          },
        },
      },
    };
    tree.config.writeAsStringSync(jsonEncode(config));
    expect(tree.library.currentFile(), '${w.path}\\index.html');
  });

  test('播放列表模式下退回最近一条记录', () {
    final old = tree.project('320', type: 'scene', file: 'scene.json', createPrimary: false,
        extraFiles: {'scene.pkg': 'x'});
    tree.config.writeAsStringSync(jsonEncode({
      'tester': {
        'general': {
          'wallpaperconfig': <String, Object?>{},
          'wallpaperconfigrecent': [
            {
              'title': 'Old one',
              'config': {
                'selectedwallpapers': {
                  'Monitor0': {'file': '${old.path}\\scene.pkg'},
                },
              },
            },
          ],
        },
      },
    }));
    expect(tree.library.currentFile(), '${old.path}\\scene.pkg');
  });

  test('配置损坏或没有选中项时返回空', () {
    tree.config.writeAsStringSync('{ this is not json');
    expect(tree.library.currentFile(), isNull);

    tree.config.writeAsStringSync(jsonEncode({
      'tester': {'general': <String, Object?>{}},
    }));
    expect(tree.library.currentFile(), isNull);
    expect(tree.library.current(), isNull);
  });

  test('解析 project.json：标题、类型与预览', () {
    final dir = tree.project('400',
        type: 'scene',
        file: 'scene.json',
        createPrimary: false,
        preview: 'preview.jpg',
        title: 'Into The Woods',
        extraFiles: {'scene.pkg': 'pkg-bytes'});
    tree.select('${dir.path}\\scene.pkg');

    final w = tree.library.current()!;
    expect(w.title, 'Into The Woods');
    expect(w.type, 'scene');
    expect(w.typeLabel, '场景');
    expect(w.projectDir, dir.path);
    expect(w.previewPath, '${dir.path}\\preview.jpg');
    // project.json names scene.json, which is not on disk — the file the
    // config actually plays is the one to use.
    expect(w.primaryFile, '${dir.path}\\scene.pkg');
    expect(w.isVideo, isFalse);
    expect(w.isImage, isFalse);
  });

  test('没有 title 的项目用目录名兜底', () {
    final dir = tree.project('410', type: 'web', file: 'index.html');
    expect(WallpaperEngineLibrary.describe('${dir.path}\\index.html')!.title, '410');
  });

  test('视频项目给出可解码的文件', () {
    final dir = tree.project('500', type: 'video', file: 'clip.mp4',
        preview: 'preview.gif');
    final w = WallpaperEngineLibrary.describe('${dir.path}\\clip.mp4')!;
    expect(w.type, 'video');
    expect(w.typeLabel, '视频');
    expect(w.isVideo, isTrue);
    expect(w.videoFile, '${dir.path}\\clip.mp4');
    expect(w.previewPath, '${dir.path}\\preview.gif');
  });

  test('大写的 Video 类型同样识别', () {
    final dir = tree.project('510', type: 'Video', file: 'clip.mp4');
    final w = WallpaperEngineLibrary.describe('${dir.path}\\clip.mp4')!;
    expect(w.isVideo, isTrue);
  });

  test('没有 project.json 的裸图片也能用', () {
    final bare = File('${tree.contentDir.path}\\bare.png')
      ..writeAsStringSync('img');
    final w = WallpaperEngineLibrary.describe(bare.path)!;
    expect(w.type, 'image');
    expect(w.isImage, isTrue);
    expect(w.primaryFile, bare.path);
    expect(w.previewPath, isNull);
  });

  test('没有 project.json 且类型未知时返回空', () {
    final odd = File('${tree.contentDir.path}\\thing.bin')
      ..writeAsStringSync('x');
    expect(WallpaperEngineLibrary.describe(odd.path), isNull);
  });

  test('project.json 没声明 preview 时按约定找 preview.jpg', () {
    final dir = tree.project('600',
        type: 'scene',
        file: 'scene.json',
        createPrimary: false,
        preview: 'preview.jpg',
        declarePreview: false,
        extraFiles: {'scene.pkg': 'x'});
    final w = WallpaperEngineLibrary.describe('${dir.path}\\scene.pkg')!;
    expect(w.previewPath, '${dir.path}\\preview.jpg');
  });

  test('图片壁纸直接用原图，场景与网页壁纸用作者预览图', () async {
    final photo = tree.project('700', type: 'image', file: 'photo.png');
    final imageStill = await tree.library.resolveStill(
      WallpaperEngineLibrary.describe('${photo.path}\\photo.png')!,
      cacheDir: cache.path,
      boxWidth: 1920,
      boxHeight: 1080,
    );
    expect(imageStill!.kind, 'image');
    expect(imageStill.path, '${photo.path}\\photo.png');
    expect(imageStill.isFrame, isFalse);

    for (final spec in [
      ('710', 'scene', 'scene.json', 'preview.jpg'),
      ('720', 'web', 'index.html', 'preview.gif'),
    ]) {
      final dir = tree.project(spec.$1,
          type: spec.$2,
          file: spec.$3,
          preview: spec.$4,
          extraFiles: spec.$2 == 'scene' ? {'scene.pkg': 'x'} : null);
      final played =
          spec.$2 == 'scene' ? '${dir.path}\\scene.pkg' : '${dir.path}\\${spec.$3}';
      final still = await tree.library.resolveStill(
        WallpaperEngineLibrary.describe(played)!,
        cacheDir: cache.path,
        boxWidth: 1920,
        boxHeight: 1080,
      );
      expect(still!.kind, 'preview', reason: spec.$2);
      expect(still.path, '${dir.path}\\${spec.$4}');
    }
  });

  test('列出壁纸：工坊与本地项目都在，WE 当前那张排最前', () {
    final a = tree.project('100', type: 'scene', file: 'scene.json',
        createPrimary: false, title: 'Zebra', extraFiles: {'scene.pkg': 'x'});
    tree.project('200', type: 'web', file: 'index.html', title: 'Apple');
    tree.localProject('my own', type: 'scene', file: 'scene.pkg', title: 'Banana');
    Directory('${tree.contentDir.path}\\900-not-a-project').createSync();
    tree.select('${a.path}\\scene.pkg', lastSelected: 'Monitor0');

    final list = tree.library.wallpapers();
    expect(list.map((w) => w.title).toList(), ['Zebra', 'Apple', 'Banana'],
        reason: '当前壁纸置顶，其余按标题排序');
    expect(list.first.primaryFile, '${a.path}\\scene.pkg');
    expect(list.last.projectDir, contains('my own'));
    expect(list.last.typeLabel, '场景');
    expect(list.every((w) => w.previewPath != null), isTrue);
  });

  test('没有任何壁纸目录时列表为空，不抛异常', () {
    expect(tree.library.wallpapers(), isEmpty);
  });

  test('WE 当前壁纸不在扫描目录里也照样列出', () {
    final outside = Directory('${cache.path}\\outside\\900')
      ..createSync(recursive: true);
    File('${outside.path}\\project.json').writeAsStringSync(jsonEncode({
      'type': 'video',
      'file': 'clip.mp4',
      'title': 'Outside',
    }));
    File('${outside.path}\\clip.mp4').writeAsStringSync('v');
    tree.select('${outside.path}\\clip.mp4');

    final list = tree.library.wallpapers();
    expect(list.length, 1);
    expect(list.single.title, 'Outside');
    expect(list.single.isVideo, isTrue);
  });

  test('场景壁纸优先取包里的原图，取不到才用预览图', () async {
    // A scene whose package holds a real 3840×2160 picture.
    final good = tree.project('730',
        type: 'scene', file: 'scene.json', createPrimary: false, title: 'Artwork');
    final picture = <int>[0xFF, 0xD8, 0xFF, 0xDB, ...List.filled(6000, 0x11)];
    File('${good.path}\\scene.pkg').writeAsBytesSync(buildPackage([
      ('scene.json', Uint8List.fromList([1])),
      (
        'materials/backdrop.tex',
        buildTexture(width: 3840, height: 2160, payload: picture, format: 0)
      ),
    ]));

    final still = await tree.library.resolveStill(
      WallpaperEngineLibrary.describe('${good.path}\\scene.pkg')!,
      cacheDir: cache.path,
      boxWidth: 1920,
      boxHeight: 1080,
    );
    expect(still!.kind, 'scene-artwork');
    expect(still.path, endsWith('.jpg'));
    expect(File(still.path).readAsBytesSync(), picture);

    // A scene whose package has no usable picture falls back to the preview.
    final brokenScene = tree.project('740',
        type: 'scene',
        file: 'scene.json',
        createPrimary: false,
        extraFiles: {'scene.pkg': 'not really a package'});
    final broken = await tree.library.resolveStill(
      WallpaperEngineLibrary.describe('${brokenScene.path}\\scene.pkg')!,
      cacheDir: cache.path,
      boxWidth: 1920,
      boxHeight: 1080,
    );
    expect(broken!.kind, 'preview');
  });

  test('libraryfolders.vdf：现代 path 与旧版编号两种写法', () {
    final vdf = File('${cache.path}\\libraryfolders.vdf');
    vdf.writeAsStringSync('"libraryfolders"\n{\n\t"0"\n\t{\n'
        '\t\t"path"\t\t"E:\\\\app\\\\steam"\n\t\t"label"\t\t""\n\t}\n'
        '\t"1"\n\t{\n\t\t"path"\t\t"C:\\\\SteamLibrary"\n\t}\n}');
    expect(WallpaperEngineLibrary.libraryFolders(vdf.path),
        [r'E:\app\steam', r'C:\SteamLibrary']);

    vdf.writeAsStringSync('"libraryfolders"\n{\n\t"1"\n\t"D:\\\\Games"\n}');
    expect(WallpaperEngineLibrary.libraryFolders(vdf.path), [r'D:\Games']);

    expect(WallpaperEngineLibrary.libraryFolders('${cache.path}\\nope.vdf'),
        isEmpty);
  });
}
