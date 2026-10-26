import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';

import 'backend.dart';
import 'config.dart';
import 'llcs_engine.dart';
import 'llcs_worker_engine.dart';

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
    final dynamicLibrary = LlamaCppDynamicLibraryLoader().open(library);
    final engine = LlcsEngine.open(
      library: dynamicLibrary,
      config: config.toLlcsEngineConfig(),
    );
    return LlamaHttpServer(
      config: config,
      backend: LlcsEngineBackend(engine, pollTimeout: config.pollTimeout),
    );
  }

  /// Loads and runs native work off the HTTP/Flutter event loop.
  static Future<LlamaHttpServer> openAsync({
    required LlamaServerConfig config,
    String? libraryPath,
  }) async {
    final engine = await LlcsWorkerEngine.open(
      libraryPath: libraryPath ?? config.libraryPath,
      config: config.toLlcsEngineConfig(),
    );
    return LlamaHttpServer(config: config, backend: LlcsWorkerBackend(engine));
  }

  final LlamaServerConfig config;
  final ChatCompletionBackend _backend;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  var _closed = false;
  Future<void>? _closeFuture;

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

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
    final backend = _backend;
    if (backend is AsyncChatCompletionBackend) {
      await backend.closeAsync();
    } else {
      backend.close();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/healthz') {
        await _writeJson(request.response, {
          'status': 'ok',
          'model': config.model,
          'loaded': true,
          'capabilities': _backend.caps(),
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
        statusCode: error is LlcsEngineException
            ? error.httpStatus
            : HttpStatus.internalServerError,
        message: error.toString(),
        type: error is LlcsEngineException ? error.type : 'server_error',
        param: error is LlcsEngineException ? error.param : null,
        code: error is LlcsEngineException ? error.code : 'internal_error',
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
        statusCode: error is LlcsEngineException
            ? error.httpStatus
            : HttpStatus.internalServerError,
        message: error is LlcsEngineException
            ? error.message
            : error.toString(),
        type: error is LlcsEngineException ? error.type : 'server_error',
        param: error is LlcsEngineException ? error.param : null,
        code: error is LlcsEngineException ? error.code : 'internal_error',
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
    response.bufferOutput = false;

    var headersSent = false;
    var hasContent = false;
    var hasFinish = false;
    final iterator = StreamIterator(_backend.complete(request));
    var pending = iterator.moveNext();
    Future<bool?> nextOrHeartbeat() => Future.any<bool?>([
      pending,
      Future<bool?>.delayed(const Duration(seconds: 1), () => null),
    ]);

    Stream<List<int>> chunks(bool? next) async* {
      try {
        while (true) {
          if (next == null) {
            yield utf8.encode(': keep-alive\n\n');
          } else if (!next) {
            break;
          } else {
            final event = iterator.current;
            if (event.containsKey('error')) {
              throw LlcsEngineException.fromJson(event);
            }
            for (final choice in event['choices'] as List? ?? const []) {
              if (choice is! Map) continue;
              hasFinish |= choice['finish_reason'] != null;
              final delta = choice['delta'];
              if (delta is Map) {
                hasContent |=
                    (delta['content'] is String &&
                        (delta['content'] as String).isNotEmpty) ||
                    (delta['reasoning_content'] is String &&
                        (delta['reasoning_content'] as String).isNotEmpty) ||
                    (delta['tool_calls'] is List &&
                        (delta['tool_calls'] as List).isNotEmpty);
              }
            }
            if (event.isNotEmpty) {
              yield utf8.encode('data: ${jsonEncode(event)}\n\n');
            }
            pending = iterator.moveNext();
          }
          next = await nextOrHeartbeat();
        }
        if (!hasContent || !hasFinish) {
          throw LlcsEngineException(
            'Backend stream completed without content and a finish reason.',
            code: 'empty_response',
          );
        }
        yield utf8.encode('data: [DONE]\n\n');
      } catch (error) {
        final native = error is LlcsEngineException ? error : null;
        yield utf8.encode(
          'data: ${jsonEncode(_errorBody(native?.message ?? error.toString(), type: native?.type ?? 'server_error', code: native?.code ?? 'internal_error', param: native?.param))}\n\n',
        );
      } finally {
        await iterator.cancel();
      }
    }

    try {
      // Keep fast parameter failures as HTTP 4xx before starting the body.
      final first = await nextOrHeartbeat();
      if (first == true && iterator.current.containsKey('error')) {
        throw LlcsEngineException.fromJson(iterator.current);
      }
      if (first == false) {
        throw LlcsEngineException(
          'Backend stream completed without content and a finish reason.',
          code: 'empty_response',
        );
      }
      headersSent = true;
      // One continuous addStream forwards socket cancellation to the producer.
      // Repeated write/flush calls can hide HttpResponse socket errors and leave
      // an idle prefill iterator alive after the peer has disconnected.
      await response.addStream(chunks(first));
      await response.close();
    } catch (error) {
      try {
        if (!headersSent) {
          final native = error is LlcsEngineException ? error : null;
          await _writeError(
            response,
            statusCode: native?.httpStatus ?? 500,
            message: native?.message ?? error.toString(),
            type: native?.type ?? 'server_error',
            code: native?.code ?? 'internal_error',
            param: native?.param,
          );
        } else {
          await response.close();
        }
      } on Object {
        // The socket may already be closed by the consumer.
      }
    } finally {
      await iterator.cancel();
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
