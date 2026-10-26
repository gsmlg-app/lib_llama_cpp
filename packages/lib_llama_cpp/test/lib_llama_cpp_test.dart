import 'dart:async';
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
  test('resolves the native library before loading a model', () async {
    final platform = FakeLibLlamaCppPlatform();
    final client = LibLlamaCpp(platform: platform);

    final responses = await client
        .transform(
          Stream<LlamaCommand>.value(
            const LlamaLoadModelCommand(modelPath: '/models/tiny.gguf'),
          ),
        )
        .toList();

    expect(platform.resolveCount, 1);
    expect(responses.first, isA<LlamaReadyResponse>());
    expect(responses.last, isA<LlamaErrorResponse>());
    expect(
      (responses.last as LlamaErrorResponse).message,
      contains('Failed to open llama.cpp library'),
    );
  });

  test(
    'resident engine acknowledges shutdown and rejects later requests',
    () async {
      final platform = FakeLibLlamaCppPlatform();
      final engine = ResidentLlamaEngine(platform: platform);
      final commands = [
        const LlamaLoadModelCommand(modelPath: '/models/tiny.gguf'),
        const LlamaDisposeCommand(),
      ];
      for (var request = 0; request < 2; request++) {
        final responses = await engine
            .transform(Stream.fromIterable(commands))
            .toList();
        expect(responses.whereType<LlamaErrorResponse>(), hasLength(1));
      }
      final close = engine.close();
      expect(identical(close, engine.close()), isTrue);
      await close.timeout(const Duration(seconds: 5));
      final responses = await engine
          .transform(Stream.fromIterable(commands))
          .toList();
      expect(
        responses.single,
        const LlamaErrorResponse(message: 'Resident engine is closed.'),
      );
      expect(platform.resolveCount, 2);
    },
  );

  test('resident close completes while the consumer is paused', () async {
    final engine = ResidentLlamaEngine(platform: FakeLibLlamaCppPlatform());
    final ready = Completer<void>();
    late final StreamSubscription<LlamaResponse> subscription;
    subscription = engine.transform(const Stream<LlamaCommand>.empty()).listen((
      event,
    ) {
      subscription.pause();
      ready.complete();
    });
    await ready.future;
    await engine.close().timeout(const Duration(seconds: 5));
    await subscription.cancel();
  });

  test(
    'canceling a queued request does not wait for a paused request',
    () async {
      final platform = FakeLibLlamaCppPlatform();
      final engine = ResidentLlamaEngine(platform: platform);
      final ready = Completer<void>();
      late final StreamSubscription<LlamaResponse> active;
      active = engine.transform(const Stream<LlamaCommand>.empty()).listen((
        event,
      ) {
        active.pause();
        ready.complete();
      });
      await ready.future;
      final queued = engine
          .transform(const Stream<LlamaCommand>.empty())
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);
      try {
        await expectLater(
          queued.cancel().timeout(const Duration(milliseconds: 250)),
          completes,
        );
        final successor = engine
            .transform(const Stream<LlamaCommand>.empty())
            .drain<void>();
        await Future<void>.delayed(Duration.zero);
        expect(platform.resolveCount, 1);
        active.resume();
        await successor.timeout(const Duration(seconds: 5));
        expect(platform.resolveCount, 2);
      } finally {
        await engine.close();
        await active.cancel();
      }
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
