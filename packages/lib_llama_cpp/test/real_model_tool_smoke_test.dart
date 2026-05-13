import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:test/test.dart';

const _modelName = 'real-model-tool-smoke';

String _env(String name) => Platform.environment[name] ?? '';

void main() {
  final libraryPath = _env('LIB_LLAMA_CPP_TEST_LIBRARY');
  final modelPath = _env('LIB_LLAMA_CPP_TEST_MODEL');
  final gpuLayerCount = int.tryParse(_env('LIB_LLAMA_CPP_TEST_GPU_LAYERS'));
  final hasRuntime = libraryPath.isNotEmpty && modelPath.isNotEmpty;

  late final LlamaOpenAIClient client;

  setUpAll(() {
    if (!hasRuntime) {
      return;
    }

    client = LlamaOpenAIClient(
      models: {
        _modelName: LlamaModelConfig(
          modelPath: modelPath,
          contextSize: 1024,
          gpuLayerCount: gpuLayerCount,
        ),
      },
      engine: LibLlamaCpp(platform: _FixedLibraryPlatform(libraryPath)),
    );
  });

  test(
    'streams a forced structured tool call',
    () async {
      final events = await client.responses
          .stream(
            model: _modelName,
            input:
                'Use the lookup_weather tool for Paris. Do not answer directly.',
            maxOutputTokens: 48,
            temperature: 0,
            tools: const [
              LlamaTool(
                name: 'lookup_weather',
                description: 'Look up current weather for a city.',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'city': {'type': 'string', 'description': 'City name.'},
                  },
                  'required': ['city'],
                },
              ),
            ],
            toolChoice: const LlamaToolChoice.tool('lookup_weather'),
          )
          .timeout(const Duration(minutes: 4))
          .toList();

      expect(events.first, isA<LlamaResponseCreated>());
      expect(events.whereType<LlamaResponseFailed>(), isEmpty);
      final toolCall = events
          .whereType<LlamaResponseToolCallDone>()
          .single
          .toolCall;
      expect(toolCall.name, 'lookup_weather');
      expect(jsonDecode(toolCall.arguments), containsPair('city', 'Paris'));
      expect(events.last, isA<LlamaResponseRequiresAction>());
    },
    skip: !hasRuntime,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

final class _FixedLibraryPlatform extends LibLlamaCppPlatform {
  _FixedLibraryPlatform(this.path);

  final String path;

  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    return LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: path,
      capabilities: const {LlamaCppLibraryCapability.cpu},
    );
  }
}
