import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  test(
    'CLI accepts existing native paths including Windows drive syntax',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'llcs cli paths ',
      );
      addTearDown(() => directory.delete(recursive: true));
      // On POSIX a drive-looking filename lets this validation regression run
      // without Windows. Windows uses its real absolute drive path instead.
      final name = Platform.isWindows
          ? 'model path.gguf'
          : r'C:\model path.gguf';
      final model = File('${directory.path}${Platform.pathSeparator}$name');
      await model.writeAsString(
        'path validation fixture; not used for inference',
      );
      final library = '${directory.path}${Platform.pathSeparator}missing.dll';
      final package = await Isolate.resolvePackageUri(
        Uri.parse('package:lib_llama_cpp_server/lib_llama_cpp_server.dart'),
      );
      final packageConfig = await Isolate.packageConfig;
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${packageConfig!.toFilePath()}',
        package!.resolve('../bin/lib_llama_cpp_server.dart').toFilePath(),
        '--model-path',
        Platform.isWindows ? model.path : name,
        '--library',
        library,
      ], workingDirectory: directory.path);
      expect(result.exitCode, 66);
      // Reaching library validation proves the existing model path was accepted;
      // no native library or actual model is needed for this CLI check.
      expect(result.stderr, contains('Library file does not exist: $library'));
      expect(result.stderr, isNot(contains('Model file does not exist')));
    },
  );
}
