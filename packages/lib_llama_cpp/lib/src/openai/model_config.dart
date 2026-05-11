final class LlamaModelConfig {
  const LlamaModelConfig({
    required this.modelPath,
    this.contextSize,
    this.gpuLayerCount,
  });

  final String modelPath;
  final int? contextSize;
  final int? gpuLayerCount;
}
