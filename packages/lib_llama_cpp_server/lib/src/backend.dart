import 'llcs_engine.dart';

abstract interface class ChatCompletionBackend {
  Stream<Map<String, Object?>> complete(Map<String, Object?> request);

  Map<String, Object?> caps();

  void close();
}

final class LlcsEngineBackend implements ChatCompletionBackend {
  LlcsEngineBackend(
    this.engine, {
    this.pollTimeout = const Duration(milliseconds: 100),
  });

  final LlcsEngine engine;
  final Duration pollTimeout;

  @override
  Map<String, Object?> caps() => engine.caps();

  @override
  Stream<Map<String, Object?>> complete(Map<String, Object?> request) {
    return engine.stream(request, pollTimeout: pollTimeout);
  }

  @override
  void close() {
    engine.close();
  }
}
