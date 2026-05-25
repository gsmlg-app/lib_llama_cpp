import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

const _modelName = 'example-e2e-harness';
const _dartDefineModelPath = String.fromEnvironment('LIB_LLAMA_CPP_TEST_MODEL');
const _dartDefineModelAsset = String.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_MODEL_ASSET',
);
const _dartDefineMmprojPath = String.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_MMPROJ',
);
const _dartDefineMmprojAsset = String.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_MMPROJ_ASSET',
);
const _dartDefinePrompt = String.fromEnvironment('LIB_LLAMA_CPP_TEST_PROMPT');
const _dartDefineTokens = int.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_TOKENS',
  defaultValue: -1,
);
const _dartDefineBackend = String.fromEnvironment('LIB_LLAMA_CPP_TEST_BACKEND');
const _dartDefineGpuLayerCount = int.fromEnvironment(
  'LIB_LLAMA_CPP_TEST_GPU_LAYERS',
  defaultValue: -1,
);

void main() {
  runApp(InferenceDemoApp(config: LlamaE2eHarnessConfig.fromEnvironment()));
}

final class LlamaE2eHarnessConfig {
  const LlamaE2eHarnessConfig({
    required this.modelPath,
    required this.modelAsset,
    required this.mmprojPath,
    required this.mmprojAsset,
    required this.prompt,
    required this.maxOutputTokens,
    required this.backend,
    required this.gpuLayerCount,
  });

  factory LlamaE2eHarnessConfig.fromEnvironment() {
    return LlamaE2eHarnessConfig(
      modelPath: _stringSetting(
        'LIB_LLAMA_CPP_TEST_MODEL',
        _dartDefineModelPath,
      ),
      modelAsset: _stringSetting(
        'LIB_LLAMA_CPP_TEST_MODEL_ASSET',
        _dartDefineModelAsset,
      ),
      mmprojPath: _stringSetting(
        'LIB_LLAMA_CPP_TEST_MMPROJ',
        _dartDefineMmprojPath,
      ),
      mmprojAsset: _stringSetting(
        'LIB_LLAMA_CPP_TEST_MMPROJ_ASSET',
        _dartDefineMmprojAsset,
      ),
      prompt: _stringSetting(
        'LIB_LLAMA_CPP_TEST_PROMPT',
        _dartDefinePrompt,
        defaultValue: 'Say hello in one short sentence.',
      ),
      maxOutputTokens: _intSetting(
        'LIB_LLAMA_CPP_TEST_TOKENS',
        _dartDefineTokens,
        defaultValue: 24,
      ),
      backend: _stringSetting('LIB_LLAMA_CPP_TEST_BACKEND', _dartDefineBackend),
      gpuLayerCount: _nullableIntSetting(
        'LIB_LLAMA_CPP_TEST_GPU_LAYERS',
        _dartDefineGpuLayerCount,
      ),
    );
  }

  final String modelPath;
  final String modelAsset;
  final String mmprojPath;
  final String mmprojAsset;
  final String prompt;
  final int maxOutputTokens;
  final String backend;
  final int? gpuLayerCount;

  bool get hasModel => modelPath.isNotEmpty || modelAsset.isNotEmpty;
  bool get hasMmproj => mmprojPath.isNotEmpty || mmprojAsset.isNotEmpty;

  String get backendLabel => backend.isEmpty ? 'cpu' : backend;

  LlamaCppLibraryCapability? get backendCapability {
    return switch (backendLabel) {
      'cpu' => null,
      'metal' => LlamaCppLibraryCapability.metal,
      'vulkan' => LlamaCppLibraryCapability.vulkan,
      _ => throw ArgumentError.value(
        backend,
        'LIB_LLAMA_CPP_TEST_BACKEND',
        'Expected cpu, metal, or vulkan',
      ),
    };
  }

  Future<LlamaModelConfig> toModelConfig() async {
    final resolvedModelPath = await _materializeAsset(
      assetPath: modelAsset,
      fallbackPath: modelPath,
    );
    final resolvedMmprojPath = await _materializeAsset(
      assetPath: mmprojAsset,
      fallbackPath: mmprojPath,
    );

    return LlamaModelConfig(
      modelPath: resolvedModelPath,
      mmprojPath: resolvedMmprojPath.isEmpty ? null : resolvedMmprojPath,
      contextSize: hasMmproj ? 4096 : 1024,
      gpuLayerCount: gpuLayerCount,
    );
  }
}

final class LlamaE2eHarnessRunner {
  LlamaE2eHarnessRunner(this.config)
    : _platform = LlamaE2eHarnessPlatform(
        backendCapability: config.backendCapability,
      );

  final LlamaE2eHarnessConfig config;
  final LlamaE2eHarnessPlatform _platform;

  Future<LlamaOpenAIClient> createClient() async {
    return LlamaOpenAIClient(
      models: {_modelName: await config.toModelConfig()},
      engine: LibLlamaCpp(platform: _platform),
    );
  }

  Future<LlamaCppLibraryDescriptor> resolveLibrary() {
    final capability = config.backendCapability;
    return _platform.resolveLibrary(
      request: LlamaCppLibraryRequest(requiredCapabilities: {?capability}),
    );
  }

  Future<void> expectRequiredBackendSupport() async {
    final capability = config.backendCapability;
    if (capability == null) {
      return;
    }

    final descriptor = await resolveLibrary();
    final bindings = LlamaCppBindings(_openDynamicLibrary(descriptor));
    if (!bindings.llama_supports_gpu_offload()) {
      throw StateError(
        'The ${capability.name} e2e library must expose llama.cpp GPU '
        'offload support before model loading runs.',
      );
    }
  }

  Stream<LlamaResponseStreamEvent> streamText(LlamaOpenAIClient client) {
    return client.responses.stream(
      model: _modelName,
      input: config.prompt,
      maxOutputTokens: config.maxOutputTokens,
      temperature: 0,
    );
  }
}

final class LlamaE2eHarnessPlatform extends LibLlamaCppPlatform {
  LlamaE2eHarnessPlatform({
    this.backendCapability,
    LibLlamaCppPlatform? basePlatform,
  }) : _basePlatform = basePlatform ?? LibLlamaCppPlatform.instance;

  final LlamaCppLibraryCapability? backendCapability;
  final LibLlamaCppPlatform _basePlatform;

  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    final descriptor = await _basePlatform.resolveLibrary(
      request: LlamaCppLibraryRequest(preferredPath: request.preferredPath),
    );
    final capabilities = {...descriptor.capabilities, ?backendCapability};
    final unsupported = request.requiredCapabilities
        .where((capability) => !capabilities.contains(capability))
        .map((capability) => capability.name)
        .toList();
    if (unsupported.isNotEmpty) {
      throw UnsupportedError(
        'Example e2e harness library does not support: '
        '${unsupported.join(', ')}',
      );
    }

    return LlamaCppLibraryDescriptor(
      resolution: descriptor.resolution,
      path: descriptor.path,
      lookupName: descriptor.lookupName,
      capabilities: capabilities,
    );
  }
}

final class InferenceDemoApp extends StatelessWidget {
  const InferenceDemoApp({required this.config, super.key});

  final LlamaE2eHarnessConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lib_llama_cpp E2E Harness',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: InferenceDemoScreen(config: config),
    );
  }
}

final class InferenceDemoScreen extends StatefulWidget {
  const InferenceDemoScreen({required this.config, super.key});

  final LlamaE2eHarnessConfig config;

  @override
  State<InferenceDemoScreen> createState() => _InferenceDemoScreenState();
}

final class _InferenceDemoScreenState extends State<InferenceDemoScreen> {
  final _events = <String>[];
  var _isRunning = false;

  Future<void> _runHarness() async {
    if (_isRunning) {
      return;
    }

    if (!widget.config.hasModel) {
      setState(() => _events.add('Set LIB_LLAMA_CPP_TEST_MODEL first.'));
      return;
    }

    setState(() {
      _events.clear();
      _isRunning = true;
    });

    final runner = LlamaE2eHarnessRunner(widget.config);

    try {
      await runner.expectRequiredBackendSupport();
      final client = await runner.createClient();
      await for (final event in runner.streamText(client)) {
        if (!mounted) {
          return;
        }
        setState(() => _events.add(_describeResponseEvent(event)));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _events.add(error.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
      }
    }
  }

  String _describeResponseEvent(LlamaResponseStreamEvent event) {
    return switch (event) {
      LlamaResponseOutputTextDelta(:final delta) => '${event.type}: $delta',
      LlamaResponseFailed(:final error) => '${event.type}: ${error.message}',
      _ => event.type,
    };
  }

  @override
  Widget build(BuildContext context) {
    final modelLabel = widget.config.modelAsset.isNotEmpty
        ? widget.config.modelAsset
        : widget.config.modelPath.isNotEmpty
        ? widget.config.modelPath
        : 'No model configured';

    return Scaffold(
      appBar: AppBar(title: const Text('lib_llama_cpp E2E')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Backend: ${widget.config.backendLabel}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(modelLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isRunning ? null : _runHarness,
                icon: _isRunning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isRunning ? 'Running' : 'Run harness smoke'),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _events.isEmpty
                      ? const Center(child: Text('No events yet'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _events.length,
                          separatorBuilder: (context, index) => const Divider(),
                          itemBuilder: (context, index) {
                            return SelectableText(_events[index]);
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _stringSetting(
  String name,
  String dartDefineValue, {
  String defaultValue = '',
}) {
  if (dartDefineValue.isNotEmpty) {
    return dartDefineValue;
  }
  return Platform.environment[name] ?? defaultValue;
}

int _intSetting(String name, int dartDefineValue, {required int defaultValue}) {
  if (dartDefineValue >= 0) {
    return dartDefineValue;
  }
  return int.tryParse(Platform.environment[name] ?? '') ?? defaultValue;
}

int? _nullableIntSetting(String name, int dartDefineValue) {
  if (dartDefineValue >= 0) {
    return dartDefineValue;
  }
  return int.tryParse(Platform.environment[name] ?? '');
}

Future<String> _materializeAsset({
  required String assetPath,
  required String fallbackPath,
}) async {
  if (assetPath.isEmpty) {
    return fallbackPath;
  }

  final bytes = await rootBundle.load(assetPath);
  final fileName = assetPath.split('/').last;
  final file = File('${Directory.systemTemp.path}/lib_llama_cpp_e2e_$fileName');
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return file.path;
}

DynamicLibrary _openDynamicLibrary(LlamaCppLibraryDescriptor descriptor) {
  return switch (descriptor.resolution) {
    LlamaCppLibraryResolution.process => DynamicLibrary.process(),
    LlamaCppLibraryResolution.executable => DynamicLibrary.executable(),
    LlamaCppLibraryResolution.path => DynamicLibrary.open(
      descriptor.path ??
          (throw StateError('Library descriptor is missing a path.')),
    ),
    LlamaCppLibraryResolution.lookupName => DynamicLibrary.open(
      descriptor.lookupName ??
          (throw StateError('Library descriptor is missing a lookup name.')),
    ),
  };
}
