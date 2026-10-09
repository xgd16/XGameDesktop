// A minimal stand-in for the NuGet CLI, used by the Windows build only.
//
// flutter_inappwebview_windows fetches the WebView2 SDK by running
// `nuget install Microsoft.Web.WebView2 -Version <v> -ExcludeVersion
// -OutputDirectory <dir>` from its CMakeLists. dist.nuget.org is not reachable
// on every network, and installing NuGet system-wide just to build would be a
// machine change this project should not require — so the project carries its
// own executable: windows/CMakeLists.txt puts `tool/nuget` on
// CMAKE_PROGRAM_PATH, where `find_program(nuget)` finds `nuget.exe`.
//
// Rebuild it with:
//   dart compile exe tool/nuget_shim.dart -o tool/nuget/nuget.exe
//
// Only `install` is implemented. Packages are downloaded from www.nuget.org
// and unpacked with the tar.exe that ships with Windows (it reads .nupkg zips).
// An existing package folder is left alone, which is what `-ExcludeVersion`
// asks for.
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != 'install') {
    stderr.writeln('nuget-shim: only "install" is supported '
        '(called with: ${args.join(' ')})');
    exit(2);
  }

  String? version;
  String? outputDirectory;
  final ids = <String>[];
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-Version' && i + 1 < args.length) {
      version = args[++i];
    } else if (arg == '-OutputDirectory' && i + 1 < args.length) {
      outputDirectory = args[++i];
    } else if (!arg.startsWith('-')) {
      ids.add(arg);
    }
  }
  if (ids.isEmpty || outputDirectory == null) {
    stderr.writeln('nuget-shim: need a package id and -OutputDirectory');
    exit(2);
  }

  final client = HttpClient();
  try {
    for (final id in ids) {
      final target = Directory('$outputDirectory\\$id');
      if (target.existsSync()) {
        stdout.writeln('nuget-shim: $id already installed, skipping');
        continue;
      }
      final url = Uri.parse('https://www.nuget.org/api/v2/package/'
          '$id${version == null ? '' : '/$version'}');
      stdout.writeln('nuget-shim: downloading $id'
          '${version == null ? '' : ' $version'}');
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != 200) {
        stderr.writeln('nuget-shim: $url -> HTTP ${response.statusCode}');
        exit(1);
      }
      final temp = Directory.systemTemp.createTempSync('nuget_shim');
      try {
        final package = File('${temp.path}\\$id.nupkg');
        final sink = package.openWrite();
        await response.pipe(sink);
        target.createSync(recursive: true);
        final tar = await Process.run(
            'tar', ['-xf', package.path, '-C', target.path]);
        if (tar.exitCode != 0) {
          stderr.writeln('nuget-shim: extracting $id failed: ${tar.stderr}');
          exit(1);
        }
      } finally {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      }
      stdout.writeln('nuget-shim: $id -> ${target.path}');
    }
  } finally {
    client.close(force: true);
  }
}
