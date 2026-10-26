import '../lib_llama_cpp.dart';
import 'chat.dart';
import 'errors.dart';
import 'model_config.dart';
import 'responses.dart';

final class LlamaOpenAIClient {
  LlamaOpenAIClient({
    required Map<String, LlamaModelConfig> models,
    LlamaEngine? engine,
  }) : _models = Map.unmodifiable(models),
       _ownedEngine = engine == null ? ResidentLlamaEngine() : null {
    final effectiveEngine = engine ?? _ownedEngine!;
    responses = LlamaResponsesResource(
      resolveModel: _resolveModel,
      engine: effectiveEngine,
    );
    chat = LlamaChatResource(responses: responses);
  }

  final Map<String, LlamaModelConfig> _models;
  final ResidentLlamaEngine? _ownedEngine;

  /// Releases the default resident engine; injected engines retain their owner.
  Future<void> close() async {
    await _ownedEngine?.close();
  }

  late final LlamaResponsesResource responses;
  late final LlamaChatResource chat;

  LlamaModelConfig _resolveModel(String model) {
    final config = _models[model];
    if (config == null) {
      throw LlamaOpenAIException(
        code: 'model_not_found',
        message: 'Model "$model" is not registered.',
        param: 'model',
      );
    }
    return config;
  }
}
