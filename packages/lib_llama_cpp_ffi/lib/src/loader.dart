import 'dart:ffi';
import 'dart:io' show Platform;

typedef DynamicLibraryOpener = DynamicLibrary Function(String path);
typedef OperatingSystemProvider = String Function();

final class LlamaCppDynamicLibraryLoader {
  LlamaCppDynamicLibraryLoader({
    DynamicLibraryOpener? openLibrary,
    OperatingSystemProvider? operatingSystem,
  }) : _openLibrary = openLibrary ?? DynamicLibrary.open,
       _operatingSystem = operatingSystem ?? (() => Platform.operatingSystem);

  final DynamicLibraryOpener _openLibrary;
  final OperatingSystemProvider _operatingSystem;

  DynamicLibrary open([String? path]) {
    final libraryPath = path ?? defaultLibraryPathFor(_operatingSystem());
    return _openLibrary(libraryPath);
  }

  static String defaultLibraryPathFor(String operatingSystem) {
    return switch (operatingSystem) {
      'android' || 'linux' => 'libllama.so',
      'ios' || 'macos' => 'libllama.dylib',
      'windows' => 'llama.dll',
      _ => throw UnsupportedError(
        'Unsupported operating system: $operatingSystem',
      ),
    };
  }
}
