sealed class LlamaCommand {
  const LlamaCommand();
}

final class LlamaLoadModelCommand extends LlamaCommand {
  const LlamaLoadModelCommand({
    required this.modelPath,
    this.contextSize,
    this.gpuLayerCount,
  });

  final String modelPath;
  final int? contextSize;
  final int? gpuLayerCount;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaLoadModelCommand &&
            other.modelPath == modelPath &&
            other.contextSize == contextSize &&
            other.gpuLayerCount == gpuLayerCount;
  }

  @override
  int get hashCode => Object.hash(modelPath, contextSize, gpuLayerCount);

  @override
  String toString() {
    return 'LlamaLoadModelCommand('
        'modelPath: $modelPath, '
        'contextSize: $contextSize, '
        'gpuLayerCount: $gpuLayerCount'
        ')';
  }
}

final class LlamaGenerateCommand extends LlamaCommand {
  const LlamaGenerateCommand({
    required this.prompt,
    this.maxTokens,
    this.temperature,
    this.topP,
    this.stop = const [],
  });

  final String prompt;
  final int? maxTokens;
  final double? temperature;
  final double? topP;
  final List<String> stop;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaGenerateCommand &&
            other.prompt == prompt &&
            other.maxTokens == maxTokens &&
            other.temperature == temperature &&
            other.topP == topP &&
            _listEquals(other.stop, stop);
  }

  @override
  int get hashCode =>
      Object.hash(prompt, maxTokens, temperature, topP, Object.hashAll(stop));

  @override
  String toString() {
    return 'LlamaGenerateCommand('
        'prompt: $prompt, '
        'maxTokens: $maxTokens, '
        'temperature: $temperature, '
        'topP: $topP, '
        'stop: $stop'
        ')';
  }
}

final class LlamaDisposeCommand extends LlamaCommand {
  const LlamaDisposeCommand();

  @override
  bool operator ==(Object other) {
    return other is LlamaDisposeCommand;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'LlamaDisposeCommand()';
}

bool _listEquals<T>(List<T> first, List<T> second) {
  if (identical(first, second)) {
    return true;
  }
  if (first.length != second.length) {
    return false;
  }

  for (var i = 0; i < first.length; i += 1) {
    if (first[i] != second[i]) {
      return false;
    }
  }
  return true;
}
