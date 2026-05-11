import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'llama_command.dart';
import 'llama_response.dart';
import 'llama_state.dart';

final class NativeLlamaRuntime {
  NativeLlamaRuntime({required LlamaCppLibraryDescriptor library})
    : _bindings = LlamaCppBindings(_openDynamicLibrary(library)) {
    _bindings.llama_backend_init();
  }

  final LlamaCppBindings _bindings;
  _LoadedModel? _loaded;

  LlamaState loadModel(LlamaLoadModelCommand command) {
    _disposeLoaded();

    final file = File(command.modelPath);
    if (!file.existsSync()) {
      throw NativeLlamaException(
        'Model file does not exist: ${command.modelPath}',
      );
    }

    final path = command.modelPath.toNativeUtf8();
    Pointer<llama_model> model = nullptr;
    Pointer<llama_context> context = nullptr;

    try {
      final modelParams = _bindings.llama_model_default_params();
      modelParams.n_gpu_layers = command.gpuLayerCount ?? 0;

      model = _bindings.llama_model_load_from_file(
        path.cast<Char>(),
        modelParams,
      );
      if (model == nullptr) {
        throw NativeLlamaException(
          'Failed to load model: ${command.modelPath}',
        );
      }

      final contextParams = _bindings.llama_context_default_params();
      contextParams.n_ctx = command.contextSize ?? 0;
      final threads = math.max(1, Platform.numberOfProcessors - 1);
      contextParams.n_threads = threads;
      contextParams.n_threads_batch = threads;

      context = _bindings.llama_new_context_with_model(model, contextParams);
      if (context == nullptr) {
        throw NativeLlamaException(
          'Failed to create llama.cpp context for: ${command.modelPath}',
        );
      }

      final vocab = _bindings.llama_model_get_vocab(model);
      if (vocab == nullptr) {
        throw NativeLlamaException(
          'Failed to read model vocabulary: ${command.modelPath}',
        );
      }

      _loaded = _LoadedModel(
        modelPath: command.modelPath,
        model: model,
        context: context,
        vocab: vocab,
      );

      return LlamaState(modelPath: command.modelPath, isModelLoaded: true);
    } catch (_) {
      if (context != nullptr) {
        _bindings.llama_free(context);
      }
      if (model != nullptr) {
        _bindings.llama_model_free(model);
      }
      rethrow;
    } finally {
      calloc.free(path);
    }
  }

  Iterable<LlamaResponse> generate(LlamaGenerateCommand command) sync* {
    final loaded = _loaded;
    if (loaded == null) {
      throw const NativeLlamaException(
        'Cannot generate before a model is loaded.',
      );
    }

    final maxTokens = command.maxTokens ?? 128;
    if (maxTokens <= 0) {
      return;
    }

    final promptTokens = _tokenize(loaded.vocab, command.prompt);
    if (promptTokens.isEmpty) {
      throw const NativeLlamaException('Prompt produced no tokens.');
    }

    final contextSize = _bindings.llama_n_ctx(loaded.context);
    if (promptTokens.length >= contextSize) {
      throw NativeLlamaException(
        'Prompt token count ${promptTokens.length} exceeds context size $contextSize.',
      );
    }

    _decodeTokens(loaded.context, promptTokens);

    final sampler = _createSampler(command);
    final stopMatcher = _StopMatcher(command.stop);
    var generated = 0;

    try {
      while (generated < maxTokens) {
        final token = _bindings.llama_sampler_sample(
          sampler,
          loaded.context,
          -1,
        );
        if (_bindings.llama_vocab_is_eog(loaded.vocab, token)) {
          break;
        }

        _bindings.llama_sampler_accept(sampler, token);
        final piece = _tokenToPiece(loaded.vocab, token);
        final delta = stopMatcher.add(piece);
        if (delta.isNotEmpty) {
          yield LlamaTokenResponse(text: delta, index: generated);
        }
        generated += 1;

        if (stopMatcher.isStopped) {
          break;
        }
        if (generated >= maxTokens) {
          break;
        }
        if (promptTokens.length + generated >= contextSize) {
          throw NativeLlamaException(
            'Generation exceeded context size $contextSize.',
          );
        }

        _decodeTokens(loaded.context, [token]);
      }

      final tail = stopMatcher.flush();
      if (tail.isNotEmpty) {
        yield LlamaTokenResponse(text: tail, index: generated);
      }
    } finally {
      _bindings.llama_sampler_free(sampler);
    }
  }

  void disposeModel() {
    _disposeLoaded();
  }

  void close() {
    _disposeLoaded();
  }

  List<int> _tokenize(Pointer<llama_vocab> vocab, String text) {
    final bytes = utf8.encode(text);
    final textPointer = calloc<Uint8>(bytes.length + 1);

    for (var i = 0; i < bytes.length; i += 1) {
      textPointer[i] = bytes[i];
    }
    textPointer[bytes.length] = 0;

    Pointer<llama_token> tokenPointer = nullptr;
    try {
      var capacity = math.max(8, bytes.length + 8);
      tokenPointer = calloc<llama_token>(capacity);
      var count = _bindings.llama_tokenize(
        vocab,
        textPointer.cast<Char>(),
        bytes.length,
        tokenPointer,
        capacity,
        true,
        true,
      );

      if (count < 0) {
        calloc.free(tokenPointer);
        capacity = -count;
        tokenPointer = calloc<llama_token>(capacity);
        count = _bindings.llama_tokenize(
          vocab,
          textPointer.cast<Char>(),
          bytes.length,
          tokenPointer,
          capacity,
          true,
          true,
        );
      }

      if (count < 0) {
        throw NativeLlamaException(
          'Failed to tokenize prompt: llama.cpp returned $count.',
        );
      }

      return [for (var i = 0; i < count; i += 1) tokenPointer[i]];
    } finally {
      if (tokenPointer != nullptr) {
        calloc.free(tokenPointer);
      }
      calloc.free(textPointer);
    }
  }

  void _decodeTokens(Pointer<llama_context> context, List<int> tokens) {
    final tokenPointer = calloc<llama_token>(tokens.length);
    try {
      for (var i = 0; i < tokens.length; i += 1) {
        tokenPointer[i] = tokens[i];
      }

      final batch = _bindings.llama_batch_get_one(tokenPointer, tokens.length);
      final result = _bindings.llama_decode(context, batch);
      if (result != 0) {
        throw NativeLlamaException('llama_decode failed with code $result.');
      }
    } finally {
      calloc.free(tokenPointer);
    }
  }

  Pointer<llama_sampler> _createSampler(LlamaGenerateCommand command) {
    final sampler = _bindings.llama_sampler_chain_init(
      _bindings.llama_sampler_chain_default_params(),
    );
    if (sampler == nullptr) {
      throw const NativeLlamaException('Failed to create llama.cpp sampler.');
    }

    void add(Pointer<llama_sampler> child, String name) {
      if (child == nullptr) {
        _bindings.llama_sampler_free(sampler);
        throw NativeLlamaException('Failed to create llama.cpp $name sampler.');
      }
      _bindings.llama_sampler_chain_add(sampler, child);
    }

    final temperature = command.temperature;
    final topP = command.topP;
    if (temperature == null && topP == null) {
      add(_bindings.llama_sampler_init_greedy(), 'greedy');
      return sampler;
    }

    if (topP != null && topP > 0 && topP < 1) {
      add(_bindings.llama_sampler_init_top_p(topP, 1), 'top-p');
    }
    if (temperature != null && temperature > 0) {
      add(_bindings.llama_sampler_init_temp(temperature), 'temperature');
      add(
        _bindings.llama_sampler_init_dist(LLAMA_DEFAULT_SEED),
        'distribution',
      );
    } else {
      add(_bindings.llama_sampler_init_greedy(), 'greedy');
    }

    return sampler;
  }

  String _tokenToPiece(Pointer<llama_vocab> vocab, int token) {
    var capacity = 32;
    Pointer<Char> buffer = calloc<Char>(capacity);

    try {
      var length = _bindings.llama_token_to_piece(
        vocab,
        token,
        buffer,
        capacity,
        0,
        false,
      );
      if (length < 0) {
        calloc.free(buffer);
        capacity = -length;
        buffer = calloc<Char>(capacity);
        length = _bindings.llama_token_to_piece(
          vocab,
          token,
          buffer,
          capacity,
          0,
          false,
        );
      }

      if (length < 0) {
        throw NativeLlamaException(
          'Failed to convert token $token to text: llama.cpp returned $length.',
        );
      }

      return buffer.cast<Utf8>().toDartString(length: length);
    } finally {
      calloc.free(buffer);
    }
  }

  void _disposeLoaded() {
    final loaded = _loaded;
    if (loaded == null) {
      return;
    }

    _bindings.llama_free(loaded.context);
    _bindings.llama_model_free(loaded.model);
    _loaded = null;
  }

  static DynamicLibrary _openDynamicLibrary(LlamaCppLibraryDescriptor library) {
    try {
      return switch (library.resolution) {
        LlamaCppLibraryResolution.process => DynamicLibrary.process(),
        LlamaCppLibraryResolution.executable => DynamicLibrary.executable(),
        LlamaCppLibraryResolution.path => DynamicLibrary.open(library.path!),
        LlamaCppLibraryResolution.lookupName => DynamicLibrary.open(
          library.lookupName!,
        ),
      };
    } on Object catch (error) {
      throw NativeLlamaException('Failed to open llama.cpp library: $error');
    }
  }
}

final class NativeLlamaException implements Exception {
  const NativeLlamaException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _LoadedModel {
  const _LoadedModel({
    required this.modelPath,
    required this.model,
    required this.context,
    required this.vocab,
  });

  final String modelPath;
  final Pointer<llama_model> model;
  final Pointer<llama_context> context;
  final Pointer<llama_vocab> vocab;
}

final class _StopMatcher {
  _StopMatcher(List<String> stop)
    : _stop = stop.where((item) => item.isNotEmpty).toList(),
      _maxStopLength = stop
          .where((item) => item.isNotEmpty)
          .fold<int>(0, (max, item) => math.max(max, item.length));

  final List<String> _stop;
  final int _maxStopLength;
  final StringBuffer _buffer = StringBuffer();
  var _emittedLength = 0;
  var isStopped = false;

  String add(String text) {
    if (isStopped) {
      return '';
    }

    _buffer.write(text);
    final value = _buffer.toString();
    final stopIndex = _firstStopIndex(value);
    if (stopIndex != null) {
      isStopped = true;
      final delta = value.substring(_emittedLength, stopIndex);
      _emittedLength = stopIndex;
      return delta;
    }

    if (_maxStopLength == 0) {
      final delta = value.substring(_emittedLength);
      _emittedLength = value.length;
      return delta;
    }

    final safeEnd = math.max(0, value.length - _maxStopLength + 1);
    if (safeEnd <= _emittedLength) {
      return '';
    }

    final delta = value.substring(_emittedLength, safeEnd);
    _emittedLength = safeEnd;
    return delta;
  }

  String flush() {
    if (isStopped) {
      return '';
    }

    final value = _buffer.toString();
    if (_emittedLength >= value.length) {
      return '';
    }

    final delta = value.substring(_emittedLength);
    _emittedLength = value.length;
    return delta;
  }

  int? _firstStopIndex(String value) {
    int? result;
    for (final stop in _stop) {
      final index = value.indexOf(stop);
      if (index >= 0 && (result == null || index < result)) {
        result = index;
      }
    }
    return result;
  }
}
