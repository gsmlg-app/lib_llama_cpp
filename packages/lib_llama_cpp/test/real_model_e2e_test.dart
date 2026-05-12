import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:test/test.dart';

const _modelName = 'gemma4-e2b';

String _env(String name) => Platform.environment[name] ?? '';

void main() {
  final libraryPath = _env('LIB_LLAMA_CPP_TEST_LIBRARY');
  final modelPath = _env('LIB_LLAMA_CPP_TEST_MODEL');
  final mmprojPath = _env('LIB_LLAMA_CPP_TEST_MMPROJ');
  final hasRuntime = libraryPath.isNotEmpty && modelPath.isNotEmpty;
  final hasMultimodalRuntime = hasRuntime && mmprojPath.isNotEmpty;

  late final LlamaOpenAIClient client;

  setUpAll(() {
    if (!hasRuntime) {
      return;
    }

    client = LlamaOpenAIClient(
      models: {
        _modelName: LlamaModelConfig(
          modelPath: modelPath,
          mmprojPath: mmprojPath.isEmpty ? null : mmprojPath,
          contextSize: 4096,
        ),
      },
      engine: LibLlamaCpp(platform: _FixedLibraryPlatform(libraryPath)),
    );
  });

  group('Gemma 4 E2B real model e2e', () {
    test('handles text input', () async {
      final response = await client.responses.create(
        model: _modelName,
        input: 'Reply with one short greeting.',
        maxOutputTokens: 24,
        temperature: 0,
      );

      expect(response.status, 'completed');
      expect(response.outputText.trim(), isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test(
      'streams text deltas and completes',
      () async {
        final events = await client.responses
            .stream(
              model: _modelName,
              input: 'Reply with one short sentence about local inference.',
              maxOutputTokens: 32,
              temperature: 0,
            )
            .toList();

        expect(events.first, isA<LlamaResponseCreated>());
        expect(events.whereType<LlamaResponseOutputTextDelta>(), isNotEmpty);
        expect(events.whereType<LlamaResponseCompleted>(), hasLength(1));
        expect(events.last, isA<LlamaResponseCompleted>());
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('cancels an active stream', () async {
      final iterator = StreamIterator(
        client.responses.stream(
          model: _modelName,
          input: 'Count upward from one, one number per line.',
          maxOutputTokens: 256,
          temperature: 0,
        ),
      );
      addTearDown(iterator.cancel);

      var sawDelta = false;
      for (var i = 0; i < 64; i += 1) {
        final hasNext = await iterator.moveNext().timeout(
          const Duration(minutes: 2),
        );
        if (!hasNext) {
          break;
        }
        final event = iterator.current;
        if (event is LlamaResponseOutputTextDelta && event.delta.isNotEmpty) {
          sawDelta = true;
          break;
        }
        if (event is LlamaResponseFailed) {
          fail('Stream failed before cancel: ${event.error.message}');
        }
      }

      expect(sawDelta, isTrue);
      await iterator.cancel().timeout(const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('streams a required tool call', () async {
      final events = await client.responses
          .stream(
            model: _modelName,
            input:
                'Use the lookup_weather tool for Paris. Do not answer directly.',
            maxOutputTokens: 96,
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
          .toList();

      final toolCall = events
          .whereType<LlamaResponseToolCallDone>()
          .single
          .toolCall;
      expect(toolCall.name, 'lookup_weather');
      expect(toolCall.arguments, contains('Paris'));
      final requiresAction = events
          .whereType<LlamaResponseRequiresAction>()
          .single;
      expect(requiresAction.response.status, 'requires_action');
      expect(events.last, isA<LlamaResponseRequiresAction>());
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
      'handles image input',
      () async {
        final response = await client.responses.create(
          model: _modelName,
          input: [
            LlamaResponseInputItem(
              role: 'user',
              content: [
                const LlamaTextPart('Briefly describe this image.'),
                LlamaImageBytesPart(
                  bytes: _redPixelPng(),
                  mimeType: 'image/png',
                ),
              ],
            ),
          ],
          maxOutputTokens: 48,
          temperature: 0,
        );

        expect(response.status, 'completed');
        expect(response.outputText.trim(), isNotEmpty);
      },
      skip: !hasMultimodalRuntime,
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'handles audio input',
      () async {
        final response = await client.responses.create(
          model: _modelName,
          input: [
            LlamaResponseInputItem(
              role: 'user',
              content: [
                const LlamaTextPart('Briefly describe this audio.'),
                LlamaAudioBytesPart(
                  bytes: _sineWaveWav(),
                  mimeType: 'audio/wav',
                ),
              ],
            ),
          ],
          maxOutputTokens: 48,
          temperature: 0,
        );

        expect(response.status, 'completed');
        expect(response.outputText.trim(), isNotEmpty);
      },
      skip: !hasMultimodalRuntime,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }, skip: !hasRuntime);
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

Uint8List _redPixelPng() {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lS0iWQAAAABJRU5ErkJggg==',
  );
}

Uint8List _sineWaveWav() {
  const sampleRate = 16000;
  const durationSeconds = 0.25;
  final samples = (sampleRate * durationSeconds).round();
  final dataBytes = samples * 2;
  final bytes = ByteData(44 + dataBytes);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i += 1) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples; i += 1) {
    final sample = math.sin(2 * math.pi * 440 * i / sampleRate);
    bytes.setInt16(44 + i * 2, (sample * 8192).round(), Endian.little);
  }

  return bytes.buffer.asUint8List();
}
