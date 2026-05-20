import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

const _defaultModelAlias = 'gemma4-e2b';

void main() {
  final libraryPath = Platform.environment['LIB_LLAMA_CPP_TEST_LIBRARY'] ?? '';
  final modelPath = Platform.environment['LIB_LLAMA_CPP_TEST_MODEL'] ?? '';
  final modelAlias =
      Platform.environment['LIB_LLAMA_CPP_TEST_MODEL_ALIAS'] ??
      _defaultModelAlias;
  final hasRuntime = libraryPath.isNotEmpty && modelPath.isNotEmpty;

  group('Gemma 4 E2B native server API e2e', () {
    late LlamaHttpServer server;
    late Uri baseUri;

    setUpAll(() async {
      if (!hasRuntime) {
        return;
      }

      server = LlamaHttpServer.open(
        libraryPath: libraryPath,
        config: LlamaServerConfig(
          model: modelAlias,
          modelPath: modelPath,
          ctxSize: 4096,
          pollTimeout: const Duration(milliseconds: 100),
        ),
      );
      final address = await server.start(host: '127.0.0.1', port: 0);
      baseUri = Uri.parse('http://${address.host}:${address.port}');
    });

    tearDownAll(() async {
      if (hasRuntime) {
        await server.close();
      }
    });

    test('GET /healthz', () async {
      final response = await _get(baseUri.resolve('/healthz'));

      expect(response.statusCode, 200);
      expect(response.jsonBody['loaded'], isTrue);
      expect(response.jsonBody['model'], modelAlias);
    }, skip: !hasRuntime);

    test('GET /v1/models', () async {
      final response = await _get(baseUri.resolve('/v1/models'));

      expect(response.statusCode, 200);
      expect(response.jsonBody['object'], 'list');
      final data = response.jsonBody['data']! as List<Object?>;
      expect(data.single, containsPair('id', modelAlias));
    }, skip: !hasRuntime);

    test('POST /v1/chat/completions non-streaming', () async {
      final response = await _postJson(
        baseUri.resolve('/v1/chat/completions'),
        {
          'model': modelAlias,
          'messages': [
            {'role': 'user', 'content': 'Reply with one short greeting.'},
          ],
          'max_tokens': 24,
          'temperature': 0,
        },
      );

      expect(response.statusCode, 200);
      expect(response.jsonBody['choices'], isA<List<Object?>>());
    }, skip: !hasRuntime);

    test('POST /v1/chat/completions streaming', () async {
      final response = await _postJson(
        baseUri.resolve('/v1/chat/completions'),
        {
          'model': modelAlias,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'Count from one to three.'},
          ],
          'max_tokens': 32,
          'temperature': 0,
        },
      );

      expect(response.statusCode, 200);
      expect(response.body, contains('data: '));
      expect(response.body, contains('data: [DONE]'));
    }, skip: !hasRuntime);
  });
}

Future<TestResponse> _get(Uri uri) => _send('GET', uri);

Future<TestResponse> _postJson(Uri uri, Map<String, Object?> body) {
  return _send('POST', uri, body: jsonEncode(body));
}

Future<TestResponse> _send(String method, Uri uri, {String? body}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    return TestResponse(response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
}

final class TestResponse {
  const TestResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;

  Map<String, Object?> get jsonBody {
    return jsonDecode(body) as Map<String, Object?>;
  }
}
