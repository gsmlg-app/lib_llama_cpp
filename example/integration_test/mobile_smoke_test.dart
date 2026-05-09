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
