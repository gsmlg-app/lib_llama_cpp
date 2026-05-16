import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_linux/lib_llama_cpp_linux.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

void main() {
  test('registerWith installs the Linux platform implementation', () {
    final initial = LibLlamaCppPlatform.instance;
    addTearDown(() => LibLlamaCppPlatform.instance = initial);

    LibLlamaCppLinux.registerWith();

    expect(LibLlamaCppPlatform.instance, isA<LibLlamaCppLinux>());
  });

  test('resolveLibrary returns the bundled Linux shared object name', () async {
    final descriptor = await LibLlamaCppLinux().resolveLibrary();

    expect(descriptor.resolution, LlamaCppLibraryResolution.lookupName);
    expect(descriptor.lookupName, 'liblib_llama_cpp_linux.so');
    expect(
      descriptor.capabilities,
      equals({LlamaCppLibraryCapability.cpu, LlamaCppLibraryCapability.vulkan}),
    );
  });

  test('bundled Linux library rejects unsupported required backends', () async {
    await expectLater(
      LibLlamaCppLinux().resolveLibrary(
        request: const LlamaCppLibraryRequest(
          requiredCapabilities: {LlamaCppLibraryCapability.cuda},
        ),
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('preferred Linux path can declare CUDA and Vulkan support', () async {
    final descriptor = await LibLlamaCppLinux().resolveLibrary(
      request: const LlamaCppLibraryRequest(
        preferredPath: '/tmp/libllama_gpu.so',
        requiredCapabilities: {
          LlamaCppLibraryCapability.cuda,
          LlamaCppLibraryCapability.vulkan,
        },
      ),
    );

    expect(descriptor.resolution, LlamaCppLibraryResolution.path);
    expect(descriptor.path, '/tmp/libllama_gpu.so');
    expect(
      descriptor.capabilities,
      equals({
        LlamaCppLibraryCapability.cpu,
        LlamaCppLibraryCapability.cuda,
        LlamaCppLibraryCapability.vulkan,
      }),
    );
  });
}
