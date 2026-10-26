import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp/src/native_runtime.dart';

void main() {
  test('native context overflow retains its code and budget fields', () {
    final error = NativeLlamaException.fromNativeError(
      '{"code":"context_overflow","type":"context_overflow",'
      '"message":"media prompt plus requested output exceeds context",'
      '"prompt_tokens":271,"prompt_positions":267,"max_tokens":4096,"n_ctx":4096}',
    );

    expect(error.code, 'context_overflow');
    expect(error.details, {
      'prompt_tokens': 271,
      'prompt_positions': 267,
      'max_tokens': 4096,
      'n_ctx': 4096,
    });
    expect(error.message, 'media prompt plus requested output exceeds context');
  });

  test(
    'legacy native messages and error response formatting are preserved',
    () {
      final error = NativeLlamaException.fromNativeError(
        'plain native failure',
      );
      expect(error.message, 'plain native failure');
      expect(error.code, isNull);
      expect(error.details, isNull);
      expect(error.toString(), 'plain native failure');
      const response = LlamaErrorResponse(message: 'failure');
      expect(response, const LlamaErrorResponse(message: 'failure'));
      expect(response.hashCode, 'failure'.hashCode);
      expect(response.toString(), 'LlamaErrorResponse(message: failure)');
    },
  );
}
