import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_ios/lib_llama_cpp_ios.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

void main() {
  test('registerWith installs the iOS platform implementation', () {
    final initial = LibLlamaCppPlatform.instance;
    addTearDown(() => LibLlamaCppPlatform.instance = initial);

    LibLlamaCppIos.registerWith();

    expect(LibLlamaCppPlatform.instance, isA<LibLlamaCppIos>());
  });

  test('resolveLibrary returns the bundled iOS framework path', () async {
    final descriptor = await LibLlamaCppIos().resolveLibrary();

    expect(descriptor.resolution, LlamaCppLibraryResolution.path);
    expect(descriptor.path, 'lib_llama_cpp_ios.framework/lib_llama_cpp_ios');
    expect(descriptor.capabilities, contains(LlamaCppLibraryCapability.metal));
  });
}
