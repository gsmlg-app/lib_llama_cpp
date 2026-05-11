import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

const _dartDefineModelPath = String.fromEnvironment('LIB_LLAMA_CPP_TEST_MODEL');
const _smokePrompt = String.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_PROMPT',
  defaultValue: 'Say hello in one short sentence.',
);
const _smokeTokens = int.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_TOKENS',
  defaultValue: 8,
);

String get _testModelPath {
  if (_dartDefineModelPath.isNotEmpty) {
    return _dartDefineModelPath;
  }
  return Platform.environment['LIB_LLAMA_CPP_TEST_MODEL'] ?? '';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final modelPath = _testModelPath;

  testWidgets(
    'loads the mobile plugin and completes a real-model generate command',
    (_) async {
      expect(Platform.isAndroid || Platform.isIOS, isTrue);

      final responses = await const LibLlamaCpp()
          .transform(
            Stream<LlamaCommand>.fromIterable([
              LlamaLoadModelCommand(modelPath: modelPath),
              const LlamaGenerateCommand(
                prompt: _smokePrompt,
                maxTokens: _smokeTokens,
              ),
              const LlamaDisposeCommand(),
            ]),
          )
          .timeout(const Duration(minutes: 2))
          .toList();

      expect(responses.whereType<LlamaReadyResponse>(), hasLength(1));
      expect(responses.whereType<LlamaErrorResponse>(), isEmpty);
      expect(responses.whereType<LlamaDoneResponse>(), hasLength(1));

      expect(responses.last, isA<LlamaDoneResponse>());
    },
    skip: modelPath.isEmpty,
  );
}
