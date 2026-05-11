import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

final class LibLlamaCppMacos extends LibLlamaCppPlatform {
  static void registerWith() {
    LibLlamaCppPlatform.instance = LibLlamaCppMacos();
  }

  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    final preferredPath = request.preferredPath;
    if (preferredPath != null) {
      return LlamaCppLibraryDescriptor(
        resolution: LlamaCppLibraryResolution.path,
        path: preferredPath,
        capabilities: _capabilities,
      );
    }

    return const LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: 'lib_llama_cpp_macos.framework/lib_llama_cpp_macos',
      capabilities: _capabilities,
    );
  }

  static const _capabilities = {LlamaCppLibraryCapability.cpu};
}
