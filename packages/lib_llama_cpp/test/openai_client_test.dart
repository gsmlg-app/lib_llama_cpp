import 'dart:convert';
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

final class ScriptedLlamaEngine implements LlamaEngine {
  ScriptedLlamaEngine(this.responses);

  final List<LlamaResponse> responses;
  final commands = <LlamaCommand>[];

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> input, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    commands.addAll(await input.toList());
    yield* Stream<LlamaResponse>.fromIterable(responses);
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
    test('maps streamed tokens into a completed response', () async {
      final engine = ScriptedLlamaEngine([
        const LlamaReadyResponse(
          library: LlamaCppLibraryDescriptor(
            resolution: LlamaCppLibraryResolution.lookupName,
            lookupName: 'libtest_llama.so',
            capabilities: {LlamaCppLibraryCapability.cpu},
          ),
        ),
        const LlamaStateChangedResponse(
          state: LlamaState(
            modelPath: '/models/local.gguf',
            isModelLoaded: true,
          ),
        ),
        const LlamaTokenResponse(text: 'Hello', index: 0),
        const LlamaTokenResponse(text: ' world', index: 1),
        const LlamaDoneResponse(),
      ]);
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: engine,
      );

      final response = await client.responses.create(
        model: 'local',
        input: 'Write one sentence.',
        maxOutputTokens: 16,
        temperature: 0.7,
        topP: 0.9,
        stop: const ['</s>'],
      );

      expect(response.status, 'completed');
      expect(response.outputText, 'Hello world');
      expect(
        engine.commands,
        contains(
          isA<LlamaGenerateMessagesCommand>()
              .having(
                (c) => c.messages.single.content,
                'content',
                'Write one sentence.',
              )
              .having((c) => c.maxTokens, 'maxTokens', 16)
              .having((c) => c.temperature, 'temperature', 0.7)
              .having((c) => c.topP, 'topP', 0.9)
              .having((c) => c.stop, 'stop', ['</s>']),
        ),
      );
    });

    test(
      'preserves instructions and ordinary message history without manual template text',
      () async {
        final engine = ScriptedLlamaEngine([
          const LlamaTokenResponse(text: '你好😀𠮷', index: 0),
          const LlamaDoneResponse(
            inputTokens: 21,
            outputTokens: 5,
            finishReason: 'length',
          ),
          const LlamaDoneResponse(),
        ]);
        final client = LlamaOpenAIClient(
          models: {
            'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
          },
          engine: engine,
        );
        final response = await client.responses.create(
          model: 'local',
          instructions: 'Be concise.',
          input:
              jsonDecode(
                    jsonEncode([
                      {'role': 'user', 'content': '你好'},
                      {'role': 'assistant', 'content': 'Hello'},
                      {'role': 'user', 'content': 'Continue 😀'},
                    ]),
                  )
                  as Object,
        );
        final command = engine.commands
            .whereType<LlamaGenerateMessagesCommand>()
            .single;
        expect(command.messages.map((m) => m.role), [
          'system',
          'user',
          'assistant',
          'user',
        ]);
        expect(command.messages.map((m) => m.content), [
          'Be concise.',
          '你好',
          'Hello',
          'Continue 😀',
        ]);
        expect(response.usage?.inputTokens, 21);
        expect(response.usage?.outputTokens, 5);
        expect(response.usage?.totalTokens, 26);
        expect(response.finishReason, 'length');
      },
    );

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

    test('maps engine errors to OpenAI exceptions', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: ScriptedLlamaEngine([
          const LlamaErrorResponse(message: 'runtime failed'),
        ]),
      );

      await expectLater(
        client.responses.create(model: 'local', input: 'Hello'),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'generation_failed')
              .having((error) => error.message, 'message', 'runtime failed')
              .having((error) => error.type, 'type', 'server_error'),
        ),
      );
    });

    test('preserves structured native errors in responses and chat', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: ScriptedLlamaEngine([
          const LlamaErrorResponse(
            message: 'media prompt plus requested output exceeds context',
            code: 'context_overflow',
            details: {'prompt_tokens': 271, 'max_tokens': 4096, 'n_ctx': 4096},
          ),
        ]),
      );
      final matcher = isA<LlamaOpenAIException>()
          .having((error) => error.code, 'code', 'context_overflow')
          .having(
            (error) => error.details?['prompt_tokens'],
            'prompt_tokens',
            271,
          )
          .having(
            (error) => error.message,
            'message',
            'media prompt plus requested output exceeds context',
          );
      await expectLater(
        client.responses.create(model: 'local', input: 'Hello'),
        throwsA(matcher),
      );
      await expectLater(
        client.chat.completions.create(
          model: 'local',
          messages: const [LlamaChatMessage(role: 'user', content: 'Hello')],
        ),
        throwsA(matcher),
      );
      final events = await client.responses
          .stream(model: 'local', input: 'Hello')
          .toList();
      expect(events.whereType<LlamaResponseFailed>().single.error, matcher);
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
      final engine = ScriptedLlamaEngine([
        const LlamaTokenResponse(text: 'Hello back', index: 0),
      ]);
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: engine,
      );

      final response = await client.responses.create(
        model: 'local',
        input: const [LlamaResponseInputItem(role: 'user', content: 'Hello')],
      );

      expect(response.outputText, 'Hello back');
      final generation = engine.commands
          .whereType<LlamaGenerateMessagesCommand>()
          .single;
      expect(generation.messages.single.content, 'Hello');
      expect(engine.commands.whereType<LlamaGenerateCommand>(), isEmpty);
    });
  });

  group('responses.stream', () {
    test('emits token deltas and a completed event', () async {
      final engine = ScriptedLlamaEngine([
        const LlamaTokenResponse(text: 'Hi', index: 0),
        const LlamaTokenResponse(text: ' there', index: 1),
        const LlamaDoneResponse(),
      ]);
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: engine,
      );

      final events = await client.responses
          .stream(model: 'local', input: 'Hello', maxOutputTokens: 4)
          .toList();

      expect(events.first.type, 'response.created');
      expect(
        events.whereType<LlamaResponseOutputTextDelta>().map(
          (event) => event.delta,
        ),
        ['Hi', ' there'],
      );
      expect(
        events.whereType<LlamaResponseCompleted>().single.response.outputText,
        'Hi there',
      );
    });

    test('emits failed event when the engine reports an error', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: ScriptedLlamaEngine([
          const LlamaErrorResponse(message: 'runtime failed'),
        ]),
      );

      final events = await client.responses
          .stream(model: 'local', input: 'Hello', maxOutputTokens: 4)
          .toList();

      expect(events.first.type, 'response.created');
      expect(events.last, isA<LlamaResponseFailed>());
      expect(
        (events.last as LlamaResponseFailed).error.code,
        'generation_failed',
      );
    });
  });

  group('chat.completions.create', () {
    test('maps chat messages through responses', () async {
      final engine = ScriptedLlamaEngine([
        const LlamaTokenResponse(text: 'Hello from llama.cpp', index: 0),
      ]);
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: engine,
      );

      final completion = await client.chat.completions.create(
        model: 'local',
        messages: [const LlamaChatMessage(role: 'user', content: 'Hello')],
        maxTokens: 4,
      );

      expect(completion.choices.single.message.role, 'assistant');
      expect(completion.choices.single.message.content, 'Hello from llama.cpp');
      expect(
        engine.commands,
        contains(
          isA<LlamaGenerateMessagesCommand>()
              .having((c) => c.messages.single.content, 'content', 'Hello')
              .having((c) => c.maxTokens, 'maxTokens', 4),
        ),
      );
    });
  });
}
