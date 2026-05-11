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
  group('LlamaOpenAIClient model registry', () {
    test('unknown model fails with model_not_found', () async {
      final platform = FakeLibLlamaCppPlatform();
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: LibLlamaCpp(platform: platform),
      );

      await expectLater(
        client.responses.create(model: 'missing', input: 'Hello'),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'model_not_found')
              .having((error) => error.param, 'param', 'model'),
        ),
      );
      expect(platform.resolveCount, 0);
    });
  });

  group('responses.create', () {
    test('preserves current unwired native generation error', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
      );

      await expectLater(
        client.responses.create(
          model: 'local',
          input: 'Write one sentence.',
          maxOutputTokens: 16,
        ),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'generation_failed')
              .having(
                (error) => error.message,
                'message',
                contains('Native llama.cpp generation is not wired yet.'),
              ),
        ),
      );
    });

    test('store true fails explicitly', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
      );

      await expectLater(
        client.responses.create(model: 'local', input: 'Hello', store: true),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'unsupported_parameter')
              .having((error) => error.param, 'param', 'store'),
        ),
      );
    });

    test('unsupported input shape fails explicitly', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
      );

      await expectLater(
        client.responses.create(model: 'local', input: const ['Hello']),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'unsupported_parameter')
              .having((error) => error.param, 'param', 'input'),
        ),
      );
    });

    test('typed input items are accepted as response input', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
      );

      await expectLater(
        client.responses.create(
          model: 'local',
          input: const [LlamaResponseInputItem(role: 'user', content: 'Hello')],
        ),
        throwsA(
          isA<LlamaOpenAIException>().having(
            (error) => error.code,
            'code',
            'generation_failed',
          ),
        ),
      );
    });
  });

  group('responses.stream', () {
    test(
      'emits created then failed while native generation is unwired',
      () async {
        final client = LlamaOpenAIClient(
          models: {
            'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
          },
          engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
        );

        final events = await client.responses
            .stream(model: 'local', input: 'Hello', maxOutputTokens: 4)
            .toList();

        expect(events.first.type, 'response.created');
        expect(events.last.type, 'response.failed');
        expect(
          (events.last as LlamaResponseFailed).error.message,
          contains('Native llama.cpp generation is not wired yet.'),
        );
      },
    );
  });

  group('chat.completions.create', () {
    test(
      'maps chat messages through responses and preserves generation errors',
      () async {
        final client = LlamaOpenAIClient(
          models: {
            'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
          },
          engine: LibLlamaCpp(platform: FakeLibLlamaCppPlatform()),
        );

        await expectLater(
          client.chat.completions.create(
            model: 'local',
            messages: [const LlamaChatMessage(role: 'user', content: 'Hello')],
            maxTokens: 4,
          ),
          throwsA(
            isA<LlamaOpenAIException>().having(
              (error) => error.code,
              'code',
              'generation_failed',
            ),
          ),
        );
      },
    );
  });
}
