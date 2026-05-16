import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

final class LibLlamaCppLinux extends LibLlamaCppPlatform {
  static void registerWith() {
    LibLlamaCppPlatform.instance = LibLlamaCppLinux();
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
        capabilities: _capabilitiesForPreferredPath(request),
      );
    }

    _validateRequiredCapabilities(request, _capabilities);
    return const LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.lookupName,
      lookupName: 'liblib_llama_cpp_linux.so',
      capabilities: _capabilities,
    );
  }

  static const _capabilities = {
    LlamaCppLibraryCapability.cpu,
    LlamaCppLibraryCapability.vulkan,
  };
}

Set<LlamaCppLibraryCapability> _capabilitiesForPreferredPath(
  LlamaCppLibraryRequest request,
) {
  return {LlamaCppLibraryCapability.cpu, ...request.requiredCapabilities};
}

void _validateRequiredCapabilities(
  LlamaCppLibraryRequest request,
  Set<LlamaCppLibraryCapability> capabilities,
) {
  final unsupported = request.requiredCapabilities
      .where((capability) => !capabilities.contains(capability))
      .map((capability) => capability.name)
      .toList();
  if (unsupported.isEmpty) {
    return;
  }

  throw UnsupportedError(
    'Bundled Linux llama.cpp library does not support: '
    '${unsupported.join(', ')}',
  );
}
