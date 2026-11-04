import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const moduleName = 'github.com/idy/wgc-ne/core';

Future<void> run(String command, List<String> arguments,
    {String? directory, Map<String, String>? environment}) async {
  final process = await Process.start(command, arguments,
      workingDirectory: directory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) throw StateError('$command failed with exit code $code');
}

Future<String> output(String command, List<String> arguments) async {
  final result = await Process.run(command, arguments);
  if (result.exitCode != 0) throw StateError('$command failed');
  return result.stdout.toString().trim();
}

void main(List<String> arguments) async {
  Directory? temporary;
  try {
    var platform = 'ios';
    var destination = p.absolute('build/WGCCore.xcframework');
    String? configPath;
    var force = false;
    var deviceOnly = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help') {
        stdout.writeln(
            'dart run wgc_ne:build_core [--platform ios|macos|all] [--config file.yaml] [--output build/WGCCore.xcframework] [--device-only] [--force]');
        return;
      }
      if (argument == '--force') {
        force = true;
        continue;
      }
      if (argument == '--device-only') {
        deviceOnly = true;
        continue;
      }
      if (!['--platform', '--output', '--config'].contains(argument) ||
          index + 1 >= arguments.length) {
        throw ArgumentError('Unknown or incomplete option: $argument');
      }
      final value = arguments[++index];
      switch (argument) {
        case '--platform':
          platform = value;
        case '--output':
          destination = p.absolute(value);
        case '--config':
          configPath = p.absolute(value);
      }
    }
    if (!Platform.isMacOS)
      throw StateError('Apple core builds require macOS and Xcode');
    if (!['ios', 'macos', 'all'].contains(platform))
      throw ArgumentError('Invalid platform');
    if (deviceOnly && platform != 'ios')
      throw ArgumentError('--device-only requires --platform ios');
    if (p.basename(destination) != 'WGCCore.xcframework')
      throw ArgumentError('Output must be named WGCCore.xcframework');
    final target = Directory(destination);
    if (target.existsSync() &&
        (!force ||
            !File(p.join(destination, 'wgc-ne-build.json')).existsSync())) {
      throw StateError(
          'Output exists; --force replaces only a previous WGC NE build');
    }
    final packageUri = await Isolate.resolvePackageUri(
        Uri.parse('package:wgc_ne/wgc_ne.dart'));
    if (packageUri == null)
      throw StateError('Cannot resolve the wgc_ne package');
    final packageRoot = p.dirname(p.dirname(File.fromUri(packageUri).path));
    final coreRoot = p.join(packageRoot, 'core');
    if (!File(p.join(coreRoot, 'go.mod')).existsSync())
      throw StateError('Plugin Go sources are missing');
    final imports = <String>[];
    final extensions = <Map<String, String>>[];
    final importPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._/-]+$');
    if (configPath != null) {
      final config = loadYaml(File(configPath).readAsStringSync());
      if (config is! YamlMap ||
          config.keys.any((key) => key != 'extensions') ||
          config['extensions'] is! YamlList) {
        throw FormatException('Expected an extensions list');
      }
      for (final item in config['extensions'] as YamlList) {
        if (item is! YamlMap ||
            item.keys.any((key) =>
                !['package', 'module', 'version', 'path'].contains(key)))
          throw FormatException('Invalid extension');
        final package = item['package'];
        final module = item['module'];
        final version = item['version'] ?? 'v0.0.0';
        if (package is! String ||
            module is! String ||
            !importPattern.hasMatch(package) ||
            !importPattern.hasMatch(module) ||
            package.contains('..') ||
            module.contains('..') ||
            !(package == module || package.startsWith('$module/')) ||
            version is! String ||
            !RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+-]*$')
                .hasMatch(version)) {
          throw FormatException(
              'Invalid Go module, package, or pinned version');
        }
        if (module == moduleName || imports.contains(package))
          throw FormatException('Duplicate or reserved extension package');
        imports.add(package);
        final entry = {
          'package': package,
          'module': module,
          'version': version
        };
        if (item['path'] != null) {
          if (item['path'] is! String)
            throw FormatException('Extension path must be a string');
          entry['path'] = p
              .normalize(p.join(p.dirname(configPath), item['path'] as String));
          if (!File(p.join(entry['path']!, 'go.mod')).existsSync())
            throw FormatException('Local extension module is missing');
        }
        extensions.add(entry);
      }
    }
    temporary = await Directory.systemTemp.createTemp('wgc-ne-core-');
    final moduleDirectory = Directory(p.join(temporary.path, 'module'))
      ..createSync();
    final source = File(p.join(coreRoot, 'cmd/wgc-ne-core/main.go'))
        .readAsStringSync()
        .replaceFirst('// wgc-ne:extension-imports',
            imports.map((value) => '_ ${jsonEncode(value)}').join('\n'));
    File(p.join(moduleDirectory.path, 'main.go')).writeAsStringSync(source);
    File(p.join(moduleDirectory.path, 'go.mod'))
        .writeAsStringSync('module wgcne.local/build\n\ngo 1.26.0\n');
    await run(
        'go',
        [
          'mod',
          'edit',
          '-require=$moduleName@v0.1.0',
          '-replace=$moduleName=$coreRoot'
        ],
        directory: moduleDirectory.path);
    for (final entry in extensions) {
      await run(
          'go',
          [
            'mod',
            'edit',
            '-require=${entry['module']}@${entry['version']}',
            if (entry['path'] != null)
              '-replace=${entry['module']}=${entry['path']}'
          ],
          directory: moduleDirectory.path);
    }
    await run('go', ['mod', 'tidy'], directory: moduleDirectory.path);
    final clang = await output('xcrun', ['--find', 'clang']);
    final libraries = <String>[];
    final slices = <String, List<String>>{
      if (platform == 'ios' || platform == 'all') 'iphoneos': ['arm64'],
      if ((platform == 'ios' || platform == 'all') && !deviceOnly)
        'iphonesimulator': ['arm64', 'x86_64'],
      if (platform == 'macos' || platform == 'all')
        'macosx': ['arm64', 'x86_64'],
    };
    for (final entry in slices.entries) {
      final sdk =
          await output('xcrun', ['--sdk', entry.key, '--show-sdk-path']);
      final archives = <String>[];
      for (final arch in entry.value) {
        final directory = Directory(p.join(temporary.path, entry.key, arch))
          ..createSync(recursive: true);
        final triple = entry.key == 'macosx'
            ? '$arch-apple-macos12.0'
            : '$arch-apple-ios15.0${entry.key == 'iphonesimulator' ? '-simulator' : ''}';
        final archive = p.join(directory.path, 'libWGCCore.a');
        stdout.writeln('Building ${entry.key} $arch');
        await run(
            'go',
            [
              'build',
              '-tags',
              'with_gvisor',
              '-trimpath',
              '-ldflags=-s -w',
              '-buildmode=c-archive',
              '-o',
              archive,
              '.'
            ],
            directory: moduleDirectory.path,
            environment: {
              'CGO_ENABLED': '1',
              'GOOS': entry.key == 'macosx' ? 'darwin' : 'ios',
              'GOARCH': arch == 'x86_64' ? 'amd64' : 'arm64',
              'CC': clang,
              'CGO_CFLAGS': '-isysroot "$sdk" -target $triple',
              'CGO_LDFLAGS': '-isysroot "$sdk" -target $triple',
            });
        archives.add(archive);
      }
      final combined = p.join(temporary.path, entry.key, 'libWGCCore.a');
      await run('xcrun', ['lipo', '-create', ...archives, '-output', combined]);
      libraries.add(combined);
    }
    final staged = p.join(temporary.path, 'WGCCore.xcframework');
    final headerPath = p.join(packageRoot, 'apple/GoAdapter/include');
    await run('xcodebuild', [
      '-create-xcframework',
      for (final library in libraries) ...[
        '-library',
        library,
        '-headers',
        headerPath
      ],
      '-output',
      staged
    ]);
    File(p.join(staged, 'wgc-ne-build.json')).writeAsStringSync(jsonEncode({
      'abi_version': 1,
      'core_version': '0.1.0',
      'wgc_version': '0.2.0',
      'sing_box_version': '1.14.4',
      'platform': platform,
      'extensions': imports
    }));
    final legal = Directory(p.join(staged, 'Legal'))..createSync();
    for (final name in ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md']) {
      File(p.join(packageRoot, name)).copySync(p.join(legal.path, name));
    }
    await run('/usr/bin/ditto', [
      p.join(packageRoot, 'third_party/licenses'),
      p.join(legal.path, 'dependencies')
    ]);
    target.parent.createSync(recursive: true);
    if (target.existsSync()) await target.delete(recursive: true);
    await run('/usr/bin/ditto', [staged, destination]);
    stdout.writeln('Built $destination');
  } catch (error) {
    stderr.writeln('WGC NE build failed: $error');
    exitCode = 1;
  } finally {
    if (temporary != null) await temporary.delete(recursive: true);
  }
}
