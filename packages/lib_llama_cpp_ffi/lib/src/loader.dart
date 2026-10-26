import 'dart:ffi';
import 'dart:io' show Platform;

typedef DynamicLibraryOpener = DynamicLibrary Function(String path);
typedef OperatingSystemProvider = String Function();
typedef LlamaCppLibraryValidator = void Function(DynamicLibrary library);

final class LlamaCppDynamicLibraryLoader {
  LlamaCppDynamicLibraryLoader({
    DynamicLibraryOpener? openLibrary,
    OperatingSystemProvider? operatingSystem,
    LlamaCppLibraryValidator? validate,
  }) : _openLibrary = openLibrary ?? DynamicLibrary.open,
       _operatingSystem = operatingSystem ?? (() => Platform.operatingSystem),
       _validate = validate ?? validateLibrary;

  final DynamicLibraryOpener _openLibrary;
  final OperatingSystemProvider _operatingSystem;
  final LlamaCppLibraryValidator _validate;

  DynamicLibrary open([String? path]) {
    final libraryPath = path ?? defaultLibraryPathFor(_operatingSystem());
    try {
      final library = _openLibrary(libraryPath);
      _validate(library);
      return library;
    } catch (error) {
      throw StateError(
        'Unable to load lib_llama_cpp library "$libraryPath": $error',
      );
    }
  }

  /// Rejects a plain upstream library before any model resources are allocated.
  static void validateLibrary(DynamicLibrary library) {
    for (final symbol in const [
      'lib_llama_cpp_abi_version',
      'lib_llama_cpp_chat_templates_apply_json',
      'lib_llama_cpp_chat_templates_caps_json',
      'llcs_engine_create',
      'llcs_engine_submit',
      'llcs_engine_poll',
      'llcs_engine_cancel',
      'llcs_engine_destroy',
      'llcs_string_free',
      'llcs_engine_prepare',
      'llcs_engine_stats',
      'llcs_backend_acquire',
      'llcs_backend_release',
      'llcs_cancel_create',
      'llcs_cancel_free',
      'llcs_cancel_request',
      'llcs_cancel_reset',
      'llcs_cancel_is_requested',
      'llcs_cancel_install',
      'llcs_cancel_wait_credit',
      'llcs_cancel_release_credit',
      'lib_llama_cpp_media_eval_prompt_with_budget',
      'lib_llama_cpp_media_last_prompt_tokens',
    ]) {
      if (!library.providesSymbol(symbol)) {
        throw ArgumentError(
          'Missing required shim symbol: $symbol. '
          'Use a lib_llama_cpp desktop artifact built from the same release.',
        );
      }
    }
  }

  static String defaultLibraryPathFor(String operatingSystem) {
    return switch (operatingSystem) {
      'android' => 'libllama.so',
      'linux' => 'liblib_llama_cpp_linux.so',
      'ios' || 'macos' => 'libllama.dylib',
      'windows' => 'lib_llama_cpp_windows.dll',
      _ => throw UnsupportedError(
        'Unsupported operating system: $operatingSystem',
      ),
    };
  }
}
