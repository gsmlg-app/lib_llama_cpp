final class LlamaState {
  const LlamaState({this.modelPath, this.isModelLoaded = false});

  const LlamaState.empty() : modelPath = null, isModelLoaded = false;

  final String? modelPath;
  final bool isModelLoaded;

  LlamaState copyWith({String? modelPath, bool? isModelLoaded}) {
    return LlamaState(
      modelPath: modelPath ?? this.modelPath,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaState &&
            other.modelPath == modelPath &&
            other.isModelLoaded == isModelLoaded;
  }

  @override
  int get hashCode => Object.hash(modelPath, isModelLoaded);

  @override
  String toString() {
    return 'LlamaState(modelPath: $modelPath, isModelLoaded: $isModelLoaded)';
  }
}
