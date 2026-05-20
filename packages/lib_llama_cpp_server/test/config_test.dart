import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaServerConfig', () {
    test('parses CLI options with defaults and typed values', () {
      final parser = buildLlamaServerArgParser();
      final args = parser.parse([
        '--library',
        '/opt/lib/liblib_llama_cpp_linux.so',
        '--model',
        '/models/local.gguf',
        '--alias',
        'local',
        '--ctx-size',
        '8192',
        '--gpu-layers',
        '0',
        '--parallel',
        '2',
        '--chat-template',
        'chatml',
        '--reasoning-format',
        'deepseek',
        '--poll-timeout-ms',
        '25',
        '--cors',
      ]);

      final config = LlamaServerConfig.fromArgResults(args);

      expect(config.libraryPath, '/opt/lib/liblib_llama_cpp_linux.so');
      expect(config.modelPath, '/models/local.gguf');
      expect(config.alias, 'local');
      expect(config.host, '127.0.0.1');
      expect(config.port, 8080);
      expect(config.contextSize, 8192);
      expect(config.gpuLayerCount, 0);
      expect(config.parallelCount, 2);
      expect(config.chatTemplate, 'chatml');
      expect(config.reasoningFormat, 'deepseek');
      expect(config.apiKey, 'no-key');
      expect(config.noAuth, isFalse);
      expect(config.cors, isTrue);
      expect(config.pollTimeout, const Duration(milliseconds: 25));
    });
  });
}
