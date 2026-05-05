import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_android/lib_llama_cpp_android.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

void main() {
  test('registerWith installs the Android platform implementation', () {
    final initial = LibLlamaCppPlatform.instance;
    addTearDown(() => LibLlamaCppPlatform.instance = initial);

    LibLlamaCppAndroid.registerWith();

    expect(LibLlamaCppPlatform.instance, isA<LibLlamaCppAndroid>());
  });

  test(
    'resolveLibrary returns the bundled Android shared object name',
    () async {
      final descriptor = await LibLlamaCppAndroid().resolveLibrary();

      expect(descriptor.resolution, LlamaCppLibraryResolution.lookupName);
      expect(descriptor.lookupName, 'liblib_llama_cpp_android.so');
      expect(
        descriptor.capabilities,
        contains(LlamaCppLibraryCapability.vulkan),
      );
    },
  );

  test('preferred path overrides the bundled Android lookup name', () async {
    final descriptor = await LibLlamaCppAndroid().resolveLibrary(
      request: const LlamaCppLibraryRequest(preferredPath: '/tmp/libllama.so'),
    );

    expect(descriptor.resolution, LlamaCppLibraryResolution.path);
    expect(descriptor.path, '/tmp/libllama.so');
    expect(descriptor.lookupName, isNull);
  });
}
