import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

void main() {
  test('CLI preserves long context configuration', () {
    final config = LlamaServerConfig.fromArgs([
      '--model-path',
      '/model.gguf',
      '--ctx-size',
      '131072',
      '--batch-size',
      '1024',
      '--ubatch-size',
      '256',
      '--threads',
      '8',
      '--threads-batch',
      '16',
      '--flash-attn',
      'on',
      '--cache-type-k',
      'f16',
      '--cache-type-v',
      'f16',
      '--swa-full',
      'false',
      '--backend',
      'cuda',
      '--require-backend',
      'true',
      '--parallel',
      '1',
    ]);
    expect(config.toLlcsEngineConfig().toJson(), containsPair('n_batch', 1024));
    expect(
      config.toLlcsEngineConfig().toJson(),
      containsPair('flash_attn', 'on'),
    );
    expect(
      config.toLlcsEngineConfig().toJson(),
      containsPair('backend', 'cuda'),
    );
  });
  test('unknown options fail instead of silently using defaults', () {
    expect(
      () => LlamaServerConfig.fromArgs([
        '--model-path',
        '/model.gguf',
        '--ctx-sze',
        '131072',
      ]),
      throwsFormatException,
    );
  });
}
