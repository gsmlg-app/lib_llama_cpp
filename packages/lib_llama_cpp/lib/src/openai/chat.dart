import 'responses.dart';

final class LlamaChatResource {
  LlamaChatResource({required LlamaResponsesResource responses})
    : completions = LlamaChatCompletionsResource(responses: responses);

  final LlamaChatCompletionsResource completions;
}

final class LlamaChatCompletionsResource {
  const LlamaChatCompletionsResource({
    required LlamaResponsesResource responses,
  }) : _responses = responses;

  final LlamaResponsesResource _responses;

  Future<LlamaChatCompletion> create({
    required String model,
    required List<LlamaChatMessage> messages,
    int? maxTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
  }) async {
    final response = await _responses.create(
      model: model,
      input: _promptFromMessages(messages),
      maxOutputTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      stop: stop,
    );

    return LlamaChatCompletion(
      id: 'chatcmpl_${DateTime.now().toUtc().microsecondsSinceEpoch}',
      createdAt: DateTime.now().toUtc(),
      model: model,
      choices: [
        LlamaChatChoice(
          index: 0,
          message: LlamaChatMessage(
            role: 'assistant',
            content: response.outputText,
          ),
          finishReason: 'stop',
        ),
      ],
    );
  }

  String _promptFromMessages(List<LlamaChatMessage> messages) {
    return messages
        .map((message) => '${message.role}: ${message.content}')
        .join('\n');
  }
}

final class LlamaChatMessage {
  const LlamaChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

final class LlamaChatCompletion {
  const LlamaChatCompletion({
    required this.id,
    required this.createdAt,
    required this.model,
    required this.choices,
  });

  final String id;
  final DateTime createdAt;
  final String model;
  final List<LlamaChatChoice> choices;
}

final class LlamaChatChoice {
  const LlamaChatChoice({
    required this.index,
    required this.message,
    required this.finishReason,
  });

  final int index;
  final LlamaChatMessage message;
  final String finishReason;
}
