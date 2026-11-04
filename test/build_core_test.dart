import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Android builder preflight', () {
    final root = Directory.current.path;
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final dart = flutterRoot == null
        ? 'dart'
        : p.join(flutterRoot, 'bin/cache/dart-sdk/bin/dart');
    late Directory scratch;
    late File goLog;
    late String fakeBin;

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('wgc-ne-preflight-test-');
      goLog = File(p.join(scratch.path, 'go.log'));
      fakeBin = p.join(scratch.path, 'bin');
      Directory(fakeBin).createSync();
      final go = File(p.join(fakeBin, 'go'))
        ..writeAsStringSync('#!/bin/sh\n'
            'printf "%s\\n" "\$*" >> "\$WGC_TEST_GO_LOG"\n'
            'exit 97\n');
      final result = await Process.run('chmod', ['+x', go.path]);
      expect(result.exitCode, 0);
    });

    tearDown(() async {
      await scratch.delete(recursive: true);
    });

    String ndk(String name,
        {String revision = '28.2.13676358',
        List<String> compilers = const [
          'aarch64-linux-android',
          'x86_64-linux-android',
        ]}) {
      final directory = Directory(p.join(scratch.path, name))..createSync();
      File(p.join(directory.path, 'source.properties'))
          .writeAsStringSync('Pkg.Revision = $revision\n');
      final bin = Directory(p.join(directory.path, 'toolchains/llvm/prebuilt',
          Platform.isMacOS ? 'darwin-x86_64' : 'linux-x86_64', 'bin'))
        ..createSync(recursive: true);
      for (final compiler in compilers) {
        File(p.join(bin.path, '${compiler}23-clang')).writeAsStringSync('');
      }
      return directory.path;
    }

    Future<ProcessResult> build(List<String> options,
        {Map<String, String> environment = const {},
        bool forbidTemporaryModule = true}) {
      final variables = Map<String, String>.of(Platform.environment)
        ..removeWhere((key, _) => [
              'ANDROID_HOME',
              'ANDROID_SDK_ROOT',
              'ANDROID_NDK_HOME',
              'ANDROID_NDK_ROOT',
            ].contains(key))
        ..addAll({
          'PATH': '$fakeBin:${Platform.environment['PATH']}',
          'WGC_TEST_GO_LOG': goLog.path,
          'TMPDIR': p.join(scratch.path,
              forbidTemporaryModule ? 'unavailable' : 'temporary'),
          ...environment,
        });
      if (!forbidTemporaryModule) {
        Directory(variables['TMPDIR']!).createSync();
      }
      return Process.run(
        dart,
        [
          '--packages=${p.join(root, '.dart_tool/package_config.json')}',
          p.join(root, 'bin/build_core.dart'),
          '--platform',
          'android',
          '--output',
          p.join(scratch.path, 'jniLibs'),
          ...options,
        ],
        workingDirectory: root,
        environment: variables,
        includeParentEnvironment: false,
      );
    }

    void expectPreflightFailure(ProcessResult result, String message) {
      expect(result.exitCode, 1, reason: result.stderr.toString());
      expect(result.stderr, contains(message));
      expect(goLog.existsSync(), isFalse, reason: 'Go must never be invoked');
    }

    void expectGoReached(ProcessResult result) {
      expect(result.exitCode, 1);
      expect(result.stderr, contains('go failed with exit code 97'));
      final calls = goLog.readAsLinesSync();
      expect(calls, hasLength(1));
      expect(calls.single, startsWith('mod edit '));
      expect(Directory(p.join(scratch.path, 'temporary')).listSync(), isEmpty);
    }

    test('missing explicit NDK fails before temporary module or Go', () async {
      expectPreflightFailure(
          await build([
            '--ndk',
            p.join(scratch.path, 'missing')
          ], environment: {
            'ANDROID_NDK_HOME': ndk('environment-ndk'),
          }),
          'Supply --ndk');
    });

    test('old and invalid revisions fail before temporary module or Go',
        () async {
      for (final revision in ['27.3.13750724', 'invalid']) {
        expectPreflightFailure(
            await build(['--ndk', ndk(revision, revision: revision)]),
            'Android builds require NDK r28 or newer');
      }
    });

    test('checks every selected API 23 compiler before temporary module or Go',
        () async {
      final incomplete = ndk('incomplete', compilers: [
        'aarch64-linux-android',
        'armv7a-linux-androideabi',
      ]);
      expectPreflightFailure(
          await build([
            '--ndk',
            incomplete,
            '--android-abis',
            'arm64-v8a,armeabi-v7a,x86_64',
          ]),
          'Android NDK compiler is missing');
    });

    test('preserves NDK and SDK environment precedence', () async {
      final old = ndk('old', revision: '27.3.13750724');
      final valid = ndk('valid');
      final oldSdk = Directory(p.join(scratch.path, 'old-sdk/ndk'))
        ..createSync(recursive: true);
      final validSdk = Directory(p.join(scratch.path, 'valid-sdk/ndk'))
        ..createSync(recursive: true);
      Directory(old).renameSync(p.join(oldSdk.path, '28.2.13676358'));
      Directory(valid).renameSync(p.join(validSdk.path, '28.2.13676358'));
      final oldNdk = p.join(oldSdk.path, '28.2.13676358');
      final validNdk = p.join(validSdk.path, '28.2.13676358');
      for (final environment in [
        {'ANDROID_NDK_HOME': oldNdk, 'ANDROID_NDK_ROOT': validNdk},
        {'ANDROID_NDK_ROOT': oldNdk, 'ANDROID_HOME': validSdk.parent.path},
        {
          'ANDROID_HOME': oldSdk.parent.path,
          'ANDROID_SDK_ROOT': validSdk.parent.path,
        },
        {'ANDROID_SDK_ROOT': oldSdk.parent.path},
      ]) {
        expectPreflightFailure(await build([], environment: environment),
            'Android builds require NDK r28 or newer');
      }
    });

    test('explicit NDK overrides environment and default ABIs remain a subset',
        () async {
      expectGoReached(await build(['--ndk', ndk('valid-defaults')],
          environment: {'ANDROID_NDK_HOME': ndk('old', revision: '27.0.0')},
          forbidTemporaryModule: false));
    });

    test('unselected ABI compilers are not required', () async {
      expectGoReached(await build([
        '--ndk',
        ndk('arm64-only', compilers: ['aarch64-linux-android']),
        '--android-abis',
        'arm64-v8a',
      ], forbidTemporaryModule: false));
    });

    test('ABI errors keep their ordered supported list', () async {
      for (final abis in ['', 'mips', 'arm64-v8a,arm64-v8a']) {
        expectPreflightFailure(await build(['--android-abis', abis]),
            'Supported Android ABIs: arm64-v8a, armeabi-v7a, x86_64');
      }
    });

    test('force still protects an output without WGC build metadata', () async {
      final sentinel = File(p.join(scratch.path, 'jniLibs/keep.txt'))
        ..parent.createSync()
        ..writeAsStringSync('keep');
      expectPreflightFailure(await build(['--force']),
          'Output exists; --force replaces only a previous WGC NE build');
      expect(sentinel.readAsStringSync(), 'keep');
    });
  }, skip: !Platform.isMacOS && !Platform.isLinux);
}
