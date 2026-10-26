import '../lib_llama_cpp.dart';
import '../llama_command.dart';
import '../llama_response.dart';
import '../llama_tool.dart';
import 'errors.dart';
import 'model_config.dart';

typedef LlamaModelResolver = LlamaModelConfig Function(String model);

final class LlamaResponseObject {
  const LlamaResponseObject({
    required this.id,
    required this.createdAt,
    required this.model,
    required this.status,
    required this.output,
    required this.outputText,
    this.error,
    this.metadata = const {},
    this.usage,
    this.finishReason,
    this.toolCalls = const [],
  });

  final String id;
  final DateTime createdAt;
  final String model;
  final String status;
  final List<LlamaResponseOutputItem> output;
  final String outputText;
  final LlamaOpenAIException? error;
  final Map<String, String> metadata;
  final LlamaResponseUsage? usage;
  final String? finishReason;
  final List<LlamaToolCall> toolCalls;
}

final class LlamaResponseOutputItem {
  const LlamaResponseOutputItem({required this.text, this.toolCall});

  final String text;
  final LlamaToolCall? toolCall;
}

final class LlamaResponseUsage {
  const LlamaResponseUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
}

final class LlamaResponseInputItem {
  const LlamaResponseInputItem({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
    this.name,
  });

  factory LlamaResponseInputItem.fromJson(Map<String, Object?> json) {
    final message = LlamaMessage.fromJson(json);
    return LlamaResponseInputItem(
      role: message.role,
      content: message.content,
      toolCalls: message.toolCalls,
      toolCallId: message.toolCallId,
      name: message.name,
    );
  }

  final String role;
  final Object content;
  final List<LlamaToolCall> toolCalls;
  final String? toolCallId;
  final String? name;

  Map<String, Object?> toJson() {
    return LlamaMessage(
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      name: name,
    ).toJson();
  }
}

sealed class LlamaResponseStreamEvent {
  const LlamaResponseStreamEvent({required this.type});

  final String type;
}

final class LlamaResponseCreated extends LlamaResponseStreamEvent {
  const LlamaResponseCreated({required this.response})
    : super(type: 'response.created');

  final LlamaResponseObject response;
}

final class LlamaResponseOutputTextDelta extends LlamaResponseStreamEvent {
  const LlamaResponseOutputTextDelta({required this.delta, required this.index})
    : super(type: 'response.output_text.delta');

  final String delta;
  final int index;
}

final class LlamaResponseOutputTextDone extends LlamaResponseStreamEvent {
  const LlamaResponseOutputTextDone({required this.text})
    : super(type: 'response.output_text.done');

  final String text;
}

final class LlamaResponseCompleted extends LlamaResponseStreamEvent {
  const LlamaResponseCompleted({required this.response})
    : super(type: 'response.completed');

  final LlamaResponseObject response;
}

final class LlamaResponseFailed extends LlamaResponseStreamEvent {
  const LlamaResponseFailed({required this.error})
    : super(type: 'response.failed');

  final LlamaOpenAIException error;
}

final class LlamaResponseToolCallDone extends LlamaResponseStreamEvent {
  const LlamaResponseToolCallDone({required this.toolCall})
    : super(type: 'response.output_item.done');

  final LlamaToolCall toolCall;
}

final class LlamaResponseRequiresAction extends LlamaResponseStreamEvent {
  const LlamaResponseRequiresAction({
    required this.response,
    required this.toolCalls,
  }) : super(type: 'response.requires_action');

  final LlamaResponseObject response;
  final List<LlamaToolCall> toolCalls;
}

final class LlamaResponsesResource {
  const LlamaResponsesResource({
    required LlamaModelResolver resolveModel,
    required LlamaEngine engine,
  }) : _resolveModel = resolveModel,
       _engine = engine;

  final LlamaModelResolver _resolveModel;
  final LlamaEngine _engine;

  Future<LlamaResponseObject> create({
    required String model,
    required Object input,
    String? instructions,
    int? maxOutputTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
    Map<String, String> metadata = const {},
    bool store = false,
    List<LlamaTool> tools = const [],
    LlamaToolChoice toolChoice = LlamaToolChoice.auto,
    bool parallelToolCalls = false,
  }) async {
    if (store) {
      throw const LlamaOpenAIException(
        code: 'unsupported_parameter',
        message: 'Stored responses are not supported by local llama.cpp.',
        param: 'store',
      );
    }

    final config = _resolveModel(model);
    final messages = _messagesFromInput(input, instructions: instructions);
    _validateCapabilities(config: config, messages: messages);
    final output = StringBuffer();
    final toolCalls = <LlamaToolCall>[];
    LlamaDoneResponse? completion;

    final commands = Stream<LlamaCommand>.fromIterable(
      _commandsForRequest(
        config: config,
        messages: messages,
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        stop: stop,
        tools: tools,
        toolChoice: toolChoice,
        parallelToolCalls: parallelToolCalls,
      ),
    );

    await for (final response in _engine.transform(commands)) {
      switch (response) {
        case LlamaTokenResponse(:final text):
          output.write(text);
        case LlamaToolCallResponse(:final toolCall):
          toolCalls.add(toolCall);
        case LlamaErrorResponse(:final message, :final code, :final details):
          throw LlamaOpenAIException(
            code: code ?? 'generation_failed',
            message: message,
            details: details,
            type: 'server_error',
          );
        case LlamaDoneResponse():
          if (response.inputTokens != null) completion = response;
        case LlamaReadyResponse() || LlamaStateChangedResponse():
          break;
      }
    }

    _ensureEngineOpen();
    final now = DateTime.now().toUtc();
    final outputText = output.toString();

    return LlamaResponseObject(
      id: 'resp_${now.microsecondsSinceEpoch}',
      createdAt: now,
      model: model,
      status: toolCalls.isEmpty ? 'completed' : 'requires_action',
      output: [
        if (outputText.isNotEmpty) LlamaResponseOutputItem(text: outputText),
        for (final toolCall in toolCalls)
          LlamaResponseOutputItem(text: '', toolCall: toolCall),
      ],
      outputText: outputText,
      metadata: metadata,
      toolCalls: toolCalls,
      usage: _usage(completion),
      finishReason: completion?.finishReason,
    );
  }

  Stream<LlamaResponseStreamEvent> stream({
    required String model,
    required Object input,
    String? instructions,
    int? maxOutputTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
    Map<String, String> metadata = const {},
    bool store = false,
    List<LlamaTool> tools = const [],
    LlamaToolChoice toolChoice = LlamaToolChoice.auto,
    bool parallelToolCalls = false,
  }) async* {
    final createdAt = DateTime.now().toUtc();
    final responseId = 'resp_${createdAt.microsecondsSinceEpoch}';

    yield LlamaResponseCreated(
      response: LlamaResponseObject(
        id: responseId,
        createdAt: createdAt,
        model: model,
        status: 'in_progress',
        output: const [],
        outputText: '',
        metadata: metadata,
      ),
    );

    final output = StringBuffer();
    final toolCalls = <LlamaToolCall>[];
    LlamaDoneResponse? completion;

    try {
      if (store) {
        throw const LlamaOpenAIException(
          code: 'unsupported_parameter',
          message: 'Stored responses are not supported by local llama.cpp.',
          param: 'store',
        );
      }

      final config = _resolveModel(model);
      final messages = _messagesFromInput(input, instructions: instructions);
      _validateCapabilities(config: config, messages: messages);
      final commands = Stream<LlamaCommand>.fromIterable(
        _commandsForRequest(
          config: config,
          messages: messages,
          maxOutputTokens: maxOutputTokens,
          temperature: temperature,
          topP: topP,
          stop: stop,
          tools: tools,
          toolChoice: toolChoice,
          parallelToolCalls: parallelToolCalls,
        ),
      );

      await for (final response in _engine.transform(commands)) {
        switch (response) {
          case LlamaTokenResponse(:final text, :final index):
            output.write(text);
            yield LlamaResponseOutputTextDelta(delta: text, index: index);
          case LlamaToolCallResponse(:final toolCall):
            toolCalls.add(toolCall);
            yield LlamaResponseToolCallDone(toolCall: toolCall);
          case LlamaErrorResponse(:final message, :final code, :final details):
            yield LlamaResponseFailed(
              error: LlamaOpenAIException(
                code: code ?? 'generation_failed',
                message: message,
                details: details,
                type: 'server_error',
              ),
            );
            return;
          case LlamaDoneResponse():
            if (response.inputTokens != null) completion = response;
          case LlamaReadyResponse() || LlamaStateChangedResponse():
            break;
        }
      }
      _ensureEngineOpen();
    } on LlamaOpenAIException catch (error) {
      yield LlamaResponseFailed(error: error);
      return;
    }

    final outputText = output.toString();
    if (toolCalls.isNotEmpty) {
      yield LlamaResponseRequiresAction(
        toolCalls: toolCalls,
        response: LlamaResponseObject(
          id: responseId,
          createdAt: createdAt,
          model: model,
          status: 'requires_action',
          output: [
            if (outputText.isNotEmpty)
              LlamaResponseOutputItem(text: outputText),
            for (final toolCall in toolCalls)
              LlamaResponseOutputItem(text: '', toolCall: toolCall),
          ],
          outputText: outputText,
          metadata: metadata,
          toolCalls: toolCalls,
          usage: _usage(completion),
          finishReason: completion?.finishReason,
        ),
      );
      return;
    }

    yield LlamaResponseOutputTextDone(text: outputText);
    yield LlamaResponseCompleted(
      response: LlamaResponseObject(
        id: responseId,
        createdAt: createdAt,
        model: model,
        status: 'completed',
        output: [LlamaResponseOutputItem(text: outputText)],
        outputText: outputText,
        metadata: metadata,
        usage: _usage(completion),
        finishReason: completion?.finishReason,
      ),
    );
  }

  void _ensureEngineOpen() {
    final engine = _engine;
    if (engine is ResidentLlamaEngine && engine.isClosed) {
      throw const LlamaOpenAIException(
        code: 'generation_cancelled',
        message: 'The inference session was closed during generation.',
      );
    }
  }

  List<LlamaMessage> _messagesFromInput(Object input, {String? instructions}) {
    final body = switch (input) {
      final String text => [LlamaMessage(role: 'user', content: text)],
      final List<LlamaResponseInputItem> items => [
        for (final item in items)
          LlamaMessage(
            role: item.role,
            content: item.content,
            toolCalls: item.toolCalls,
            toolCallId: item.toolCallId,
            name: item.name,
          ),
      ],
      final List<Object?> items => [
        for (final item in items) _messageFromObject(item),
      ],
      _ => throw const LlamaOpenAIException(
        code: 'unsupported_parameter',
        message:
            'Only string input or typed response input items are supported.',
        param: 'input',
      ),
    };

    if (instructions == null || instructions.isEmpty) {
      return body;
    }

    return [LlamaMessage(role: 'system', content: instructions), ...body];
  }

  Iterable<LlamaCommand> _commandsForRequest({
    required LlamaModelConfig config,
    required List<LlamaMessage> messages,
    required int? maxOutputTokens,
    required double? temperature,
    required double? topP,
    required List<String> stop,
    required List<LlamaTool> tools,
    required LlamaToolChoice toolChoice,
    required bool parallelToolCalls,
  }) sync* {
    yield LlamaLoadModelCommand(
      modelPath: config.modelPath,
      contextSize: config.contextSize,
      gpuLayerCount: config.gpuLayerCount,
      batchSize: config.batchSize,
      microBatchSize: config.microBatchSize,
      threadCount: config.threadCount,
      batchThreadCount: config.batchThreadCount,
      flashAttention: config.flashAttention,
      cacheTypeK: config.cacheTypeK,
      cacheTypeV: config.cacheTypeV,
      swaFull: config.swaFull,
      mmprojPath: config.mmprojPath,
      mmprojUseGpu: config.mmprojUseGpu,
      imageMinTokens: config.imageMinTokens,
      imageMaxTokens: config.imageMaxTokens,
    );

    yield LlamaGenerateMessagesCommand(
      messages: messages,
      maxTokens: maxOutputTokens,
      temperature: temperature,
      topP: topP,
      stop: stop,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
    );

    yield const LlamaDisposeCommand();
  }

  void _validateCapabilities({
    required LlamaModelConfig config,
    required List<LlamaMessage> messages,
  }) {
    if (messages.any((message) => message.hasMedia) &&
        config.mmprojPath == null) {
      throw const LlamaOpenAIException(
        code: 'unsupported_model_capability',
        message: 'Image and audio inputs require LlamaModelConfig.mmprojPath.',
        param: 'input',
      );
    }
  }
}

LlamaResponseUsage? _usage(LlamaDoneResponse? completion) {
  final input = completion?.inputTokens;
  final output = completion?.outputTokens;
  if (input == null || output == null) return null;
  return LlamaResponseUsage(
    inputTokens: input,
    outputTokens: output,
    totalTokens: input + output,
  );
}

LlamaMessage _messageFromObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const LlamaOpenAIException(
      code: 'unsupported_parameter',
      message: 'Expected response input message objects.',
      param: 'input',
    );
  }
  return LlamaMessage.fromJson(value.cast<String, Object?>());
}
