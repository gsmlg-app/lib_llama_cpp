import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:lib_llama_cpp_server/src/llcs_engine.dart';
import 'package:test/test.dart';

void main() {
  group('LlcsEngineConfig', () {
    test('maps Dart config to llcs JSON', () {
      const config = LlcsEngineConfig(
        modelPath: '/models/local.gguf',
        nCtx: 32768,
        nGpuLayers: 99,
        nParallel: 4,
        chatTemplate: 'chatml',
        reasoningFormat: 'deepseek',
      );

      expect(config.toJson(), {
        'model_path': '/models/local.gguf',
        'n_ctx': 32768,
        'n_gpu_layers': 99,
        'n_parallel': 4,
        'chat_template': 'chatml',
        'reasoning_format': 'deepseek',
        'use_jinja': true,
      });
    });
  });

  group('LlcsEngine', () {
    test('create failure accepts message-shaped native error JSON', () {
      final bindings = FakeLlcsNativeBindings(
        createResult: nullptr,
        createError: {'message': 'model missing'},
      );

      expect(
        () => LlcsEngine.withBindings(
          bindings: bindings,
          config: const LlcsEngineConfig(modelPath: '/missing.gguf'),
        ),
        throwsA(
          isA<LlcsEngineException>()
              .having((error) => error.message, 'message', 'model missing')
              .having((error) => error.nativeJson, 'nativeJson', {
                'message': 'model missing',
              }),
        ),
      );
      expect(bindings.freedStrings, hasLength(1));
    });

    test('create failure accepts legacy error-shaped native JSON', () {
      final bindings = FakeLlcsNativeBindings(
        createResult: nullptr,
        createError: {'error': 'bad params'},
      );

      expect(
        () => LlcsEngine.withBindings(
          bindings: bindings,
          config: const LlcsEngineConfig(modelPath: '/missing.gguf'),
        ),
        throwsA(
          isA<LlcsEngineException>().having(
            (error) => error.message,
            'message',
            'bad params',
          ),
        ),
      );
    });

    test('caps frees returned native strings', () {
      final bindings = FakeLlcsNativeBindings(
        capsResult: {'supports_tools': true},
      );
      final engine = LlcsEngine.withBindings(
        bindings: bindings,
        config: const LlcsEngineConfig(modelPath: '/models/local.gguf'),
      );

      expect(engine.caps(), {'supports_tools': true});
      expect(bindings.freedStrings, hasLength(1));
    });

    test('submit failure throws typed exception and frees native error', () {
      final bindings = FakeLlcsNativeBindings(
        submitResult: -1,
        submitError: {'message': 'parse failed'},
      );
      final engine = LlcsEngine.withBindings(
        bindings: bindings,
        config: const LlcsEngineConfig(modelPath: '/models/local.gguf'),
      );

      expect(
        () => engine.submit({'model': 'local'}),
        throwsA(
          isA<LlcsEngineException>().having(
            (error) => error.message,
            'message',
            'parse failed',
          ),
        ),
      );
      expect(bindings.freedStrings, hasLength(1));
    });

    test('poll distinguishes timeout, event, and drained states', () {
      final bindings = FakeLlcsNativeBindings(
        pollResults: [
          '',
          jsonEncode({'choices': <Object?>[]}),
          null,
        ],
      );
      final engine = LlcsEngine.withBindings(
        bindings: bindings,
        config: const LlcsEngineConfig(modelPath: '/models/local.gguf'),
      );

      expect(engine.poll(1), isEmpty);
      expect(engine.poll(1), {'choices': <Object?>[]});
      expect(engine.poll(1), isNull);
      expect(bindings.freedStrings, hasLength(2));
    });

    test(
      'stream skips poll timeouts and cancels on listener cancellation',
      () async {
        final bindings = FakeLlcsNativeBindings(
          submitResult: 7,
          pollResults: [
            '',
            jsonEncode({'delta': 'a'}),
            '',
            jsonEncode({'delta': 'b'}),
          ],
        );
        final engine = LlcsEngine.withBindings(
          bindings: bindings,
          config: const LlcsEngineConfig(modelPath: '/models/local.gguf'),
        );

        final events = await engine.stream({'model': 'local'}).take(2).toList();

        expect(events, [
          {'delta': 'a'},
          {'delta': 'b'},
        ]);
        expect(bindings.cancelledTaskIds, [7]);
      },
    );

    test('close is idempotent', () {
      final bindings = FakeLlcsNativeBindings();
      final engine = LlcsEngine.withBindings(
        bindings: bindings,
        config: const LlcsEngineConfig(modelPath: '/models/local.gguf'),
      );

      engine.close();
      engine.close();

      expect(bindings.destroyCount, 1);
    });
  });
}

final class FakeLlcsNativeBindings implements LlcsNativeBindings {
  FakeLlcsNativeBindings({
    Pointer<llcs_engine>? createResult,
    this.createError,
    this.capsResult = const {},
    this.submitResult = 1,
    this.submitError,
    this.pollResults = const [],
  }) : createResult = createResult ?? Pointer<llcs_engine>.fromAddress(1);

  final Pointer<llcs_engine> createResult;
  final Map<String, Object?>? createError;
  final Map<String, Object?> capsResult;
  final int submitResult;
  final Map<String, Object?>? submitError;
  final List<String?> pollResults;
  final freedStrings = <String>[];
  final cancelledTaskIds = <int>[];
  var destroyCount = 0;
  var _pollIndex = 0;

  @override
  Pointer<llcs_engine> create(
    Pointer<Char> paramsJson,
    Pointer<Pointer<Char>> errorOut,
  ) {
    if (createError != null) {
      errorOut.value = _nativeJson(createError!);
    }
    return createResult;
  }

  @override
  void destroy(Pointer<llcs_engine> engine) {
    destroyCount += 1;
  }

  @override
  Pointer<Char> caps(Pointer<llcs_engine> engine) {
    return _nativeJson(capsResult);
  }

  @override
  int submit(
    Pointer<llcs_engine> engine,
    Pointer<Char> requestJson,
    Pointer<Pointer<Char>> errorOut,
  ) {
    if (submitError != null) {
      errorOut.value = _nativeJson(submitError!);
    }
    return submitResult;
  }

  @override
  Pointer<Char> poll(Pointer<llcs_engine> engine, int taskId, int timeoutMs) {
    if (_pollIndex >= pollResults.length) {
      return nullptr;
    }
    final result = pollResults[_pollIndex++];
    if (result == null) {
      return nullptr;
    }
    return result.toNativeUtf8().cast<Char>();
  }

  @override
  void cancel(Pointer<llcs_engine> engine, int taskId) {
    cancelledTaskIds.add(taskId);
  }

  @override
  void stringFree(Pointer<Char> string) {
    freedStrings.add(string.cast<Utf8>().toDartString());
    calloc.free(string);
  }

  Pointer<Char> _nativeJson(Map<String, Object?> value) {
    return jsonEncode(value).toNativeUtf8().cast<Char>();
  }
}
