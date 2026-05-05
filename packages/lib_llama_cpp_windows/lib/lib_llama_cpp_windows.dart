import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

final class LibLlamaCppWindows extends LibLlamaCppPlatform {
  static void registerWith() {
    LibLlamaCppPlatform.instance = LibLlamaCppWindows();
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
      resolution: LlamaCppLibraryResolution.lookupName,
      lookupName: 'lib_llama_cpp_windows.dll',
      capabilities: _capabilities,
    );
  }

  static const _capabilities = {
    LlamaCppLibraryCapability.cpu,
    LlamaCppLibraryCapability.vulkan,
  };
}
