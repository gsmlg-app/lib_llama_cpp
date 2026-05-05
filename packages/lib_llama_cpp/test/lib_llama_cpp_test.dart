import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

final class FakeLibLlamaCppPlatform extends LibLlamaCppPlatform
    with MockPlatformInterfaceMixin {
  var resolveCount = 0;

  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    resolveCount += 1;
    return const LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.lookupName,
      lookupName: 'libtest_llama.so',
      capabilities: {LlamaCppLibraryCapability.cpu},
    );
  }
}

void main() {
  test(
    'resolves the native library before streaming command responses',
    () async {
      final platform = FakeLibLlamaCppPlatform();
      final client = LibLlamaCpp(platform: platform);

      final responses = await client
          .transform(
            Stream<LlamaCommand>.fromIterable([
              const LlamaLoadModelCommand(modelPath: '/models/tiny.gguf'),
              const LlamaDisposeCommand(),
            ]),
          )
          .toList();

      expect(platform.resolveCount, 1);
      expect(responses.first, isA<LlamaReadyResponse>());
      expect(
        responses.whereType<LlamaStateChangedResponse>().map(
          (event) => event.state,
        ),
        [
          const LlamaState(modelPath: '/models/tiny.gguf', isModelLoaded: true),
          const LlamaState.empty(),
        ],
      );
      expect(responses.last, const LlamaDoneResponse());
    },
  );

  test('generation before loading a model emits an error response', () async {
    final client = LibLlamaCpp(platform: FakeLibLlamaCppPlatform());

    final responses = await client
        .transform(
          Stream<LlamaCommand>.value(
            const LlamaGenerateCommand(prompt: 'Hello', maxTokens: 8),
          ),
        )
        .toList();

    expect(responses.first, isA<LlamaReadyResponse>());
    expect(
      responses.last,
      const LlamaErrorResponse(
        message: 'Cannot generate before a model is loaded.',
      ),
    );
  });
}
