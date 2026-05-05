import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:test/test.dart';

final class MockLibLlamaCppPlatform extends LibLlamaCppPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    return const LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: '/tmp/libllama.dylib',
      capabilities: {LlamaCppLibraryCapability.cpu},
    );
  }
}

void main() {
  late LibLlamaCppPlatform initialPlatform;

  setUpAll(() {
    initialPlatform = LibLlamaCppPlatform.instance;
  });

  tearDown(() {
    LibLlamaCppPlatform.instance = initialPlatform;
  });

  test('default instance throws UnimplementedError for resolveLibrary', () {
    expect(
      () => LibLlamaCppPlatform.instance.resolveLibrary(),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('mock platform can be assigned', () async {
    final platform = MockLibLlamaCppPlatform();

    LibLlamaCppPlatform.instance = platform;

    expect(LibLlamaCppPlatform.instance, same(platform));
    await expectLater(
      LibLlamaCppPlatform.instance.resolveLibrary(),
      completion(
        const LlamaCppLibraryDescriptor(
          resolution: LlamaCppLibraryResolution.path,
          path: '/tmp/libllama.dylib',
          capabilities: {LlamaCppLibraryCapability.cpu},
        ),
      ),
    );
  });

  test('library descriptor equality and toString are deterministic', () {
    const first = LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: '/opt/lib/libllama.dylib',
      capabilities: {
        LlamaCppLibraryCapability.vulkan,
        LlamaCppLibraryCapability.cpu,
      },
    );
    const second = LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: '/opt/lib/libllama.dylib',
      capabilities: {
        LlamaCppLibraryCapability.cpu,
        LlamaCppLibraryCapability.vulkan,
      },
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(
      first.toString(),
      'LlamaCppLibraryDescriptor('
      'resolution: path, '
      'path: /opt/lib/libllama.dylib, '
      'lookupName: null, '
      'capabilities: {cpu, vulkan}'
      ')',
    );
  });
}
