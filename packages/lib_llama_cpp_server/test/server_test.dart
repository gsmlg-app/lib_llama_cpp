import 'dart:async';
import 'dart:convert';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaServer', () {
    test('health reports model and active request state', () async {
      final server = _server(FakeLlcsEngine(capsPayload: {'chat': true}));

      final response = await _request(server, 'GET', '/health');
      final body = await _json(response);

      expect(response.statusCode, 200);
      expect(body, {
        'status': 'ok',
        'model': 'local',
        'model_path': '/models/local.gguf',
        'engine': 'llcs',
        'caps': {'chat': true},
        'active_requests': 0,
      });
    });

    test('models returns one OpenAI-compatible loaded model', () async {
      final server = _server(FakeLlcsEngine(capsPayload: {'chat': true}));

      final response = await _request(server, 'GET', '/v1/models');
      final body = await _json(response);

      expect(response.statusCode, 200);
      expect(body['object'], 'list');
      expect(body['data'], [
        {
          'id': 'local',
          'object': 'model',
          'created': 0,
          'owned_by': 'llamacpp',
          'meta': {
            'model_path': '/models/local.gguf',
            'caps': {'chat': true},
          },
        },
      ]);
    });

    test('chat completions rejects missing messages', () async {
      final server = _server(FakeLlcsEngine());

      final response = await _jsonRequest(server, '/v1/chat/completions', {
        'model': 'local',
      });
      final body = await _json(response);
      final error = body['error']! as Map<String, Object?>;

      expect(response.statusCode, 400);
      expect(error['code'], 'invalid_request_error');
      expect(error['param'], 'messages');
    });

    test('chat completions requires bearer auth by default', () async {
      final server = _server(FakeLlcsEngine());

      final response = await _jsonRequest(server, '/v1/chat/completions', {
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      }, authorize: false);
      final body = await _json(response);
      final error = body['error']! as Map<String, Object?>;

      expect(response.statusCode, 401);
      expect(error['code'], 'unauthorized');
    });

    test('chat completions submits normalized non-streaming request', () async {
      final engine = FakeLlcsEngine(
        events: {
          1: [
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
        },
      );
      final server = _server(engine);

      final response = await _jsonRequest(server, '/v1/chat/completions', {
        'model': '/models/local.gguf',
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });
      final body = await _json(response);

      expect(response.statusCode, 200);
      expect(body['id'], 'chatcmpl_1');
      expect(engine.submissions.single['model'], 'local');
      expect(engine.submissions.single['stream'], isFalse);
    });

    test('responses converts simple input through chat completions', () async {
      final engine = FakeLlcsEngine(
        events: {
          1: [
            {
              'id': 'chatcmpl_1',
              'choices': [
                {
                  'message': {'content': 'Hello from chat'},
                },
              ],
            },
          ],
        },
      );
      final server = _server(engine);

      final response = await _jsonRequest(server, '/v1/responses', {
        'model': 'local',
        'instructions': 'Be concise.',
        'input': 'Say hello.',
        'max_output_tokens': 16,
        'temperature': 0.2,
      });
      final body = await _json(response);

      expect(response.statusCode, 200);
      expect(body['object'], 'response');
      expect(body['model'], 'local');
      expect(body['status'], 'completed');
      expect(body['output_text'], 'Hello from chat');
      expect(engine.submissions.single, {
        'model': 'local',
        'messages': [
          {'role': 'system', 'content': 'Be concise.'},
          {'role': 'user', 'content': 'Say hello.'},
        ],
        'max_tokens': 16,
        'temperature': 0.2,
        'stream': false,
      });
    });

    test('streaming chat completions formats SSE and done sentinel', () async {
      final engine = FakeLlcsEngine(
        events: {
          1: [
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
        },
      );
      final server = _server(engine);

      final response = await _jsonRequest(server, '/v1/chat/completions', {
        'model': 'local',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/event-stream'));
      expect(
        body,
        'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n'
        'data: {"choices":[{"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      );
    });

    test('client disconnect cancels active streaming task', () async {
      final engine = FakeLlcsEngine(
        events: {
          1: [
            {
              'choices': [
                {
                  'delta': {'content': 'Hi'},
                },
              ],
            },
          ],
        },
        keepPolling: true,
      );
      final server = _server(engine);
      final response = await _jsonRequest(server, '/v1/chat/completions', {
        'model': 'local',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });

      final subscription = response.read().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(engine.cancelledTaskIds, [1]);
    });
  });

  group('LlamaServer.close', () {
    test('closes the engine idempotently', () async {
      final engine = CloseTrackingLlcsEngine();
      final server = _server(engine);

      await server.close();
      await server.close();

      expect(engine.closeCount, 1);
    });
  });
}

LlamaServer _server(LlcsEngine engine) {
  return LlamaServer(
    config: const LlamaServerConfig(
      libraryPath: '/opt/lib/liblib_llama_cpp_linux.so',
      modelPath: '/models/local.gguf',
    ),
    engine: engine,
  );
}

Future<Response> _request(
  LlamaServer server,
  String method,
  String path, {
  Object? body,
  Map<String, String>? headers,
}) {
  final request = Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: headers ?? const {},
  );
  return Future<Response>.value(server.handler(request));
}

Future<Response> _jsonRequest(
  LlamaServer server,
  String path,
  Map<String, Object?> body, {
  bool authorize = true,
}) {
  return _request(
    server,
    'POST',
    path,
    body: body,
    headers: {
      'content-type': 'application/json',
      if (authorize) 'authorization': 'Bearer no-key',
    },
  );
}

Future<Map<String, Object?>> _json(Response response) async {
  return jsonDecode(await response.readAsString()) as Map<String, Object?>;
}

final class FakeLlcsEngine implements LlcsEngine {
  FakeLlcsEngine({
    this.capsPayload = const {},
    this.events = const {},
    this.keepPolling = false,
  });

  final Map<String, Object?> capsPayload;
  final Map<int, List<Map<String, Object?>>> events;
  final bool keepPolling;
  final submissions = <Map<String, Object?>>[];
  final cancelledTaskIds = <int>[];
  var _nextTaskId = 1;

  @override
  Future<Map<String, Object?>> caps() async => capsPayload;

  @override
  void cancel(int taskId) {
    cancelledTaskIds.add(taskId);
  }

  @override
  Future<void> close() async {}

  @override
  Stream<Map<String, Object?>> poll(
    int taskId, {
    Duration pollTimeout = const Duration(milliseconds: 100),
  }) {
    final taskEvents = events[taskId] ?? const <Map<String, Object?>>[];
    if (!keepPolling) {
      return Stream<Map<String, Object?>>.fromIterable(taskEvents);
    }

    late final StreamController<Map<String, Object?>> controller;
    controller = StreamController<Map<String, Object?>>(
      onListen: () {
        scheduleMicrotask(() {
          if (controller.isClosed) {
            return;
          }
          for (final event in taskEvents) {
            controller.add(event);
          }
        });
      },
      onCancel: () {},
    );
    return controller.stream;
  }

  @override
  Future<int> submit(Map<String, Object?> openAIChatRequest) async {
    submissions.add(openAIChatRequest);
    return _nextTaskId++;
  }
}

final class CloseTrackingLlcsEngine implements LlcsEngine {
  var closeCount = 0;
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
    closeCount += 1;
  }

  @override
  Stream<Map<String, Object?>> poll(
    int taskId, {
    Duration pollTimeout = const Duration(milliseconds: 100),
  }) {
    return const Stream.empty();
  }

  @override
  Future<int> submit(Map<String, Object?> openAIChatRequest) async => 1;
}
