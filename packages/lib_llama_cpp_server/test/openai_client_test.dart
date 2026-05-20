import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaServerClient', () {
    test('builds non-stream chat completion requests', () async {
      final fixture = await ClientServerFixture.start((request) async {
        final body = await utf8.decodeStream(request);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'seen': jsonDecode(body)}));
        await request.response.close();
      });
      addTearDown(fixture.close);

      final response = await fixture.client.createChatCompletion(
        model: 'local',
        messages: [
          {'role': 'user', 'content': 'hello'},
        ],
        maxTokens: 16,
        temperature: 0.2,
        topP: 0.9,
        stop: const ['</s>'],
      );

      expect(response['seen'], {
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
        'stream': false,
        'max_tokens': 16,
        'temperature': 0.2,
        'top_p': 0.9,
        'stop': ['</s>'],
      });
    });

    test('parses streaming SSE chat completion events', () async {
      final fixture = await ClientServerFixture.start((request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write('data: {"delta":"a"}\n\n');
        request.response.write('data: {"delta":"b"}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final events = await fixture.client
          .streamChatCompletion(
            model: 'local',
            messages: [
              {'role': 'user', 'content': 'hello'},
            ],
          )
          .toList();

      expect(events, [
        {'delta': 'a'},
        {'delta': 'b'},
      ]);
    });
  });
}

final class ClientServerFixture {
  ClientServerFixture._(this.server, this.client);

  final HttpServer server;
  final LlamaServerClient client;

  static Future<ClientServerFixture> start(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    unawaited(server.forEach(handler));
    final client = LlamaServerClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/v1'),
    );
    return ClientServerFixture._(server, client);
  }

  Future<void> close() => server.close(force: true);
}
