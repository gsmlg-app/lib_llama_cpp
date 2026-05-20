import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';

import 'backend.dart';
import 'config.dart';
import 'llcs_engine.dart';

final class LlamaHttpServer {
  LlamaHttpServer({
    required this.config,
    required ChatCompletionBackend backend,
  }) : _backend = backend;

  factory LlamaHttpServer.open({
    required LlamaServerConfig config,
    String? libraryPath,
  }) {
    final library = libraryPath ?? config.libraryPath;
    final dynamicLibrary = library == null
        ? LlamaCppDynamicLibraryLoader().open()
        : DynamicLibrary.open(library);
    final engine = LlcsEngine.open(
      library: dynamicLibrary,
      config: config.toLlcsEngineConfig(),
    );
    return LlamaHttpServer(
      config: config,
      backend: LlcsEngineBackend(engine, pollTimeout: config.pollTimeout),
    );
  }

  final LlamaServerConfig config;
  final ChatCompletionBackend _backend;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  var _closed = false;

  Future<LlamaServerAddress> start({String? host, int? port}) async {
    if (_closed) {
      throw StateError('LlamaHttpServer is closed.');
    }
    if (_server != null) {
      throw StateError('LlamaHttpServer is already started.');
    }
    final bindHost = host ?? config.host;
    final server = await HttpServer.bind(bindHost, port ?? config.port);
    _server = server;
    _subscription = server.listen((request) {
      unawaited(_handle(request));
    }, onError: (_) {});
    return LlamaServerAddress(server.address.host, server.port);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
    _backend.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/healthz') {
        await _writeJson(request.response, {
          'status': 'ok',
          'model': config.model,
          'loaded': true,
        });
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        await _writeJson(request.response, {
          'object': 'list',
          'data': [
            {
              'id': config.model,
              'object': 'model',
              'created': 0,
              'owned_by': 'lib_llama_cpp',
            },
          ],
        });
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == '/v1/chat/completions') {
        await _handleChatCompletions(request);
        return;
      }

      await _writeError(
        request.response,
        statusCode: HttpStatus.notFound,
        message: 'Unknown endpoint.',
        code: 'not_found',
      );
    } on _RequestTooLarge {
      await _writeError(
        request.response,
        statusCode: HttpStatus.requestEntityTooLarge,
        message: 'Request body is too large.',
        code: 'request_too_large',
      );
    } on FormatException catch (error) {
      await _writeError(
        request.response,
        statusCode: HttpStatus.badRequest,
        message: error.message,
        code: 'invalid_json',
      );
    } catch (error) {
      await _writeError(
        request.response,
        statusCode: HttpStatus.internalServerError,
        message: error.toString(),
        type: 'server_error',
        code: 'internal_error',
      );
    }
  }

  Future<void> _handleChatCompletions(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final validationError = _validateChatRequest(body);
    if (validationError != null) {
      await _writeError(
        request.response,
        statusCode: validationError.statusCode,
        message: validationError.message,
        param: validationError.param,
        code: validationError.code,
      );
      return;
    }

    final normalized = <String, Object?>{
      ...body,
      'model': config.model,
      'stream': body['stream'] == true,
    };

    if (normalized['stream'] == true) {
      await _streamChatCompletions(request.response, normalized);
      return;
    }

    try {
      Map<String, Object?>? finalEvent;
      await for (final event in _backend.complete(normalized)) {
        if (event.isNotEmpty) {
          finalEvent = event;
        }
      }
      await _writeJson(
        request.response,
        finalEvent ??
            {
              'error': {
                'message': 'Backend completed without a response.',
                'type': 'server_error',
                'param': null,
                'code': 'empty_response',
              },
            },
        statusCode: finalEvent == null
            ? HttpStatus.internalServerError
            : HttpStatus.ok,
      );
    } catch (error) {
      await _writeError(
        request.response,
        statusCode: HttpStatus.internalServerError,
        message: error is LlcsEngineException
            ? error.message
            : error.toString(),
        type: 'server_error',
        code: 'internal_error',
      );
    }
  }

  Future<void> _streamChatCompletions(
    HttpResponse response,
    Map<String, Object?> request,
  ) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

    try {
      await for (final event in _backend.complete(request)) {
        if (event.isEmpty) {
          continue;
        }
        response.write('data: ${jsonEncode(event)}\n\n');
        await response.flush();
      }
      response.write('data: [DONE]\n\n');
      await response.close();
    } catch (error) {
      response.write(
        'data: ${jsonEncode(_errorBody(error.toString(), type: 'server_error', code: 'internal_error'))}\n\n',
      );
      await response.close();
    }
  }

  _ChatValidationError? _validateChatRequest(Map<String, Object?> body) {
    final model = body['model'];
    if (model != null && model != config.model) {
      return _ChatValidationError(
        HttpStatus.notFound,
        'Model `$model` is not loaded.',
        param: 'model',
        code: 'model_not_found',
      );
    }

    final messages = body['messages'];
    if (messages is! List || messages.isEmpty) {
      return const _ChatValidationError(
        HttpStatus.badRequest,
        '`messages` must be a non-empty list.',
        param: 'messages',
        code: 'invalid_messages',
      );
    }

    if (_containsMedia(messages)) {
      return const _ChatValidationError(
        HttpStatus.badRequest,
        'Image and audio content are not supported in server mode yet.',
        param: 'messages',
        code: 'unsupported_model_capability',
      );
    }

    return null;
  }

  Future<Map<String, Object?>> _readJsonObject(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType?.mimeType != 'application/json') {
      throw const FormatException(
        'Request Content-Type must be application/json.',
      );
    }

    var total = 0;
    final chunks = <List<int>>[];
    await for (final chunk in request) {
      total += chunk.length;
      if (total > config.maxRequestBytes) {
        throw const _RequestTooLarge();
      }
      chunks.add(chunk);
    }

    final raw = utf8.decode(chunks.expand((chunk) => chunk).toList());
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const FormatException('Request body must be a JSON object.');
  }
}

final class LlamaServerAddress {
  const LlamaServerAddress(this.host, this.port);

  final String host;
  final int port;
}

final class _ChatValidationError {
  const _ChatValidationError(
    this.statusCode,
    this.message, {
    required this.param,
    required this.code,
  });

  final int statusCode;
  final String message;
  final String param;
  final String code;
}

final class _RequestTooLarge implements Exception {
  const _RequestTooLarge();
}

Future<void> _writeJson(
  HttpResponse response,
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
}) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> _writeError(
  HttpResponse response, {
  required int statusCode,
  required String message,
  String type = 'invalid_request_error',
  String? param,
  required String code,
}) {
  return _writeJson(
    response,
    _errorBody(message, type: type, param: param, code: code),
    statusCode: statusCode,
  );
}

Map<String, Object?> _errorBody(
  String message, {
  required String type,
  String? param,
  required String code,
}) {
  return {
    'error': {'message': message, 'type': type, 'param': param, 'code': code},
  };
}

bool _containsMedia(Object? value) {
  if (value is List) {
    return value.any(_containsMedia);
  }
  if (value is Map) {
    final type = value['type'];
    if (type is String) {
      final normalized = type.toLowerCase();
      if (normalized.contains('image') || normalized.contains('audio')) {
        return true;
      }
    }
    for (final key in value.keys) {
      final normalized = key.toString().toLowerCase();
      if (normalized.contains('image') || normalized.contains('audio')) {
        return true;
      }
    }
    return value.values.any(_containsMedia);
  }
  return false;
}
