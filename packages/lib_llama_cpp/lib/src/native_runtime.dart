import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'llama_command.dart';
import 'llama_content.dart';
import 'llama_response.dart';
import 'llama_state.dart';
import 'llama_tool.dart';
import 'tool_aware_streaming.dart';
import 'token_text_decoder.dart';
import 'native_cancellation.dart';

final class NativeLlamaRuntime {
  NativeLlamaRuntime({required LlamaCppLibraryDescriptor library})
    : this._fromDynamicLibrary(
        _openDynamicLibrary(library),
        requiredCapabilities: library.requestedCapabilities,
      );

  NativeLlamaRuntime._fromDynamicLibrary(
    DynamicLibrary library, {
    required Set<LlamaCppLibraryCapability> requiredCapabilities,
  }) : _bindings = LlamaCppBindings(library),
       _wrapper = _LibLlamaCppWrapper(library),
       _library = library,
       _requiredCapabilities = requiredCapabilities {
    final error = calloc<Pointer<Char>>();
    try {
      final acquire = library
          .lookupFunction<
            Int32 Function(Pointer<Pointer<Char>>),
            int Function(Pointer<Pointer<Char>>)
          >('llcs_backend_acquire');
      if (acquire(error) != 0) {
        throw const NativeLlamaException(
          'Failed to acquire llama.cpp backend.',
        );
      }
      _backendOwned = true;
      if (Platform.isLinux ||
          Platform.isWindows ||
          _requiredCapabilities.isNotEmpty) {
        _inspectBackends();
      }
      final create = library
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'llcs_cancel_create',
          );
      final flag = create();
      if (flag == nullptr) {
        throw const NativeLlamaException(
          'Failed to allocate cancellation flag.',
        );
      }
      cancellation = NativeCancellation(library, flag.address);
    } catch (_) {
      if (_backendOwned) _releaseBackend();
      rethrow;
    } finally {
      if (error.value != nullptr) {
        library.lookupFunction<
          Void Function(Pointer<Char>),
          void Function(Pointer<Char>)
        >('llcs_string_free')(error.value);
      }
      calloc.free(error);
    }
  }

  final LlamaCppBindings _bindings;
  final _LibLlamaCppWrapper _wrapper;
  final DynamicLibrary _library;
  final Set<LlamaCppLibraryCapability> _requiredCapabilities;
  final Set<LlamaCppLibraryCapability> _compiledCapabilities = {};
  final Map<LlamaCppLibraryCapability, List<ggml_backend_dev_t>> _gpuDevices =
      {};
  var _backendsInspected = false;
  late final NativeCancellation cancellation;
  var _backendOwned = false;
  var _closed = false;
  LlamaLoadModelCommand? _configuration;
  LlamaState? _loadedState;

  void _inspectBackends() {
    _backendsInspected = true;
    final regCount = _library.lookupFunction<Size Function(), int Function()>(
      'ggml_backend_reg_count',
    );
    final regGet = _library
        .lookupFunction<
          ggml_backend_reg_t Function(Size),
          ggml_backend_reg_t Function(int)
        >('ggml_backend_reg_get');
    final regName = _library
        .lookupFunction<
          Pointer<Char> Function(ggml_backend_reg_t),
          Pointer<Char> Function(ggml_backend_reg_t)
        >('ggml_backend_reg_name');
    final devCount = _library.lookupFunction<Size Function(), int Function()>(
      'ggml_backend_dev_count',
    );
    final devGet = _library
        .lookupFunction<
          ggml_backend_dev_t Function(Size),
          ggml_backend_dev_t Function(int)
        >('ggml_backend_dev_get');
    final devType = _library
        .lookupFunction<
          Int32 Function(ggml_backend_dev_t),
          int Function(ggml_backend_dev_t)
        >('ggml_backend_dev_type');
    final devReg = _library
        .lookupFunction<
          ggml_backend_reg_t Function(ggml_backend_dev_t),
          ggml_backend_reg_t Function(ggml_backend_dev_t)
        >('ggml_backend_dev_backend_reg');
    for (var index = 0; index < regCount(); index++) {
      final capability = _backendCapability(
        regName(regGet(index)).cast<Utf8>().toDartString(),
      );
      if (capability != null) _compiledCapabilities.add(capability);
    }
    for (var index = 0; index < devCount(); index++) {
      final device = devGet(index);
      final type = devType(device);
      if (type != 1 && type != 2 && type != 4) continue;
      final capability = _backendCapability(
        regName(devReg(device)).cast<Utf8>().toDartString(),
      );
      if (capability != null) {
        _gpuDevices.putIfAbsent(capability, () => []).add(device);
      }
    }
    for (final capability in _requiredCapabilities) {
      if (!_compiledCapabilities.contains(capability) ||
          (_isGpuCapability(capability) &&
              (_gpuDevices[capability]?.isEmpty ?? true))) {
        throw NativeLlamaException(
          'Required backend ${capability.name} is unavailable: no compiled registration or usable device.',
        );
      }
    }
  }

  List<ggml_backend_dev_t> _devicesFor(LlamaLoadModelCommand command) {
    if (!_backendsInspected) return const [];
    final requiredGpu = _requiredCapabilities.where(_isGpuCapability).toSet();
    if (requiredGpu.isNotEmpty && command.gpuLayerCount == 0) {
      throw const NativeLlamaException(
        'A required GPU backend cannot use gpuLayerCount: 0.',
      );
    }
    final devices = [
      for (final entry in _gpuDevices.entries)
        if (requiredGpu.isEmpty || requiredGpu.contains(entry.key))
          ...entry.value,
    ];
    if ((command.gpuLayerCount ?? 0) != 0 && devices.isEmpty) {
      throw const NativeLlamaException(
        'GPU offload requested but no usable GPU device is available.',
      );
    }
    return requiredGpu.isEmpty ? const [] : devices;
  }

  void _releaseBackend() {
    _library.lookupFunction<Void Function(), void Function()>(
      'llcs_backend_release',
    )();
    _backendOwned = false;
  }

  void _checkCancellation() {
    if (cancellation.isRequested) {
      throw const NativeLlamaException('Generation cancelled.');
    }
  }

  void _installCancellation(Pointer<llama_context> context) {
    _library.lookupFunction<
      Void Function(Pointer<Void>, Pointer<llama_context>),
      void Function(Pointer<Void>, Pointer<llama_context>)
    >('llcs_cancel_install')(cancellation.pointer, context);
  }

  llama_context_params _contextParams(LlamaLoadModelCommand command) {
    if (command.contextSize != null && command.contextSize! < 0) {
      throw const NativeLlamaException('Context size must not be negative.');
    }
    for (final value in [
      command.batchSize,
      command.microBatchSize,
      command.threadCount,
      command.batchThreadCount,
    ]) {
      if (value != null && value <= 0) {
        throw const NativeLlamaException(
          'Context, batch and thread sizes must be positive.',
        );
      }
    }
    if (command.flashAttention != null) {
      llama_flash_attn_type.fromValue(command.flashAttention!);
    }
    if (command.cacheTypeK != null) ggml_type.fromValue(command.cacheTypeK!);
    if (command.cacheTypeV != null) ggml_type.fromValue(command.cacheTypeV!);
    final params = _bindings.llama_context_default_params();
    params.n_ctx = command.contextSize ?? 0;
    final threads = math.max(1, Platform.numberOfProcessors - 1);
    params.n_threads = command.threadCount ?? threads;
    params.n_threads_batch = command.batchThreadCount ?? params.n_threads;
    if (command.batchSize != null) params.n_batch = command.batchSize!;
    if (command.microBatchSize != null) {
      params.n_ubatch = command.microBatchSize!;
    }
    if (command.flashAttention != null) {
      params.flash_attn_typeAsInt = command.flashAttention!;
    }
    if (command.cacheTypeK != null) params.type_kAsInt = command.cacheTypeK!;
    if (command.cacheTypeV != null) params.type_vAsInt = command.cacheTypeV!;
    params.swa_full = command.swaFull;
    return params;
  }

  void _resetContext(_LoadedModel loaded) {
    _checkCancellation();
    if (loaded.context != nullptr) _bindings.llama_free(loaded.context);
    loaded.context = nullptr;
    final context = _wrapper.contextCreate(
      loaded.model,
      _contextParams(_configuration!),
    );
    if (context == nullptr) {
      throw const NativeLlamaException('Failed to rebuild request context.');
    }
    loaded.context = context;
    _installCancellation(context);
  }

  _LoadedModel? _loaded;

  LlamaState loadModel(LlamaLoadModelCommand command) {
    if (_configuration == command && _loaded != null) return _loadedState!;
    _disposeLoaded();
    _checkCancellation();

    final selectedDevices = _devicesFor(command);
    final file = File(command.modelPath);
    if (!file.existsSync()) {
      throw NativeLlamaException(
        'Model file does not exist: ${command.modelPath}',
      );
    }

    final path = command.modelPath.toNativeUtf8();
    Pointer<llama_model> model = nullptr;
    Pointer<llama_context> context = nullptr;
    Pointer<Void> mediaContext = nullptr;
    Pointer<ggml_backend_dev_t> deviceArray = nullptr;

    try {
      final modelParams = _bindings.llama_model_default_params();
      modelParams.n_gpu_layers =
          command.gpuLayerCount ?? (selectedDevices.isEmpty ? 0 : -1);
      if (selectedDevices.isNotEmpty) {
        deviceArray = calloc<ggml_backend_dev_t>(selectedDevices.length + 1);
        for (var index = 0; index < selectedDevices.length; index++) {
          deviceArray[index] = selectedDevices[index];
        }
        modelParams.devices = deviceArray;
      }

      model = _wrapper.modelLoad(path.cast<Char>(), modelParams);
      if (model == nullptr) {
        throw NativeLlamaException(
          'Failed to load model: ${command.modelPath}',
        );
      }

      final contextParams = _contextParams(command);

      context = _wrapper.contextCreate(model, contextParams);
      if (context == nullptr) {
        throw NativeLlamaException(
          'Failed to create llama.cpp context for: ${command.modelPath}',
        );
      }

      _installCancellation(context);
      _checkCancellation();
      final vocab = _bindings.llama_model_get_vocab(model);
      if (vocab == nullptr) {
        throw NativeLlamaException(
          'Failed to read model vocabulary: ${command.modelPath}',
        );
      }

      final chatTemplate = _modelChatTemplate(model);
      final templateCapabilities = chatTemplate == null
          ? const <String, Object?>{}
          : _wrapper.chatTemplateCapabilities(model);
      var supportsImage = false;
      var supportsAudio = false;
      if (command.mmprojPath != null) {
        final mmprojFile = File(command.mmprojPath!);
        if (!mmprojFile.existsSync()) {
          throw NativeLlamaException(
            'Multimodal projector file does not exist: ${command.mmprojPath}',
          );
        }
        mediaContext = _wrapper.mediaInit(
          mmprojPath: command.mmprojPath!,
          model: model,
          useGpu: command.mmprojUseGpu,
          imageMinTokens: command.imageMinTokens,
          imageMaxTokens: command.imageMaxTokens,
        );
        supportsImage = _wrapper.mediaSupportsVision(mediaContext);
        supportsAudio = _wrapper.mediaSupportsAudio(mediaContext);
      }

      _loaded = _LoadedModel(
        modelPath: command.modelPath,
        model: model,
        context: context,
        vocab: vocab,
        mmprojPath: command.mmprojPath,
        mediaContext: mediaContext,
        supportsImage: supportsImage,
        supportsAudio: supportsAudio,
      );

      _configuration = command;
      return _loadedState = LlamaState(
        modelPath: command.modelPath,
        isModelLoaded: true,
        capabilities: LlamaModelCapabilities.fromTemplateCapabilities(
          templateCapabilities,
          hasChatTemplate: chatTemplate != null,
          image: supportsImage,
          audio: supportsAudio,
        ),
      );
    } catch (_) {
      if (mediaContext != nullptr) {
        _wrapper.mediaFree(mediaContext);
      }
      if (context != nullptr) {
        _bindings.llama_free(context);
      }
      if (model != nullptr) {
        _bindings.llama_model_free(model);
      }
      rethrow;
    } finally {
      if (deviceArray != nullptr) calloc.free(deviceArray);
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

    _resetContext(loaded);
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

    _validateBudget(promptTokens.length, command.maxTokens, contextSize);
    loaded.promptTokenCount = promptTokens.length;
    _decodeTokens(loaded.context, promptTokens);
    yield* _sampleFromEvaluatedPrompt(
      loaded: loaded,
      command: command,
      initialTokenCount: promptTokens.length,
    );
  }

  Iterable<LlamaResponse> generateMessages(
    LlamaGenerateMessagesCommand command,
  ) sync* {
    final loaded = _loaded;
    if (loaded == null) {
      throw const NativeLlamaException(
        'Cannot generate before a model is loaded.',
      );
    }
    if (command.hasMedia && loaded.mmprojPath == null) {
      throw const NativeLlamaException(
        'Image and audio inputs require a multimodal projector.',
      );
    }

    _resetContext(loaded);
    _validateBudget(
      0,
      command.maxTokens,
      _bindings.llama_n_ctx(loaded.context),
    );
    final mediaInputs = <_MediaInput>[];
    final templateResult = _wrapper.applyChatTemplate(
      model: loaded.model,
      request: _chatTemplateRequest(command, mediaInputs),
    );
    final samplingCommand = LlamaGenerateCommand(
      prompt: templateResult.prompt,
      maxTokens: command.maxTokens,
      temperature: command.temperature,
      topP: command.topP,
      stop: [...templateResult.additionalStops, ...command.stop],
    );

    final initialTokenCount = _evaluateMessagePrompt(
      loaded: loaded,
      prompt: templateResult.prompt,
      mediaInputs: mediaInputs,
      maxOutputTokens: command.maxTokens,
    );

    _validateBudget(
      initialTokenCount,
      command.maxTokens,
      _bindings.llama_n_ctx(loaded.context),
    );
    final grammar = _samplingGrammarFor(templateResult);
    yield* streamToolAwareMessageResponses(
      sampled: _sampleFromEvaluatedPrompt(
        loaded: loaded,
        command: samplingCommand,
        initialTokenCount: initialTokenCount,
        grammar: grammar,
        grammarLazy: grammar != null && templateResult.grammarLazy,
        grammarTriggers: grammar == null
            ? const []
            : templateResult.grammarTriggers,
      ),
      command: command,
      parseChatOutput: (text, {required isPartial}) => _wrapper.parseChatOutput(
        text: text,
        format: templateResult.format,
        generationPrompt: templateResult.generationPrompt,
        parser: templateResult.parser,
        isPartial: isPartial,
      ),
    );
  }

  String? _samplingGrammarFor(_ChatTemplateResult templateResult) {
    if (templateResult.grammar.isEmpty) {
      return null;
    }

    // Retain the existing Gemma4 sampling policy until its generated grammars
    // are validated with this direct parser. Safe FFI and single token accept
    // now contain grammar exceptions; that alone does not establish Gemma4
    // constrained decoding. The tool-aware template and parser remain active.
    if (templateResult.format == 'peg-gemma4') {
      return null;
    }

    return templateResult.grammar;
  }

  Iterable<LlamaResponse> _sampleFromEvaluatedPrompt({
    required _LoadedModel loaded,
    required LlamaGenerateCommand command,
    required int initialTokenCount,
    String? grammar,
    bool grammarLazy = false,
    List<_GrammarTrigger> grammarTriggers = const [],
  }) sync* {
    final contextSize = _bindings.llama_n_ctx(loaded.context);
    _validateBudget(initialTokenCount, command.maxTokens, contextSize);
    final maxTokens = command.maxTokens ?? contextSize - initialTokenCount;
    if (maxTokens == 0) {
      yield LlamaDoneResponse(
        inputTokens: loaded.promptTokenCount,
        outputTokens: 0,
        finishReason: 'length',
      );
      return;
    }

    final sampler = _createSampler(
      loaded.vocab,
      command,
      grammar: grammar,
      grammarLazy: grammarLazy,
      grammarTriggers: grammarTriggers,
    );
    final stopMatcher = TokenTextDecoder(stop: command.stop);
    var generated = 0;
    var finishReason = 'length';

    try {
      while (generated < maxTokens) {
        _checkCancellation();
        final token = _wrapper.samplerSample(sampler, loaded.context, -1);
        if (_bindings.llama_vocab_is_eog(loaded.vocab, token)) {
          generated += 1;
          finishReason = 'stop';
          break;
        }

        final piece = _tokenToPiece(loaded.vocab, token);
        final delta = stopMatcher.add(piece);
        if (delta.isNotEmpty) {
          yield LlamaTokenResponse(text: delta, index: generated);
        }
        generated += 1;

        if (stopMatcher.isStopped) {
          finishReason = 'stop';
          break;
        }
        if (generated >= maxTokens) {
          break;
        }
        if (initialTokenCount + generated >= contextSize) {
          throw NativeLlamaException(
            'Generation exceeded context size $contextSize.',
          );
        }

        _decodeTokens(loaded.context, [token]);
      }

      final tail = stopMatcher.close();
      if (tail.isNotEmpty) {
        yield LlamaTokenResponse(text: tail, index: generated);
      }
      yield LlamaDoneResponse(
        inputTokens: loaded.promptTokenCount,
        outputTokens: generated,
        finishReason: finishReason,
      );
    } finally {
      _wrapper.samplerFree(sampler);
    }
  }

  int _evaluateMessagePrompt({
    required _LoadedModel loaded,
    required String prompt,
    required List<_MediaInput> mediaInputs,
    required int? maxOutputTokens,
  }) {
    if (mediaInputs.isEmpty) {
      final promptTokens = _tokenize(loaded.vocab, prompt);
      if (promptTokens.isEmpty) {
        throw const NativeLlamaException('Prompt produced no tokens.');
      }

      final contextSize = _bindings.llama_n_ctx(loaded.context);
      if (promptTokens.length >= contextSize) {
        throw NativeLlamaException(
          'Prompt token count ${promptTokens.length} exceeds context size $contextSize.',
        );
      }

      _validateBudget(promptTokens.length, maxOutputTokens, contextSize);
      loaded.promptTokenCount = promptTokens.length;
      _decodeTokens(loaded.context, promptTokens);
      return promptTokens.length;
    }

    if (loaded.mediaContext == nullptr) {
      throw const NativeLlamaException(
        'Image and audio inputs require a multimodal projector.',
      );
    }
    if (mediaInputs.any((input) => input.isImage) && !loaded.supportsImage) {
      throw const NativeLlamaException(
        'The loaded multimodal projector does not support image input.',
      );
    }
    if (mediaInputs.any((input) => input.isAudio) && !loaded.supportsAudio) {
      throw const NativeLlamaException(
        'The loaded multimodal projector does not support audio input.',
      );
    }

    final blobs = <Pointer<Void>>[];
    try {
      for (final input in mediaInputs) {
        _checkCancellation();
        blobs.add(_wrapper.mediaBlob(loaded.mediaContext, input));
      }
      _checkCancellation();
      final evaluated = _wrapper.mediaEvalPrompt(
        mediaContext: loaded.mediaContext,
        llamaContext: loaded.context,
        prompt: prompt,
        blobs: blobs,
        nBatch: _bindings.llama_n_batch(loaded.context),
        reservedOutputTokens: maxOutputTokens ?? 0,
      );
      _checkCancellation();
      loaded.promptTokenCount = evaluated.tokens;
      return math.max(evaluated.positions, evaluated.tokens);
    } finally {
      for (final blob in blobs) {
        _wrapper.mediaBlobFree(blob);
      }
    }
  }

  Map<String, Object?> _chatTemplateRequest(
    LlamaGenerateMessagesCommand command,
    List<_MediaInput> mediaInputs,
  ) {
    return {
      'messages': [
        for (final message in command.messages)
          _messageToJson(message, mediaInputs),
      ],
      if (command.tools.isNotEmpty)
        'tools': [for (final tool in command.tools) _toolToJson(tool)],
      'tool_choice': _toolChoiceToJson(command.toolChoice),
      'parallel_tool_calls': command.parallelToolCalls,
      'add_generation_prompt': true,
      'use_jinja': true,
    };
  }

  Map<String, Object?> _messageToJson(
    LlamaMessage message,
    List<_MediaInput> mediaInputs,
  ) {
    final json = <String, Object?>{
      'role': message.role,
      'content': _contentToJson(message.content, mediaInputs),
    };

    if (message.toolCalls.isNotEmpty) {
      json['tool_calls'] = [
        for (final toolCall in message.toolCalls)
          {
            'id': toolCall.id,
            'type': 'function',
            'function': {
              'name': toolCall.name,
              'arguments': toolCall.arguments,
            },
          },
      ];
    }
    if (message.toolCallId != null) {
      json['tool_call_id'] = message.toolCallId;
    }
    if (message.name != null) {
      json['name'] = message.name;
    }

    return json;
  }

  Object _contentToJson(Object content, List<_MediaInput> mediaInputs) {
    if (content is String) {
      return content;
    }
    if (content is List<LlamaContentPart>) {
      return [
        for (final part in content) _contentPartToJson(part, mediaInputs),
      ];
    }
    throw ArgumentError.value(
      content,
      'content',
      'Unsupported message content',
    );
  }

  Map<String, String> _contentPartToJson(
    LlamaContentPart part,
    List<_MediaInput> mediaInputs,
  ) {
    if (part is LlamaTextPart) {
      return {'type': 'text', 'text': part.text};
    }
    if (part.isMedia) {
      final index = mediaInputs.length;
      mediaInputs.add(_MediaInput(index: index, part: part));
      return {'type': 'media_marker', 'text': _MediaInput.mediaMarker};
    }
    throw ArgumentError.value(part, 'part', 'Unsupported content part');
  }

  Map<String, Object?> _toolToJson(LlamaTool tool) {
    return {
      'type': 'function',
      'function': {
        'name': tool.name,
        if (tool.description.isNotEmpty) 'description': tool.description,
        'parameters': tool.parameters,
      },
    };
  }

  Object _toolChoiceToJson(LlamaToolChoice toolChoice) {
    if (toolChoice.mode == 'tool' && toolChoice.name != null) {
      return {
        'type': 'function',
        'function': {'name': toolChoice.name},
      };
    }
    return toolChoice.mode;
  }

  void disposeModel() {
    _disposeLoaded();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _disposeLoaded();
    } finally {
      _library.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('llcs_cancel_free')(cancellation.pointer);
      if (_backendOwned) _releaseBackend();
    }
  }

  void _validateBudget(int inputTokens, int? outputTokens, int contextSize) {
    if (outputTokens != null && outputTokens < 0) {
      throw const NativeLlamaException('maxTokens must not be negative.');
    }
    if (inputTokens >= contextSize ||
        inputTokens + (outputTokens ?? 0) > contextSize) {
      throw NativeLlamaException(
        'Context budget exceeded: $inputTokens input tokens + ${outputTokens ?? 0} requested output tokens > $contextSize context tokens.',
        code: 'context_overflow',
        details: {
          'prompt_tokens': inputTokens,
          'max_tokens': outputTokens ?? 0,
          'n_ctx': contextSize,
        },
      );
    }
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
      var count = _wrapper.tokenize(
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
        count = _wrapper.tokenize(
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
    if (tokens.isEmpty) {
      return;
    }

    final batchSize = _bindings.llama_n_batch(context);
    if (batchSize <= 0) {
      throw NativeLlamaException('Invalid llama.cpp batch size $batchSize.');
    }

    for (var offset = 0; offset < tokens.length; offset += batchSize) {
      _checkCancellation();
      final chunkLength = math.min(batchSize, tokens.length - offset);
      final tokenPointer = calloc<llama_token>(chunkLength);
      try {
        for (var i = 0; i < chunkLength; i += 1) {
          tokenPointer[i] = tokens[offset + i];
        }

        final batch = _bindings.llama_batch_get_one(tokenPointer, chunkLength);
        final result = _wrapper.decode(context, batch);
        _checkCancellation();
        if (result != 0) {
          throw NativeLlamaException('llama_decode failed with code $result.');
        }
      } finally {
        calloc.free(tokenPointer);
      }
    }
  }

  Pointer<llama_sampler> _createSampler(
    Pointer<llama_vocab> vocab,
    LlamaGenerateCommand command, {
    String? grammar,
    bool grammarLazy = false,
    List<_GrammarTrigger> grammarTriggers = const [],
  }) {
    return _wrapper.samplerCreate(vocab, {
      'temperature': command.temperature,
      'top_p': command.topP,
      'grammar': grammar ?? '',
      'grammar_lazy': grammarLazy,
      'grammar_triggers': [
        for (final trigger in grammarTriggers)
          {
            'type': trigger.type,
            'value': trigger.value,
            'token': trigger.token,
          },
      ],
    });
  }

  List<int> _tokenToPiece(Pointer<llama_vocab> vocab, int token) {
    var capacity = 32;
    Pointer<Char> buffer = calloc<Char>(capacity);

    try {
      var length = _wrapper.tokenToPiece(
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
        length = _wrapper.tokenToPiece(
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

      return List<int>.of(buffer.cast<Uint8>().asTypedList(length));
    } finally {
      calloc.free(buffer);
    }
  }

  String? _modelChatTemplate(Pointer<llama_model> model) {
    final template = _bindings.llama_model_chat_template(model, nullptr);
    if (template == nullptr) {
      return null;
    }
    return template.cast<Utf8>().toDartString();
  }

  void _disposeLoaded() {
    final loaded = _loaded;
    if (loaded == null) {
      return;
    }

    _loaded = null;
    _configuration = null;
    _loadedState = null;
    try {
      if (loaded.mediaContext != nullptr) {
        _wrapper.mediaFree(loaded.mediaContext);
      }
    } finally {
      try {
        if (loaded.context != nullptr) _bindings.llama_free(loaded.context);
      } finally {
        _bindings.llama_model_free(loaded.model);
      }
    }
  }

  static DynamicLibrary _openDynamicLibrary(LlamaCppLibraryDescriptor library) {
    try {
      final opened = switch (library.resolution) {
        LlamaCppLibraryResolution.process => DynamicLibrary.process(),
        LlamaCppLibraryResolution.executable => DynamicLibrary.executable(),
        LlamaCppLibraryResolution.path => DynamicLibrary.open(library.path!),
        LlamaCppLibraryResolution.lookupName => DynamicLibrary.open(
          library.lookupName!,
        ),
      };
      LlamaCppDynamicLibraryLoader.validateLibrary(opened);
      return opened;
    } on Object catch (error) {
      throw NativeLlamaException('Failed to open llama.cpp library: $error');
    }
  }
}

final class NativeLlamaException implements Exception {
  const NativeLlamaException(this.message, {this.code, this.details});

  factory NativeLlamaException.fromNativeError(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final details = Map<String, Object?>.of(decoded)
          ..remove('code')
          ..remove('type')
          ..remove('message');
        return NativeLlamaException(
          decoded['message'] is String ? decoded['message'] as String : raw,
          code: decoded['code'] is String ? decoded['code'] as String : null,
          details: details.isEmpty ? null : details,
        );
      }
    } on FormatException {
      // Older native wrappers can return an unstructured error string.
    }
    return NativeLlamaException(raw);
  }

  final String message;
  final String? code;
  final Map<String, Object?>? details;

  @override
  String toString() => message;
}

final class _LoadedModel {
  _LoadedModel({
    required this.modelPath,
    required this.model,
    required this.context,
    required this.vocab,
    required this.mmprojPath,
    required this.mediaContext,
    required this.supportsImage,
    required this.supportsAudio,
  });

  final String modelPath;
  final Pointer<llama_model> model;
  Pointer<llama_context> context;
  var promptTokenCount = 0;
  final Pointer<llama_vocab> vocab;
  final String? mmprojPath;
  final Pointer<Void> mediaContext;
  final bool supportsImage;
  final bool supportsAudio;
}

final class _ChatTemplateResult {
  const _ChatTemplateResult({
    required this.prompt,
    required this.grammar,
    required this.grammarLazy,
    required this.format,
    required this.generationPrompt,
    required this.parser,
    required this.grammarTriggers,
    required this.additionalStops,
  });

  factory _ChatTemplateResult.fromJson(Map<String, Object?> json) {
    return _ChatTemplateResult(
      prompt: json['prompt'] as String? ?? '',
      grammar: json['grammar'] as String? ?? '',
      grammarLazy: json['grammar_lazy'] as bool? ?? false,
      format: json['format'] as String? ?? 'content-only',
      generationPrompt: json['generation_prompt'] as String? ?? '',
      parser: json['parser'] as String? ?? '',
      grammarTriggers: (json['grammar_triggers'] as List? ?? const [])
          .map(_GrammarTrigger.fromJsonObject)
          .whereType<_GrammarTrigger>()
          .toList(),
      additionalStops: (json['additional_stops'] as List? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  final String prompt;
  final String grammar;
  final bool grammarLazy;
  final String format;
  final String generationPrompt;
  final String parser;
  final List<_GrammarTrigger> grammarTriggers;
  final List<String> additionalStops;
}

final class _GrammarTrigger {
  const _GrammarTrigger({
    required this.type,
    required this.value,
    required this.token,
  });

  static _GrammarTrigger? fromJsonObject(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    final json = value.map((key, value) => MapEntry(key.toString(), value));
    return _GrammarTrigger(
      type: json['type'] as String? ?? '',
      value: json['value'] as String? ?? '',
      token: json['token'] as int? ?? LLAMA_TOKEN_NULL,
    );
  }

  final String type;
  final String value;
  final int token;
}

final class _MediaInput {
  const _MediaInput({required this.index, required this.part});

  static const mediaMarker = '<__media__>';

  final int index;
  final LlamaContentPart part;

  String get id => 'media_$index';

  bool get isImage {
    final value = part;
    return value is LlamaImageFilePart || value is LlamaImageBytesPart;
  }

  bool get isAudio {
    final value = part;
    return value is LlamaAudioFilePart || value is LlamaAudioBytesPart;
  }
}

final class _LibLlamaCppWrapper {
  _LibLlamaCppWrapper(this._library) {
    // Resolve the new direct ABI before any model resources are allocated.
    for (final symbol in const [
      'lib_llama_cpp_model_load_safe',
      'lib_llama_cpp_context_create_safe',
      'lib_llama_cpp_tokenize_safe',
      'lib_llama_cpp_token_to_piece_safe',
      'lib_llama_cpp_decode_safe',
      'lib_llama_cpp_sampler_create_safe',
      'lib_llama_cpp_sampler_sample_safe',
      'lib_llama_cpp_sampler_accept_safe',
      'lib_llama_cpp_sampler_free_safe',
    ]) {
      if (!_library.providesSymbol(symbol)) {
        throw NativeLlamaException(
          'Missing required direct shim symbol: $symbol.',
        );
      }
    }
  }

  final DynamicLibrary _library;

  Pointer<T> _pointerResult<T extends NativeType>(
    Pointer<T> Function(Pointer<Pointer<Char>>) operation,
    String fallback,
  ) {
    final error = calloc<Pointer<Char>>();
    try {
      final result = operation(error);
      if (result == nullptr) throw _errorMessage(error, fallback);
      return result;
    } finally {
      _freeError(error);
      calloc.free(error);
    }
  }

  int _integerResult(
    int Function(Pointer<Int32>, Pointer<Pointer<Char>>) operation,
    String fallback,
  ) {
    final error = calloc<Pointer<Char>>();
    final result = calloc<Int32>();
    try {
      if (operation(result, error) != 0) throw _errorMessage(error, fallback);
      return result.value;
    } finally {
      _freeError(error);
      calloc.free(result);
      calloc.free(error);
    }
  }

  Pointer<llama_model> modelLoad(
    Pointer<Char> path,
    llama_model_params params,
  ) => _pointerResult(
    (error) => _safeModelLoad(path, params, error),
    'Failed to load model.',
  );

  Pointer<llama_context> contextCreate(
    Pointer<llama_model> model,
    llama_context_params params,
  ) => _pointerResult(
    (error) => _safeContextCreate(model, params, error),
    'Failed to create context.',
  );

  int tokenize(
    Pointer<llama_vocab> vocab,
    Pointer<Char> text,
    int length,
    Pointer<llama_token> tokens,
    int capacity,
    bool addSpecial,
    bool parseSpecial,
  ) => _integerResult(
    (result, error) => _safeTokenize(
      vocab,
      text,
      length,
      tokens,
      capacity,
      addSpecial,
      parseSpecial,
      result,
      error,
    ),
    'Tokenization failed.',
  );

  int tokenToPiece(
    Pointer<llama_vocab> vocab,
    int token,
    Pointer<Char> buffer,
    int capacity,
    int lstrip,
    bool special,
  ) => _integerResult(
    (result, error) => _safeTokenToPiece(
      vocab,
      token,
      buffer,
      capacity,
      lstrip,
      special,
      result,
      error,
    ),
    'Token conversion failed.',
  );

  int decode(Pointer<llama_context> context, llama_batch batch) =>
      _integerResult(
        (result, error) => _safeDecode(context, batch, result, error),
        'Decode failed.',
      );

  Pointer<llama_sampler> samplerCreate(
    Pointer<llama_vocab> vocab,
    Map<String, Object?> options,
  ) {
    final config = jsonEncode(options).toNativeUtf8();
    try {
      return _pointerResult(
        (error) => _safeSamplerCreate(vocab, config.cast<Char>(), error),
        'Sampler creation failed.',
      );
    } finally {
      calloc.free(config);
    }
  }

  int samplerSample(
    Pointer<llama_sampler> sampler,
    Pointer<llama_context> context,
    int index,
  ) => _integerResult(
    (result, error) =>
        _safeSamplerSample(sampler, context, index, result, error),
    'Sampling failed.',
  );

  void samplerFree(Pointer<llama_sampler> sampler) => _safeSamplerFree(sampler);

  late final _safeModelLoad = _library
      .lookupFunction<
        Pointer<llama_model> Function(
          Pointer<Char>,
          llama_model_params,
          Pointer<Pointer<Char>>,
        ),
        Pointer<llama_model> Function(
          Pointer<Char>,
          llama_model_params,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_model_load_safe');

  late final _safeContextCreate = _library
      .lookupFunction<
        Pointer<llama_context> Function(
          Pointer<llama_model>,
          llama_context_params,
          Pointer<Pointer<Char>>,
        ),
        Pointer<llama_context> Function(
          Pointer<llama_model>,
          llama_context_params,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_context_create_safe');

  late final _safeTokenize = _library
      .lookupFunction<
        Int32 Function(
          Pointer<llama_vocab>,
          Pointer<Char>,
          Int32,
          Pointer<llama_token>,
          Int32,
          Bool,
          Bool,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        ),
        int Function(
          Pointer<llama_vocab>,
          Pointer<Char>,
          int,
          Pointer<llama_token>,
          int,
          bool,
          bool,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_tokenize_safe');

  late final _safeTokenToPiece = _library
      .lookupFunction<
        Int32 Function(
          Pointer<llama_vocab>,
          Int32,
          Pointer<Char>,
          Int32,
          Int32,
          Bool,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        ),
        int Function(
          Pointer<llama_vocab>,
          int,
          Pointer<Char>,
          int,
          int,
          bool,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_token_to_piece_safe');

  late final _safeDecode = _library
      .lookupFunction<
        Int32 Function(
          Pointer<llama_context>,
          llama_batch,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        ),
        int Function(
          Pointer<llama_context>,
          llama_batch,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_decode_safe');

  late final _safeSamplerCreate = _library
      .lookupFunction<
        Pointer<llama_sampler> Function(
          Pointer<llama_vocab>,
          Pointer<Char>,
          Pointer<Pointer<Char>>,
        ),
        Pointer<llama_sampler> Function(
          Pointer<llama_vocab>,
          Pointer<Char>,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_sampler_create_safe');

  late final _safeSamplerSample = _library
      .lookupFunction<
        Int32 Function(
          Pointer<llama_sampler>,
          Pointer<llama_context>,
          Int32,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        ),
        int Function(
          Pointer<llama_sampler>,
          Pointer<llama_context>,
          int,
          Pointer<Int32>,
          Pointer<Pointer<Char>>,
        )
      >('lib_llama_cpp_sampler_sample_safe');

  late final _safeSamplerFree = _library
      .lookupFunction<
        Void Function(Pointer<llama_sampler>),
        void Function(Pointer<llama_sampler>)
      >('lib_llama_cpp_sampler_free_safe');

  Map<String, Object?> chatTemplateCapabilities(Pointer<llama_model> model) {
    return _withWrapper('chat template capabilities', () {
      final error = calloc<Pointer<Char>>();
      Pointer<Void> handle = nullptr;
      try {
        handle = _chatTemplatesInit(model, nullptr, nullptr, nullptr, error);
        if (handle == nullptr) {
          throw _errorMessage(error, 'Failed to initialize chat templates.');
        }
        final caps = _library
            .lookupFunction<
              Pointer<Char> Function(Pointer<Void>, Pointer<Pointer<Char>>),
              Pointer<Char> Function(Pointer<Void>, Pointer<Pointer<Char>>)
            >('lib_llama_cpp_chat_templates_caps_json')(handle, error);
        if (caps == nullptr) {
          throw _errorMessage(
            error,
            'Failed to read chat template capabilities.',
          );
        }
        final decoded = jsonDecode(_takeString(caps));
        if (decoded is! Map<String, Object?>) {
          throw const NativeLlamaException(
            'Invalid native template capabilities JSON.',
          );
        }
        return decoded;
      } finally {
        if (handle != nullptr) _chatTemplatesFree(handle);
        _freeError(error);
        calloc.free(error);
      }
    });
  }

  _ChatTemplateResult applyChatTemplate({
    required Pointer<llama_model> model,
    required Map<String, Object?> request,
  }) {
    return _withWrapper('chat template formatting', () {
      final error = calloc<Pointer<Char>>();
      Pointer<Void> handle = nullptr;
      try {
        handle = _chatTemplatesInit(
          model,
          nullptr.cast<Char>(),
          nullptr.cast<Char>(),
          nullptr.cast<Char>(),
          error,
        );
        if (handle == nullptr) {
          throw _errorMessage(error, 'Failed to initialize chat templates.');
        }

        final requestPointer = jsonEncode(request).toNativeUtf8();
        try {
          final result = _chatTemplatesApplyJson(
            handle,
            requestPointer.cast<Char>(),
            error,
          );
          if (result == nullptr) {
            throw _errorMessage(error, 'Failed to apply chat template.');
          }
          final decoded = jsonDecode(_takeString(result));
          if (decoded is! Map<String, Object?>) {
            throw const NativeLlamaException(
              'Chat template wrapper returned invalid JSON.',
            );
          }
          return _ChatTemplateResult.fromJson(decoded);
        } finally {
          calloc.free(requestPointer);
        }
      } finally {
        if (handle != nullptr) {
          _chatTemplatesFree(handle);
        }
        _freeError(error);
        calloc.free(error);
      }
    });
  }

  Map<String, Object?> parseChatOutput({
    required String text,
    required String format,
    required String generationPrompt,
    required String parser,
    bool isPartial = false,
  }) {
    return _withWrapper('chat output parsing', () {
      final request = {
        'text': text,
        'format': format,
        'generation_prompt': generationPrompt,
        'parser': parser,
        'parse_tool_calls': true,
        'is_partial': isPartial,
      };
      final requestPointer = jsonEncode(request).toNativeUtf8();
      final error = calloc<Pointer<Char>>();
      try {
        final result = _chatParseJson(requestPointer.cast<Char>(), error);
        if (result == nullptr) {
          throw _errorMessage(error, 'Failed to parse chat output.');
        }
        final decoded = jsonDecode(_takeString(result));
        if (decoded is! Map<String, Object?>) {
          throw const NativeLlamaException(
            'Chat parser wrapper returned invalid JSON.',
          );
        }
        return decoded;
      } finally {
        _freeError(error);
        calloc.free(error);
        calloc.free(requestPointer);
      }
    });
  }

  Pointer<Void> mediaInit({
    required String mmprojPath,
    required Pointer<llama_model> model,
    required bool useGpu,
    required int? imageMinTokens,
    required int? imageMaxTokens,
  }) {
    return _withWrapper('multimodal projector loading', () {
      final pathPointer = mmprojPath.toNativeUtf8();
      final options = <String, Object?>{
        'use_gpu': useGpu,
        'media_marker': _MediaInput.mediaMarker,
        'warmup': false,
      };
      if (imageMinTokens != null) {
        options['image_min_tokens'] = imageMinTokens;
      }
      if (imageMaxTokens != null) {
        options['image_max_tokens'] = imageMaxTokens;
      }
      final optionsPointer = jsonEncode(options).toNativeUtf8();
      final error = calloc<Pointer<Char>>();
      try {
        final result = _mediaInit(
          pathPointer.cast<Char>(),
          model,
          optionsPointer.cast<Char>(),
          error,
        );
        if (result == nullptr) {
          throw _errorMessage(error, 'Failed to load multimodal projector.');
        }
        return result;
      } finally {
        _freeError(error);
        calloc.free(error);
        calloc.free(optionsPointer);
        calloc.free(pathPointer);
      }
    });
  }

  void mediaFree(Pointer<Void> mediaContext) {
    if (mediaContext == nullptr) {
      return;
    }
    _withWrapper('multimodal cleanup', () {
      _mediaFree(mediaContext);
    });
  }

  bool mediaSupportsVision(Pointer<Void> mediaContext) {
    return _withWrapper('multimodal capability detection', () {
      return _mediaSupportsVision(mediaContext);
    });
  }

  bool mediaSupportsAudio(Pointer<Void> mediaContext) {
    return _withWrapper('multimodal capability detection', () {
      return _mediaSupportsAudio(mediaContext);
    });
  }

  Pointer<Void> mediaBlob(Pointer<Void> mediaContext, _MediaInput input) {
    final part = input.part;
    if (part is LlamaImageFilePart) {
      return _mediaBlobFromFile(mediaContext, part.path, input.id);
    }
    if (part is LlamaAudioFilePart) {
      return _mediaBlobFromFile(mediaContext, part.path, input.id);
    }
    if (part is LlamaImageBytesPart) {
      return _mediaBlobFromBytes(mediaContext, part.bytes, input.id);
    }
    if (part is LlamaAudioBytesPart) {
      return _mediaBlobFromBytes(mediaContext, part.bytes, input.id);
    }
    throw ArgumentError.value(part, 'part', 'Unsupported media part');
  }

  void mediaBlobFree(Pointer<Void> blob) {
    if (blob == nullptr) {
      return;
    }
    _withWrapper('media cleanup', () {
      _mediaBlobFree(blob);
    });
  }

  ({int positions, int tokens}) mediaEvalPrompt({
    required Pointer<Void> mediaContext,
    required Pointer<llama_context> llamaContext,
    required String prompt,
    required List<Pointer<Void>> blobs,
    required int nBatch,
    required int reservedOutputTokens,
  }) {
    return _withWrapper('multimodal prompt evaluation', () {
      final promptPointer = prompt.toNativeUtf8();
      final blobArray = calloc<Pointer<Void>>(blobs.length);
      final newPast = calloc<Int32>();
      final error = calloc<Pointer<Char>>();
      try {
        for (var i = 0; i < blobs.length; i += 1) {
          blobArray[i] = blobs[i];
        }
        final result = _mediaEvalPrompt(
          mediaContext,
          llamaContext,
          promptPointer.cast<Char>(),
          blobArray,
          blobs.length,
          0,
          0,
          nBatch,
          true,
          true,
          true,
          reservedOutputTokens,
          newPast,
          error,
        );
        if (result != 0) {
          throw _errorMessage(
            error,
            'Failed to evaluate multimodal prompt: mtmd returned $result.',
          );
        }
        final promptTokens = _library
            .lookupFunction<
              Int64 Function(Pointer<Void>),
              int Function(Pointer<Void>)
            >('lib_llama_cpp_media_last_prompt_tokens')(mediaContext);
        return (positions: newPast.value, tokens: promptTokens);
      } finally {
        _freeError(error);
        calloc.free(error);
        calloc.free(newPast);
        calloc.free(blobArray);
        calloc.free(promptPointer);
      }
    });
  }

  Pointer<Void> _mediaBlobFromFile(
    Pointer<Void> mediaContext,
    String path,
    String id,
  ) {
    return _withWrapper('media file decoding', () {
      final pathPointer = path.toNativeUtf8();
      final idPointer = id.toNativeUtf8();
      final error = calloc<Pointer<Char>>();
      try {
        final result = _mediaBlobFromFileNative(
          mediaContext,
          pathPointer.cast<Char>(),
          idPointer.cast<Char>(),
          error,
        );
        if (result == nullptr) {
          throw _errorMessage(error, 'Failed to decode media file.');
        }
        return result;
      } finally {
        _freeError(error);
        calloc.free(error);
        calloc.free(idPointer);
        calloc.free(pathPointer);
      }
    });
  }

  Pointer<Void> _mediaBlobFromBytes(
    Pointer<Void> mediaContext,
    List<int> bytes,
    String id,
  ) {
    return _withWrapper('media byte decoding', () {
      final bytesPointer = calloc<Uint8>(bytes.length);
      final idPointer = id.toNativeUtf8();
      final error = calloc<Pointer<Char>>();
      try {
        for (var i = 0; i < bytes.length; i += 1) {
          bytesPointer[i] = bytes[i];
        }
        final result = _mediaBlobFromEncodedBytes(
          mediaContext,
          bytesPointer,
          bytes.length,
          idPointer.cast<Char>(),
          error,
        );
        if (result == nullptr) {
          throw _errorMessage(error, 'Failed to decode encoded media bytes.');
        }
        return result;
      } finally {
        _freeError(error);
        calloc.free(error);
        calloc.free(idPointer);
        calloc.free(bytesPointer);
      }
    });
  }

  T _withWrapper<T>(String feature, T Function() body) {
    try {
      return body();
    } on ArgumentError catch (error) {
      throw NativeLlamaException(
        'The loaded llama.cpp library does not include lib_llama_cpp native '
        'wrapper support for $feature: $error',
      );
    }
  }

  String _takeString(Pointer<Char> pointer) {
    try {
      return pointer.cast<Utf8>().toDartString();
    } finally {
      _stringFree(pointer);
    }
  }

  NativeLlamaException _errorMessage(
    Pointer<Pointer<Char>> errorPointer,
    String fallback,
  ) {
    final pointer = errorPointer.value;
    if (pointer == nullptr) {
      return NativeLlamaException(fallback);
    }

    try {
      return NativeLlamaException.fromNativeError(
        pointer.cast<Utf8>().toDartString(),
      );
    } finally {
      _stringFree(pointer);
      errorPointer.value = nullptr;
    }
  }

  void _freeError(Pointer<Pointer<Char>> errorPointer) {
    if (errorPointer.value != nullptr) {
      _stringFree(errorPointer.value);
      errorPointer.value = nullptr;
    }
  }

  late final _StringFreeDart _stringFree = _library
      .lookupFunction<_StringFreeNative, _StringFreeDart>(
        'lib_llama_cpp_string_free',
      );

  late final _ChatTemplatesInitDart _chatTemplatesInit = _library
      .lookupFunction<_ChatTemplatesInitNative, _ChatTemplatesInitDart>(
        'lib_llama_cpp_chat_templates_init',
      );

  late final _ChatTemplatesFreeDart _chatTemplatesFree = _library
      .lookupFunction<_ChatTemplatesFreeNative, _ChatTemplatesFreeDart>(
        'lib_llama_cpp_chat_templates_free',
      );

  late final _ChatTemplatesApplyJsonDart _chatTemplatesApplyJson = _library
      .lookupFunction<
        _ChatTemplatesApplyJsonNative,
        _ChatTemplatesApplyJsonDart
      >('lib_llama_cpp_chat_templates_apply_json');

  late final _ChatParseJsonDart _chatParseJson = _library
      .lookupFunction<_ChatParseJsonNative, _ChatParseJsonDart>(
        'lib_llama_cpp_chat_parse_json',
      );

  late final _MediaInitDart _mediaInit = _library
      .lookupFunction<_MediaInitNative, _MediaInitDart>(
        'lib_llama_cpp_media_init',
      );

  late final _MediaFreeDart _mediaFree = _library
      .lookupFunction<_MediaFreeNative, _MediaFreeDart>(
        'lib_llama_cpp_media_free',
      );

  late final _MediaSupportsDart _mediaSupportsVision = _library
      .lookupFunction<_MediaSupportsNative, _MediaSupportsDart>(
        'lib_llama_cpp_media_supports_vision',
      );

  late final _MediaSupportsDart _mediaSupportsAudio = _library
      .lookupFunction<_MediaSupportsNative, _MediaSupportsDart>(
        'lib_llama_cpp_media_supports_audio',
      );

  late final _MediaBlobFromFileDart _mediaBlobFromFileNative = _library
      .lookupFunction<_MediaBlobFromFileNative, _MediaBlobFromFileDart>(
        'lib_llama_cpp_media_blob_from_file',
      );

  late final _MediaBlobFromBytesDart _mediaBlobFromEncodedBytes = _library
      .lookupFunction<_MediaBlobFromBytesNative, _MediaBlobFromBytesDart>(
        'lib_llama_cpp_media_blob_from_encoded_bytes',
      );

  late final _MediaBlobFreeDart _mediaBlobFree = _library
      .lookupFunction<_MediaBlobFreeNative, _MediaBlobFreeDart>(
        'lib_llama_cpp_media_blob_free',
      );

  late final _MediaEvalPromptDart _mediaEvalPrompt = _library
      .lookupFunction<_MediaEvalPromptNative, _MediaEvalPromptDart>(
        'lib_llama_cpp_media_eval_prompt_with_budget',
      );
}

typedef _StringFreeNative = Void Function(Pointer<Char>);
typedef _StringFreeDart = void Function(Pointer<Char>);

typedef _ChatTemplatesInitNative =
    Pointer<Void> Function(
      Pointer<llama_model>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );
typedef _ChatTemplatesInitDart =
    Pointer<Void> Function(
      Pointer<llama_model>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );

typedef _ChatTemplatesFreeNative = Void Function(Pointer<Void>);
typedef _ChatTemplatesFreeDart = void Function(Pointer<Void>);

typedef _ChatTemplatesApplyJsonNative =
    Pointer<Char> Function(
      Pointer<Void>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );
typedef _ChatTemplatesApplyJsonDart =
    Pointer<Char> Function(
      Pointer<Void>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );

typedef _ChatParseJsonNative =
    Pointer<Char> Function(Pointer<Char>, Pointer<Pointer<Char>>);
typedef _ChatParseJsonDart =
    Pointer<Char> Function(Pointer<Char>, Pointer<Pointer<Char>>);

typedef _MediaInitNative =
    Pointer<Void> Function(
      Pointer<Char>,
      Pointer<llama_model>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );
typedef _MediaInitDart =
    Pointer<Void> Function(
      Pointer<Char>,
      Pointer<llama_model>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );

typedef _MediaFreeNative = Void Function(Pointer<Void>);
typedef _MediaFreeDart = void Function(Pointer<Void>);

typedef _MediaSupportsNative = Bool Function(Pointer<Void>);
typedef _MediaSupportsDart = bool Function(Pointer<Void>);

typedef _MediaBlobFromFileNative =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );
typedef _MediaBlobFromFileDart =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Char>,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );

typedef _MediaBlobFromBytesNative =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );
typedef _MediaBlobFromBytesDart =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Char>,
      Pointer<Pointer<Char>>,
    );

typedef _MediaBlobFreeNative = Void Function(Pointer<Void>);
typedef _MediaBlobFreeDart = void Function(Pointer<Void>);

typedef _MediaEvalPromptNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<llama_context>,
      Pointer<Char>,
      Pointer<Pointer<Void>>,
      Size,
      Int32,
      Int32,
      Int32,
      Bool,
      Bool,
      Bool,
      Int32,
      Pointer<Int32>,
      Pointer<Pointer<Char>>,
    );
typedef _MediaEvalPromptDart =
    int Function(
      Pointer<Void>,
      Pointer<llama_context>,
      Pointer<Char>,
      Pointer<Pointer<Void>>,
      int,
      int,
      int,
      int,
      bool,
      bool,
      bool,
      int,
      Pointer<Int32>,
      Pointer<Pointer<Char>>,
    );

DynamicLibrary openLlamaLibrary(LlamaCppLibraryDescriptor library) =>
    switch (library.resolution) {
      LlamaCppLibraryResolution.process => DynamicLibrary.process(),
      LlamaCppLibraryResolution.executable => DynamicLibrary.executable(),
      LlamaCppLibraryResolution.path => DynamicLibrary.open(library.path!),
      LlamaCppLibraryResolution.lookupName => DynamicLibrary.open(
        library.lookupName!,
      ),
    };

LlamaCppLibraryCapability? _backendCapability(String name) =>
    switch (name.toLowerCase()) {
      'cpu' => LlamaCppLibraryCapability.cpu,
      'cuda' => LlamaCppLibraryCapability.cuda,
      'vulkan' => LlamaCppLibraryCapability.vulkan,
      'metal' => LlamaCppLibraryCapability.metal,
      'opencl' => LlamaCppLibraryCapability.openCl,
      'blas' || 'openblas' => LlamaCppLibraryCapability.openBlas,
      'rpc' => LlamaCppLibraryCapability.rpc,
      'nnapi' => LlamaCppLibraryCapability.nnapi,
      _ => null,
    };
bool _isGpuCapability(LlamaCppLibraryCapability capability) => const {
  LlamaCppLibraryCapability.cuda,
  LlamaCppLibraryCapability.vulkan,
  LlamaCppLibraryCapability.metal,
  LlamaCppLibraryCapability.openCl,
}.contains(capability);
