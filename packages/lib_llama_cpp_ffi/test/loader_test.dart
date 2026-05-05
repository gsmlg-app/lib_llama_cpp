import 'dart:ffi';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaCppDynamicLibraryLoader', () {
    test('opens an explicit library path with the injected opener', () {
      final openedPaths = <String>[];
      final loader = LlamaCppDynamicLibraryLoader(
        openLibrary: (path) {
          openedPaths.add(path);
          return DynamicLibrary.process();
        },
        operatingSystem: () => 'linux',
      );

      final library = loader.open('/opt/llama/libcustom_llama.so');

      expect(library, isA<DynamicLibrary>());
      expect(openedPaths, ['/opt/llama/libcustom_llama.so']);
    });

    test('uses the platform default library path when no path is supplied', () {
      final cases = <String, String>{
        'android': 'libllama.so',
        'ios': 'libllama.dylib',
        'linux': 'libllama.so',
        'macos': 'libllama.dylib',
        'windows': 'llama.dll',
      };

      for (final MapEntry(key: operatingSystem, value: expectedPath)
          in cases.entries) {
        final openedPaths = <String>[];
        final loader = LlamaCppDynamicLibraryLoader(
          openLibrary: (path) {
            openedPaths.add(path);
            return DynamicLibrary.process();
          },
          operatingSystem: () => operatingSystem,
        );

        loader.open();

        expect(openedPaths, [
          expectedPath,
        ], reason: 'default path for $operatingSystem');
      }
    });

    test('reports unsupported platforms before opening a library', () {
      var opened = false;
      final loader = LlamaCppDynamicLibraryLoader(
        openLibrary: (_) {
          opened = true;
          return DynamicLibrary.process();
        },
        operatingSystem: () => 'fuchsia',
      );

      expect(loader.open, throwsUnsupportedError);
      expect(opened, isFalse);
    });
  });
}
