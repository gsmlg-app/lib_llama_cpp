import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:lib_llama_cpp_windows/lib_llama_cpp_windows.dart';

void main() {
  test('registerWith installs the Windows platform implementation', () {
    final initial = LibLlamaCppPlatform.instance;
    addTearDown(() => LibLlamaCppPlatform.instance = initial);

    LibLlamaCppWindows.registerWith();

    expect(LibLlamaCppPlatform.instance, isA<LibLlamaCppWindows>());
  });

  test('resolveLibrary returns the bundled Windows DLL name', () async {
    final descriptor = await LibLlamaCppWindows().resolveLibrary();

    expect(descriptor.resolution, LlamaCppLibraryResolution.lookupName);
    expect(descriptor.lookupName, 'lib_llama_cpp_windows.dll');
    expect(
      descriptor.capabilities,
      equals({LlamaCppLibraryCapability.cpu, LlamaCppLibraryCapability.vulkan}),
    );
  });

  test(
    'bundled Windows library rejects unsupported required backends',
    () async {
      await expectLater(
        LibLlamaCppWindows().resolveLibrary(
          request: const LlamaCppLibraryRequest(
            requiredCapabilities: {LlamaCppLibraryCapability.cuda},
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('preferred Windows path can declare CUDA and Vulkan support', () async {
    final descriptor = await LibLlamaCppWindows().resolveLibrary(
      request: const LlamaCppLibraryRequest(
        preferredPath: r'C:\llama\lib_llama_cpp_windows.dll',
        requiredCapabilities: {
          LlamaCppLibraryCapability.cuda,
          LlamaCppLibraryCapability.vulkan,
        },
      ),
    );

    expect(descriptor.resolution, LlamaCppLibraryResolution.path);
    expect(descriptor.path, r'C:\llama\lib_llama_cpp_windows.dll');
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
