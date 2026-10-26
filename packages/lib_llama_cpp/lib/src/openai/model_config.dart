final class LlamaModelConfig {
  const LlamaModelConfig({
    required this.modelPath,
    this.contextSize,
    this.gpuLayerCount,
    this.batchSize,
    this.microBatchSize,
    this.threadCount,
    this.batchThreadCount,
    this.flashAttention,
    this.cacheTypeK,
    this.cacheTypeV,
    this.swaFull = false,
    this.mmprojPath,
    this.mmprojUseGpu = false,
    this.imageMinTokens,
    this.imageMaxTokens,
  });

  final String modelPath;
  final int? contextSize;
  final int? gpuLayerCount;
  final int? batchSize;
  final int? microBatchSize;
  final int? threadCount;
  final int? batchThreadCount;
  final int? flashAttention;
  final int? cacheTypeK;
  final int? cacheTypeV;
  final bool swaFull;
  final String? mmprojPath;
  final bool mmprojUseGpu;
  final int? imageMinTokens;
  final int? imageMaxTokens;
}
