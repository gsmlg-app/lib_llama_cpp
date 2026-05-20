import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaHttpServer', () {
    test('GET /healthz reports loaded model', () async {
      final fixture = await ServerFixture.start(FakeChatCompletionBackend());
      addTearDown(fixture.close);

      final response = await fixture.get('/healthz');

      expect(response.statusCode, 200);
      expect(response.jsonBody, {
        'status': 'ok',
        'model': 'local',
        'loaded': true,
      });
    });

    test('GET /v1/models returns OpenAI-shaped model list', () async {
      final fixture = await ServerFixture.start(FakeChatCompletionBackend());
      addTearDown(fixture.close);

      final response = await fixture.get('/v1/models');

      expect(response.statusCode, 200);
      expect(response.jsonBody, {
        'object': 'list',
        'data': [
          {
            'id': 'local',
            'object': 'model',
            'created': 0,
            'owned_by': 'lib_llama_cpp',
          },
        ],
      });
    });

    test('POST /v1/chat/completions returns final non-stream JSON', () async {
      final backend = FakeChatCompletionBackend(
        events: [
          {
            'id': 'chatcmpl_1',
            'object': 'chat.completion',
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'Hello'},
                'finish_reason': 'stop',
              },
            ],
          },
        ],
      );
      final fixture = await ServerFixture.start(backend);
      addTearDown(fixture.close);

      final response = await fixture.postJson('/v1/chat/completions', {
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
        'max_tokens': 32,
      });

      expect(response.statusCode, 200);
      expect(response.jsonBody['id'], 'chatcmpl_1');
      expect(backend.requests.single['stream'], isFalse);
    });

    test(
      'POST /v1/chat/completions streams SSE chunks and done sentinel',
      () async {
        final backend = FakeChatCompletionBackend(
          events: [
            {
              'choices': [
                {
                  'delta': {'content': 'Hi'},
                },
              ],
            },
            {
              'choices': [
                {'finish_reason': 'stop'},
              ],
            },
          ],
        );
        final fixture = await ServerFixture.start(backend);
        addTearDown(fixture.close);

        final response = await fixture.postJson('/v1/chat/completions', {
          'model': 'local',
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        });

        expect(response.statusCode, 200);
        expect(
          response.headers.value('content-type'),
          contains('text/event-stream'),
        );
        expect(
          response.body,
          'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n'
          'data: {"choices":[{"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        );
      },
    );

    test('invalid model returns OpenAI-shaped 404 error', () async {
      final fixture = await ServerFixture.start(FakeChatCompletionBackend());
      addTearDown(fixture.close);

      final response = await fixture.postJson('/v1/chat/completions', {
        'model': 'missing',
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 404);
      expect(response.jsonBody['error'], {
        'message': 'Model `missing` is not loaded.',
        'type': 'invalid_request_error',
        'param': 'model',
        'code': 'model_not_found',
      });
    });

    test('invalid messages returns OpenAI-shaped 400 error', () async {
      final fixture = await ServerFixture.start(FakeChatCompletionBackend());
      addTearDown(fixture.close);

      final response = await fixture.postJson('/v1/chat/completions', {
        'model': 'local',
        'messages': <Object?>[],
      });

      expect(response.statusCode, 400);
      expect(
        (response.jsonBody['error']! as Map<String, Object?>)['param'],
        'messages',
      );
    });

    test('invalid JSON request returns OpenAI-shaped 400 error', () async {
      final fixture = await ServerFixture.start(FakeChatCompletionBackend());
      addTearDown(fixture.close);

      final response = await fixture.postRaw(
        '/v1/chat/completions',
        '{not json',
      );

      expect(response.statusCode, 400);
      expect(
        (response.jsonBody['error']! as Map<String, Object?>)['code'],
        'invalid_json',
      );
    });

    test(
      'unsupported media content is rejected before backend submit',
      () async {
        final backend = FakeChatCompletionBackend();
        final fixture = await ServerFixture.start(backend);
        addTearDown(fixture.close);

        final response = await fixture.postJson('/v1/chat/completions', {
          'model': 'local',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'describe'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,aaaa'},
                },
              ],
            },
          ],
        });

        expect(response.statusCode, 400);
        expect(
          (response.jsonBody['error']! as Map<String, Object?>)['code'],
          'unsupported_model_capability',
        );
        expect(backend.requests, isEmpty);
      },
    );

    test('backend error returns OpenAI-shaped 500 error', () async {
      final fixture = await ServerFixture.start(
        FakeChatCompletionBackend(error: StateError('native failed')),
      );
      addTearDown(fixture.close);

      final response = await fixture.postJson('/v1/chat/completions', {
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 500);
      expect(
        (response.jsonBody['error']! as Map<String, Object?>)['code'],
        'internal_error',
      );
    });
  });
}

final class FakeChatCompletionBackend implements ChatCompletionBackend {
  FakeChatCompletionBackend({this.events = const [], this.error});

  final List<Map<String, Object?>> events;
  final Object? error;
  final requests = <Map<String, Object?>>[];
  var closed = false;

  @override
  Map<String, Object?> caps() => const {};

  @override
  Stream<Map<String, Object?>> complete(Map<String, Object?> request) async* {
    requests.add(request);
    if (error != null) {
      throw error!;
    }
    yield* Stream<Map<String, Object?>>.fromIterable(events);
  }

  @override
  void close() {
    closed = true;
  }
}

final class ServerFixture {
  ServerFixture._(this._server, this.baseUri);

  final LlamaHttpServer _server;
  final Uri baseUri;

  static Future<ServerFixture> start(ChatCompletionBackend backend) async {
    final server = LlamaHttpServer(
      config: const LlamaServerConfig(
        model: 'local',
        modelPath: '/models/local.gguf',
      ),
      backend: backend,
    );
    final address = await server.start(host: '127.0.0.1', port: 0);
    return ServerFixture._(
      server,
      Uri.parse('http://${address.host}:${address.port}'),
    );
  }

  Future<TestResponse> get(String path) => _send('GET', path);

  Future<TestResponse> postJson(String path, Map<String, Object?> body) {
    return _send('POST', path, body: jsonEncode(body));
  }

  Future<TestResponse> postRaw(String path, String body) {
    return _send('POST', path, body: body);
  }

  Future<TestResponse> _send(String method, String path, {String? body}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, baseUri.resolve(path));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      return TestResponse(response.statusCode, response.headers, responseBody);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() => _server.close();
}

final class TestResponse {
  const TestResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;

  Map<String, Object?> get jsonBody {
    return jsonDecode(body) as Map<String, Object?>;
  }
}
