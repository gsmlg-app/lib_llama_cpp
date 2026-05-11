import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads the mobile native plugin and runs the isolate stream', (
    _,
  ) async {
    expect(Platform.isAndroid || Platform.isIOS, isTrue);
    expect(_stubAbiVersion(), 1);

    final responses = await const LibLlamaCpp()
        .transform(
          Stream<LlamaCommand>.fromIterable([
            const LlamaLoadModelCommand(modelPath: '/models/mobile-smoke.gguf'),
            const LlamaGenerateCommand(
              prompt: 'Say hello in one short sentence.',
              maxTokens: 8,
            ),
            const LlamaDisposeCommand(),
          ]),
        )
        .timeout(const Duration(seconds: 10))
        .toList();

    expect(responses.whereType<LlamaReadyResponse>(), hasLength(1));
    expect(responses.whereType<LlamaDoneResponse>(), hasLength(1));

    final errors = responses.whereType<LlamaErrorResponse>().toList();
    expect(errors, hasLength(1));
    expect(
      errors.single.message,
      'Native llama.cpp generation is not wired yet.',
    );

    final client = LlamaOpenAIClient(
      models: {
        'mobile-smoke': const LlamaModelConfig(
          modelPath: '/models/mobile-smoke.gguf',
        ),
      },
    );

    await expectLater(
      client.responses
          .create(
            model: 'mobile-smoke',
            input: 'Say hello in one short sentence.',
            maxOutputTokens: 8,
          )
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<LlamaOpenAIException>()
            .having((error) => error.code, 'code', 'generation_failed')
            .having(
              (error) => error.message,
              'message',
              'Native llama.cpp generation is not wired yet.',
            ),
      ),
    );

    final events = await client.responses
        .stream(
          model: 'mobile-smoke',
          input: const [
            LlamaResponseInputItem(
              role: 'user',
              content: 'Say hello in one short sentence.',
            ),
          ],
          maxOutputTokens: 8,
        )
        .timeout(const Duration(seconds: 10))
        .toList();

    expect(events.first.type, 'response.created');
    expect(events.last, isA<LlamaResponseFailed>());
    expect(
      (events.last as LlamaResponseFailed).error.message,
      'Native llama.cpp generation is not wired yet.',
    );

    await expectLater(
      client.chat.completions
          .create(
            model: 'mobile-smoke',
            messages: [
              const LlamaChatMessage(
                role: 'user',
                content: 'Say hello in one short sentence.',
              ),
            ],
            maxTokens: 8,
          )
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<LlamaOpenAIException>().having(
          (error) => error.code,
          'code',
          'generation_failed',
        ),
      ),
    );
  });
}

int _stubAbiVersion() {
  final library = _openMobileNativeLibrary();
  final abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
    'lib_llama_cpp_stub_abi_version',
  );
  return abiVersion();
}

DynamicLibrary _openMobileNativeLibrary() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('liblib_llama_cpp_android.so');
  }

  if (Platform.isIOS) {
    final errors = <Object>[];
    for (final candidate in <String>[
      'lib_llama_cpp_ios.framework/lib_llama_cpp_ios',
      'lib_llama_cpp_ios',
    ]) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object catch (error) {
        errors.add(error);
      }
    }

    try {
      return DynamicLibrary.process();
    } on Object catch (error) {
      errors.add(error);
    }

    throw StateError('Could not open the iOS native plugin library: $errors');
  }

  throw UnsupportedError('Mobile E2E only supports Android and iOS.');
}
