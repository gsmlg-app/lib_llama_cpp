import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_macos/lib_llama_cpp_macos.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

void main() {
  test('registerWith installs the macOS platform implementation', () {
    final initial = LibLlamaCppPlatform.instance;
    addTearDown(() => LibLlamaCppPlatform.instance = initial);

    LibLlamaCppMacos.registerWith();

    expect(LibLlamaCppPlatform.instance, isA<LibLlamaCppMacos>());
  });

  test('resolveLibrary returns the bundled macOS framework path', () async {
    final descriptor = await LibLlamaCppMacos().resolveLibrary();

    expect(descriptor.resolution, LlamaCppLibraryResolution.path);
    expect(
      descriptor.path,
      'lib_llama_cpp_macos.framework/lib_llama_cpp_macos',
    );
    expect(descriptor.capabilities, equals({LlamaCppLibraryCapability.cpu}));
  });
}
