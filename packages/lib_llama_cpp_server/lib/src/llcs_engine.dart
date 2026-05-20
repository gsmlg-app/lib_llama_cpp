import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';

final class LlcsEngineConfig {
  const LlcsEngineConfig({
    required this.modelPath,
    this.nCtx,
    this.nGpuLayers,
    this.nParallel = 1,
    this.chatTemplate,
    this.reasoningFormat,
    this.useJinja = true,
  });

  final String modelPath;
  final int? nCtx;
  final int? nGpuLayers;
  final int nParallel;
  final String? chatTemplate;
  final String? reasoningFormat;
  final bool useJinja;

  Map<String, Object?> toJson() {
    return {
      'model_path': modelPath,
      if (nCtx != null) 'n_ctx': nCtx,
      if (nGpuLayers != null) 'n_gpu_layers': nGpuLayers,
      'n_parallel': nParallel,
      if (chatTemplate != null) 'chat_template': chatTemplate,
      if (reasoningFormat != null) 'reasoning_format': reasoningFormat,
      'use_jinja': useJinja,
    };
  }
}

abstract interface class LlcsNativeBindings {
  Pointer<llcs_engine> create(
    Pointer<Char> paramsJson,
    Pointer<Pointer<Char>> errorOut,
  );

  void destroy(Pointer<llcs_engine> engine);

  Pointer<Char> caps(Pointer<llcs_engine> engine);

  int submit(
    Pointer<llcs_engine> engine,
    Pointer<Char> requestJson,
    Pointer<Pointer<Char>> errorOut,
  );

  Pointer<Char> poll(Pointer<llcs_engine> engine, int taskId, int timeoutMs);

  void cancel(Pointer<llcs_engine> engine, int taskId);

  void stringFree(Pointer<Char> string);
}

final class GeneratedLlcsNativeBindings implements LlcsNativeBindings {
  GeneratedLlcsNativeBindings(DynamicLibrary library)
    : _bindings = LlamaCppBindings(library);

  final LlamaCppBindings _bindings;

  @override
  Pointer<llcs_engine> create(
    Pointer<Char> paramsJson,
    Pointer<Pointer<Char>> errorOut,
  ) {
    return _bindings.llcs_engine_create(paramsJson, errorOut);
  }

  @override
  void destroy(Pointer<llcs_engine> engine) {
    _bindings.llcs_engine_destroy(engine);
  }

  @override
  Pointer<Char> caps(Pointer<llcs_engine> engine) {
    return _bindings.llcs_engine_caps(engine);
  }

  @override
  int submit(
    Pointer<llcs_engine> engine,
    Pointer<Char> requestJson,
    Pointer<Pointer<Char>> errorOut,
  ) {
    return _bindings.llcs_engine_submit(engine, requestJson, errorOut);
  }

  @override
  Pointer<Char> poll(Pointer<llcs_engine> engine, int taskId, int timeoutMs) {
    return _bindings.llcs_engine_poll(engine, taskId, timeoutMs);
  }

  @override
  void cancel(Pointer<llcs_engine> engine, int taskId) {
    _bindings.llcs_engine_cancel(engine, taskId);
  }

  @override
  void stringFree(Pointer<Char> string) {
    _bindings.llcs_string_free(string);
  }
}

final class LlcsEngine {
  LlcsEngine._({required LlcsNativeBindings bindings, required this.config})
    : _bindings = bindings;

  static LlcsEngine open({
    required DynamicLibrary library,
    required LlcsEngineConfig config,
  }) {
    return LlcsEngine.withBindings(
      bindings: GeneratedLlcsNativeBindings(library),
      config: config,
    );
  }

  factory LlcsEngine.withBindings({
    required LlcsNativeBindings bindings,
    required LlcsEngineConfig config,
  }) {
    final engine = LlcsEngine._(bindings: bindings, config: config);
    engine._create();
    return engine;
  }

  final LlcsEngineConfig config;
  final LlcsNativeBindings _bindings;
  Pointer<llcs_engine>? _engine;
  var _closed = false;

  Map<String, Object?> caps() {
    final pointer = _requireOpen();
    final raw = _readNativeString(_bindings.caps(pointer));
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    return _decodeObject(raw);
  }

  int submit(Map<String, Object?> openAiChatRequest) {
    final pointer = _requireOpen();
    final requestJson = jsonEncode(
      openAiChatRequest,
    ).toNativeUtf8().cast<Char>();
    final errorOut = calloc<Pointer<Char>>();
    try {
      final taskId = _bindings.submit(pointer, requestJson, errorOut);
      if (taskId == -1) {
        throw _exceptionFromNative(
          errorOut.value,
          fallbackMessage: 'llcs_engine_submit failed.',
        );
      }
      return taskId;
    } finally {
      calloc.free(requestJson);
      calloc.free(errorOut);
    }
  }

  Map<String, Object?>? poll(
    int taskId, {
    Duration timeout = const Duration(milliseconds: 100),
  }) {
    final pointer = _requireOpen();
    final native = _bindings.poll(pointer, taskId, timeout.inMilliseconds);
    final raw = _readNativeString(native);
    if (raw == null) {
      return null;
    }
    if (raw.isEmpty) {
      return const {};
    }
    return _decodeObject(raw);
  }

  Stream<Map<String, Object?>> stream(
    Map<String, Object?> openAiChatRequest, {
    Duration pollTimeout = const Duration(milliseconds: 100),
  }) async* {
    final taskId = submit(openAiChatRequest);
    var completed = false;
    try {
      while (true) {
        final event = poll(taskId, timeout: pollTimeout);
        if (event == null) {
          completed = true;
          break;
        }
        if (event.isEmpty) {
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        yield event;
      }
    } finally {
      if (!completed) {
        cancel(taskId);
      }
    }
  }

  void cancel(int taskId) {
    final pointer = _engine;
    if (_closed || pointer == null) {
      return;
    }
    _bindings.cancel(pointer, taskId);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final pointer = _engine;
    _engine = null;
    if (pointer != null) {
      _bindings.destroy(pointer);
    }
  }

  void _create() {
    final paramsJson = jsonEncode(config.toJson()).toNativeUtf8().cast<Char>();
    final errorOut = calloc<Pointer<Char>>();
    try {
      final pointer = _bindings.create(paramsJson, errorOut);
      if (pointer == nullptr) {
        throw _exceptionFromNative(
          errorOut.value,
          fallbackMessage: 'llcs_engine_create failed.',
        );
      }
      _engine = pointer;
    } finally {
      calloc.free(paramsJson);
      calloc.free(errorOut);
    }
  }

  Pointer<llcs_engine> _requireOpen() {
    final pointer = _engine;
    if (_closed || pointer == null) {
      throw StateError('LlcsEngine is closed.');
    }
    return pointer;
  }

  String? _readNativeString(Pointer<Char> pointer) {
    if (pointer == nullptr) {
      return null;
    }
    try {
      return pointer.cast<Utf8>().toDartString();
    } finally {
      _bindings.stringFree(pointer);
    }
  }

  LlcsEngineException _exceptionFromNative(
    Pointer<Char> pointer, {
    required String fallbackMessage,
  }) {
    final raw = _readNativeString(pointer);
    if (raw == null || raw.isEmpty) {
      return LlcsEngineException(fallbackMessage);
    }

    try {
      final nativeJson = _decodeObject(raw);
      final message =
          nativeJson['message'] as String? ??
          nativeJson['error'] as String? ??
          fallbackMessage;
      return LlcsEngineException(
        message,
        nativeJson: nativeJson,
        nativeJsonText: raw,
      );
    } on FormatException {
      return LlcsEngineException(fallbackMessage, nativeJsonText: raw);
    }
  }
}

final class LlcsEngineException implements Exception {
  LlcsEngineException(
    this.message, {
    this.code = 'native_error',
    this.type = 'server_error',
    this.param,
    this.nativeJson,
    this.nativeJsonText,
  });

  final String message;
  final String code;
  final String type;
  final String? param;
  final Map<String, Object?>? nativeJson;
  final String? nativeJsonText;

  @override
  String toString() => 'LlcsEngineException($code): $message';
}

Map<String, Object?> _decodeObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
  throw const FormatException('Expected JSON object from llcs.');
}
