import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class LlamaServerClient {
  LlamaServerClient({required Uri baseUri, this.apiKey})
    : baseUri = _normalizeBaseUri(baseUri);

  final Uri baseUri;
  final String? apiKey;

  Future<Map<String, Object?>> createChatCompletion({
    required String model,
    required List<Map<String, Object?>> messages,
    int? maxTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
  }) async {
    final response = await _postJson(
      'chat/completions',
      _chatRequest(
        model: model,
        messages: messages,
        stream: false,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        stop: stop,
      ),
    );
    return jsonDecode(response) as Map<String, Object?>;
  }

  Stream<Map<String, Object?>> streamChatCompletion({
    required String model,
    required List<Map<String, Object?>> messages,
    int? maxTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
  }) async* {
    final client = HttpClient();
    try {
      final request = await client.postUrl(_endpoint('chat/completions'));
      _configureHeaders(request);
      request.write(
        jsonEncode(
          _chatRequest(
            model: model,
            messages: messages,
            stream: true,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stop: stop,
          ),
        ),
      );

      final response = await request.close();
      await for (final event in _parseSse(response)) {
        yield event;
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _postJson(String path, Map<String, Object?> body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(_endpoint(path));
      _configureHeaders(request);
      request.write(jsonEncode(body));
      final response = await request.close();
      return utf8.decodeStream(response);
    } finally {
      client.close(force: true);
    }
  }

  void _configureHeaders(HttpClientRequest request) {
    request.headers.contentType = ContentType.json;
    if (apiKey != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
  }

  Uri _endpoint(String path) {
    return baseUri.replace(path: '${baseUri.path}/$path');
  }
}

Map<String, Object?> _chatRequest({
  required String model,
  required List<Map<String, Object?>> messages,
  required bool stream,
  int? maxTokens,
  double? temperature,
  double? topP,
  required List<String> stop,
}) {
  final request = <String, Object?>{
    'model': model,
    'messages': messages,
    'stream': stream,
  };
  if (maxTokens != null) {
    request['max_tokens'] = maxTokens;
  }
  if (temperature != null) {
    request['temperature'] = temperature;
  }
  if (topP != null) {
    request['top_p'] = topP;
  }
  if (stop.isNotEmpty) {
    request['stop'] = stop;
  }
  return request;
}

Stream<Map<String, Object?>> _parseSse(HttpClientResponse response) async* {
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data:')) {
      continue;
    }
    final data = line.substring(5).trim();
    if (data.isEmpty) {
      continue;
    }
    if (data == '[DONE]') {
      break;
    }
    yield jsonDecode(data) as Map<String, Object?>;
  }
}

Uri _normalizeBaseUri(Uri uri) {
  final normalizedPath = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return uri.replace(path: normalizedPath);
}
