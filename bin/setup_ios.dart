import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;

/// The setup operation is explicit because it changes the containing app's
/// Xcode targets and entitlements. It does not configure signing credentials.
void main(List<String> arguments) async {
  if (!Platform.isMacOS) {
    stderr.writeln('iOS extension setup requires macOS and Xcode.');
    exitCode = 1;
    return;
  }
  final uri =
      await Isolate.resolvePackageUri(Uri.parse('package:wgc_ne/wgc_ne.dart'));
  if (uri == null) {
    stderr.writeln('Cannot resolve the wgc_ne package.');
    exitCode = 1;
    return;
  }
  final root = p.dirname(p.dirname(File.fromUri(uri).path));
  final child = await Process.start(
      'python3', ['-I', p.join(root, 'tool/configure_ios.py'), ...arguments],
      mode: ProcessStartMode.inheritStdio);
  exitCode = await child.exitCode;
}
