import 'dart:ffi';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaCppDynamicLibraryLoader', () {
    test('opens an explicit library path with the injected opener', () {
      final openedPaths = <String>[];
      final loader = LlamaCppDynamicLibraryLoader(
        validate: (_) {},
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
        'linux': 'liblib_llama_cpp_linux.so',
        'macos': 'libllama.dylib',
        'windows': 'lib_llama_cpp_windows.dll',
      };

      for (final MapEntry(key: operatingSystem, value: expectedPath)
          in cases.entries) {
        final openedPaths = <String>[];
        final loader = LlamaCppDynamicLibraryLoader(
          validate: (_) {},
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

    test('rejects libraries without project shim symbols', () {
      expect(
        () => LlamaCppDynamicLibraryLoader.validateLibrary(
          DynamicLibrary.process(),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('shim symbol'),
          ),
        ),
      );
    });

    test('explicit load errors identify the requested path', () {
      final loader = LlamaCppDynamicLibraryLoader(
        openLibrary: (_) => throw ArgumentError('missing dependency'),
      );
      expect(
        () => loader.open('/missing/accelerator.dll'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('/missing/accelerator.dll'),
          ),
        ),
      );
    });
  });
}
