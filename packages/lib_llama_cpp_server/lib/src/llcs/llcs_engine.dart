abstract interface class LlcsEngine {
  Future<Map<String, Object?>> caps();

  Future<int> submit(Map<String, Object?> openAIChatRequest);

  Stream<Map<String, Object?>> poll(
    int taskId, {
    Duration pollTimeout = const Duration(milliseconds: 100),
  });

  void cancel(int taskId);

  Future<void> close();
}

final class LlcsEngineException implements Exception {
  LlcsEngineException(
    this.message, {
    this.code = 'server_error',
    this.type = 'server_error',
    this.param,
    this.statusCode = 500,
  });

  final String message;
  final String code;
  final String type;
  final String? param;
  final int statusCode;

  @override
  String toString() => 'LlcsEngineException($code): $message';
}

final class UnavailableLlcsEngine implements LlcsEngine {
  var _closed = false;

  @override
  Future<Map<String, Object?>> caps() async => const {};

  @override
  void cancel(int taskId) {}

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
  }

  @override
  Stream<Map<String, Object?>> poll(
    int taskId, {
    Duration pollTimeout = const Duration(milliseconds: 100),
  }) {
    return const Stream<Map<String, Object?>>.empty();
  }

  @override
  Future<int> submit(Map<String, Object?> openAIChatRequest) {
    throw LlcsEngineException(
      'The real llcs FFI engine is not wired in this server shell yet.',
      code: 'not_implemented',
      statusCode: 501,
    );
  }
}
