import '../lib_llama_cpp.dart';
import '../llama_command.dart';
import '../llama_response.dart';
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
}

final class LlamaResponseOutputItem {
  const LlamaResponseOutputItem({required this.text});

  final String text;
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
  const LlamaResponseInputItem({required this.role, required this.content});

  final String role;
  final String content;
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

final class LlamaResponsesResource {
  const LlamaResponsesResource({
    required LlamaModelResolver resolveModel,
    required LibLlamaCpp engine,
  }) : _resolveModel = resolveModel,
       _engine = engine;

  final LlamaModelResolver _resolveModel;
  final LibLlamaCpp _engine;

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
  }) async {
    if (store) {
      throw const LlamaOpenAIException(
        code: 'unsupported_parameter',
        message: 'Stored responses are not supported by local llama.cpp.',
        param: 'store',
      );
    }

    final config = _resolveModel(model);
    final prompt = _promptFromInput(input, instructions: instructions);
    final output = StringBuffer();

    final commands = Stream<LlamaCommand>.fromIterable([
      LlamaLoadModelCommand(
        modelPath: config.modelPath,
        contextSize: config.contextSize,
        gpuLayerCount: config.gpuLayerCount,
      ),
      LlamaGenerateCommand(prompt: prompt, maxTokens: maxOutputTokens),
      const LlamaDisposeCommand(),
    ]);

    await for (final response in _engine.transform(commands)) {
      switch (response) {
        case LlamaTokenResponse(:final text):
          output.write(text);
        case LlamaErrorResponse(:final message):
          throw LlamaOpenAIException(
            code: 'generation_failed',
            message: message,
            type: 'server_error',
          );
        case LlamaReadyResponse() ||
            LlamaStateChangedResponse() ||
            LlamaDoneResponse():
          break;
      }
    }

    final now = DateTime.now().toUtc();
    final outputText = output.toString();

    return LlamaResponseObject(
      id: 'resp_${now.microsecondsSinceEpoch}',
      createdAt: now,
      model: model,
      status: 'completed',
      output: [LlamaResponseOutputItem(text: outputText)],
      outputText: outputText,
      metadata: metadata,
      usage: const LlamaResponseUsage(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
      ),
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

    try {
      if (store) {
        throw const LlamaOpenAIException(
          code: 'unsupported_parameter',
          message: 'Stored responses are not supported by local llama.cpp.',
          param: 'store',
        );
      }

      final config = _resolveModel(model);
      final prompt = _promptFromInput(input, instructions: instructions);
      final commands = Stream<LlamaCommand>.fromIterable([
        LlamaLoadModelCommand(
          modelPath: config.modelPath,
          contextSize: config.contextSize,
          gpuLayerCount: config.gpuLayerCount,
        ),
        LlamaGenerateCommand(prompt: prompt, maxTokens: maxOutputTokens),
        const LlamaDisposeCommand(),
      ]);

      await for (final response in _engine.transform(commands)) {
        switch (response) {
          case LlamaTokenResponse(:final text, :final index):
            output.write(text);
            yield LlamaResponseOutputTextDelta(delta: text, index: index);
          case LlamaErrorResponse(:final message):
            yield LlamaResponseFailed(
              error: LlamaOpenAIException(
                code: 'generation_failed',
                message: message,
                type: 'server_error',
              ),
            );
            return;
          case LlamaReadyResponse() ||
              LlamaStateChangedResponse() ||
              LlamaDoneResponse():
            break;
        }
      }
    } on LlamaOpenAIException catch (error) {
      yield LlamaResponseFailed(error: error);
      return;
    }

    final outputText = output.toString();
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
        usage: const LlamaResponseUsage(
          inputTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
        ),
      ),
    );
  }

  String _promptFromInput(Object input, {String? instructions}) {
    final body = switch (input) {
      final String text => text,
      final List<LlamaResponseInputItem> items =>
        items.map((item) => '${item.role}: ${item.content}').join('\n'),
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

    return '$instructions\n\n$body';
  }
}
