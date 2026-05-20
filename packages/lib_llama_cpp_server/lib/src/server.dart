import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'llcs/llcs_engine.dart';
import 'routes/chat_completions.dart';
import 'routes/health.dart';
import 'routes/models.dart';
import 'routes/responses.dart';

final class LlamaServer {
  LlamaServer({required this.config, required LlcsEngine engine})
    : _engine = engine;

  final LlamaServerConfig config;
  final LlcsEngine _engine;
  final Set<int> _activeTasks = <int>{};
  var _activeRequests = 0;
  var _closed = false;
  Future<Map<String, Object?>>? _capsFuture;

  Handler get handler {
    final router = Router()
      ..get('/health', _handleHealth)
      ..get('/v1/models', _handleModels)
      ..post('/v1/chat/completions', _handleChatCompletions)
      ..post('/v1/responses', _handleResponses);

    Handler handler = router.call;
    if (config.cors) {
      handler = _withCors(handler);
    }
    return handler;
  }

  int get activeRequestCount => _activeRequests;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    cancelActiveTasks();
    await _engine.close();
  }

  void cancelActiveTasks() {
    for (final taskId in _activeTasks.toList(growable: false)) {
      _engine.cancel(taskId);
    }
    _activeTasks.clear();
  }

  Future<Map<String, Object?>> caps() {
    return _capsFuture ??= _engine.caps();
  }

  Future<Response> _handleHealth(Request request) async {
    return healthResponse(
      config: config,
      caps: await caps(),
      activeRequests: activeRequestCount,
    );
  }

  Future<Response> _handleModels(Request request) async {
    return modelsResponse(config: config, caps: await caps());
  }

  Future<Response> _handleChatCompletions(Request request) async {
    final authResponse = _authorize(request);
    if (authResponse != null) {
      return authResponse;
    }

    final bodyResult = await _readJsonObject(request);
    if (bodyResult.error != null) {
      return bodyResult.error!;
    }

    final normalized = normalizeChatCompletionRequest(
      bodyResult.value!,
      alias: config.alias,
      modelPath: config.modelPath,
    );
    if (normalized.error != null) {
      return normalized.error!;
    }

    final chatRequest = normalized.value!;
    if (chatRequest['stream'] == true) {
      return _streamChatCompletion(chatRequest);
    }
    return _completeChatCompletion(chatRequest);
  }

  Future<Response> _completeChatCompletion(
    Map<String, Object?> chatRequest,
  ) async {
    var taskRegistered = false;
    int? taskId;
    _activeRequests += 1;
    try {
      taskId = await _engine.submit(chatRequest);
      _activeTasks.add(taskId);
      taskRegistered = true;

      Map<String, Object?>? lastEvent;
      await for (final event in _engine.poll(
        taskId,
        pollTimeout: config.pollTimeout,
      )) {
        lastEvent = event;
      }

      if (lastEvent == null) {
        return openAIErrorResponse(
          statusCode: 502,
          message: 'llcs completed without a response body.',
          code: 'empty_response',
        );
      }
      return jsonResponse(lastEvent);
    } on LlcsEngineException catch (error) {
      return engineErrorResponse(error);
    } finally {
      if (taskRegistered && taskId != null) {
        _activeTasks.remove(taskId);
      }
      _activeRequests -= 1;
    }
  }

  Future<Response> _streamChatCompletion(
    Map<String, Object?> chatRequest,
  ) async {
    int? taskId;
    _activeRequests += 1;
    try {
      taskId = await _engine.submit(chatRequest);
      _activeTasks.add(taskId);
    } on LlcsEngineException catch (error) {
      _activeRequests -= 1;
      return engineErrorResponse(error);
    }

    var completed = false;
    var cleanedUp = false;
    StreamSubscription<Map<String, Object?>>? pollSubscription;
    late final StreamController<List<int>> body;

    void cleanup({required bool cancel}) {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;
      _activeTasks.remove(taskId);
      _activeRequests -= 1;
      if (cancel) {
        _engine.cancel(taskId!);
      }
    }

    body = StreamController<List<int>>(
      onListen: () {
        pollSubscription = _engine
            .poll(taskId!, pollTimeout: config.pollTimeout)
            .listen(
              (event) {
                body.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
              },
              onError: (Object error, StackTrace stackTrace) {
                body.addError(error, stackTrace);
                cleanup(cancel: false);
                unawaited(body.close());
              },
              onDone: () {
                completed = true;
                body.add(utf8.encode('data: [DONE]\n\n'));
                cleanup(cancel: false);
                unawaited(body.close());
              },
            );
      },
      onCancel: () async {
        if (!completed) {
          cleanup(cancel: true);
        }
        await pollSubscription?.cancel();
      },
    );

    return Response.ok(
      body.stream,
      headers: const {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  Future<Response> _handleResponses(Request request) async {
    final authResponse = _authorize(request);
    if (authResponse != null) {
      return authResponse;
    }

    final bodyResult = await _readJsonObject(request);
    if (bodyResult.error != null) {
      return bodyResult.error!;
    }

    final converted = convertResponsesRequest(
      bodyResult.value!,
      alias: config.alias,
      modelPath: config.modelPath,
    );
    if (converted.error != null) {
      return converted.error!;
    }

    final chatRequest = converted.value!;
    if (chatRequest['stream'] == true) {
      return _streamChatCompletion(chatRequest);
    }

    final chatResponse = await _completeChatCompletion(chatRequest);
    if (chatResponse.statusCode >= 400) {
      return chatResponse;
    }

    final chatBody =
        jsonDecode(await chatResponse.readAsString()) as Map<String, Object?>;
    return jsonResponse(responseBodyFromChatCompletion(chatBody, config.alias));
  }

  Response? _authorize(Request request) {
    if (config.noAuth) {
      return null;
    }

    final authorization = request.headers['authorization'];
    if (authorization == 'Bearer ${config.apiKey}') {
      return null;
    }

    return openAIErrorResponse(
      statusCode: 401,
      message: 'Missing or invalid bearer token.',
      type: 'authentication_error',
      code: 'unauthorized',
    );
  }

  Handler _withCors(Handler inner) {
    return (request) async {
      final headers = {
        'access-control-allow-origin': '*',
        'access-control-allow-headers': 'authorization, content-type',
        'access-control-allow-methods': 'GET, POST, OPTIONS',
      };
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await inner(request);
      return response.change(headers: headers);
    };
  }
}

Future<_JsonBodyResult> _readJsonObject(Request request) async {
  final contentType = request.headers['content-type'];
  if (contentType == null || !contentType.contains('application/json')) {
    return _JsonBodyResult.error(
      openAIErrorResponse(
        statusCode: 400,
        message: 'Request body must be JSON.',
        code: 'invalid_request_error',
      ),
    );
  }

  final rawBody = await request.readAsString();
  final Object? decoded;
  try {
    decoded = jsonDecode(rawBody);
  } on FormatException {
    return _JsonBodyResult.error(
      openAIErrorResponse(
        statusCode: 400,
        message: 'Request body is not valid JSON.',
        code: 'invalid_request_error',
      ),
    );
  }

  if (decoded case final Map<String, Object?> body) {
    return _JsonBodyResult.value(body);
  }

  return _JsonBodyResult.error(
    openAIErrorResponse(
      statusCode: 400,
      message: 'Request body must be a JSON object.',
      code: 'invalid_request_error',
    ),
  );
}

Response jsonResponse(Map<String, Object?> body, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Response openAIErrorResponse({
  required int statusCode,
  required String message,
  String type = 'invalid_request_error',
  String code = 'invalid_request_error',
  String? param,
}) {
  return jsonResponse({
    'error': {'message': message, 'type': type, 'param': param, 'code': code},
  }, statusCode: statusCode);
}

Response engineErrorResponse(LlcsEngineException error) {
  return openAIErrorResponse(
    statusCode: error.statusCode,
    message: error.message,
    type: error.type,
    code: error.code,
    param: error.param,
  );
}

final class _JsonBodyResult {
  const _JsonBodyResult._({this.value, this.error});

  factory _JsonBodyResult.value(Map<String, Object?> value) {
    return _JsonBodyResult._(value: value);
  }

  factory _JsonBodyResult.error(Response error) {
    return _JsonBodyResult._(error: error);
  }

  final Map<String, Object?>? value;
  final Response? error;
}

final class RouteResult {
  const RouteResult._({this.value, this.error});

  factory RouteResult.value(Map<String, Object?> value) {
    return RouteResult._(value: value);
  }

  factory RouteResult.error(Response error) {
    return RouteResult._(error: error);
  }

  final Map<String, Object?>? value;
  final Response? error;
}
