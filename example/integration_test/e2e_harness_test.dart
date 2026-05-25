import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final config = LlamaE2eHarnessConfig.fromEnvironment();
  final runAdvancedCases = config.hasModel && config.hasMmproj;
  late final LlamaE2eHarnessRunner runner;
  late final LlamaOpenAIClient client;

  setUpAll(() async {
    if (!config.hasModel) {
      return;
    }
    runner = LlamaE2eHarnessRunner(config);
    await runner.expectRequiredBackendSupport();
    client = await runner.createClient();
  });

  testWidgets('renders the example e2e harness app', (tester) async {
    await tester.pumpWidget(InferenceDemoApp(config: config));

    expect(find.text('lib_llama_cpp E2E'), findsOneWidget);
    expect(find.text('Run harness smoke'), findsOneWidget);
    expect(find.text('No events yet'), findsOneWidget);
  });

  testWidgets('loads the plugin and completes text input', (_) async {
    _expectSupportedPlatform();

    final response = await client.responses.create(
      model: 'example-e2e-harness',
      input: config.prompt,
      maxOutputTokens: config.maxOutputTokens,
      temperature: 0,
    );

    expect(response.status, 'completed');
  }, skip: !config.hasModel);

  testWidgets('streams text deltas', (_) async {
    _expectSupportedPlatform();

    final events = await runner
        .streamText(client)
        .timeout(const Duration(minutes: 3))
        .toList();

    expect(events.first, isA<LlamaResponseCreated>());
    expect(events.whereType<LlamaResponseFailed>(), isEmpty);
    expect(events.whereType<LlamaResponseCompleted>(), hasLength(1));
    expect(events.last, isA<LlamaResponseCompleted>());
  }, skip: !config.hasModel);

  testWidgets('cancels an active stream', (_) async {
    _expectSupportedPlatform();

    final iterator = StreamIterator(
      client.responses.stream(
        model: 'example-e2e-harness',
        input: 'Count upward from one, one number per line.',
        maxOutputTokens: 256,
        temperature: 0,
      ),
    );
    addTearDown(iterator.cancel);

    final hasFirstEvent = await iterator.moveNext().timeout(
      const Duration(minutes: 2),
    );
    expect(hasFirstEvent, isTrue);
    expect(iterator.current, isA<LlamaResponseCreated>());
    await iterator.cancel().timeout(const Duration(seconds: 10));
  }, skip: !config.hasModel);

  testWidgets('streams a required tool call', (_) async {
    _expectSupportedPlatform();

    final events = await client.responses
        .stream(
          model: 'example-e2e-harness',
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
        .timeout(const Duration(minutes: 4))
        .toList();

    final toolCall = events
        .whereType<LlamaResponseToolCallDone>()
        .single
        .toolCall;
    expect(toolCall.name, 'lookup_weather');
    expect(jsonDecode(toolCall.arguments), containsPair('city', 'Paris'));
    expect(events.whereType<LlamaResponseRequiresAction>(), hasLength(1));
    expect(events.last, isA<LlamaResponseRequiresAction>());
  }, skip: !config.hasModel);

  testWidgets('handles image input', (_) async {
    _expectSupportedPlatform();

    final response = await client.responses.create(
      model: 'example-e2e-harness',
      input: [
        LlamaResponseInputItem(
          role: 'user',
          content: [
            const LlamaTextPart('Briefly describe this image.'),
            LlamaImageBytesPart(bytes: _redPixelPng(), mimeType: 'image/png'),
          ],
        ),
      ],
      maxOutputTokens: 48,
      temperature: 0,
    );

    expect(response.status, 'completed');
  }, skip: !runAdvancedCases);

  testWidgets('handles audio input', (_) async {
    _expectSupportedPlatform();

    final response = await client.responses.create(
      model: 'example-e2e-harness',
      input: [
        LlamaResponseInputItem(
          role: 'user',
          content: [
            const LlamaTextPart('Briefly describe this audio.'),
            LlamaAudioBytesPart(bytes: _sineWaveWav(), mimeType: 'audio/wav'),
          ],
        ),
      ],
      maxOutputTokens: 48,
      temperature: 0,
    );

    expect(response.status, 'completed');
  }, skip: !runAdvancedCases);
}

void _expectSupportedPlatform() {
  expect(
    Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isWindows,
    isTrue,
  );
}

Uint8List _redPixelPng() {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l2q6qgAAAABJRU5ErkJggg==',
  );
}

Uint8List _sineWaveWav() {
  const sampleRate = 16000;
  const durationSeconds = 1;
  const samples = sampleRate * durationSeconds;
  const bytesPerSample = 2;
  const dataSize = samples * bytesPerSample;
  final bytes = ByteData(44 + dataSize);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * bytesPerSample, Endian.little);
  bytes.setUint16(32, bytesPerSample, Endian.little);
  bytes.setUint16(34, 8 * bytesPerSample, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < samples; i++) {
    final sample = (math.sin(2 * math.pi * 440 * i / sampleRate) * 32767)
        .round();
    bytes.setInt16(44 + i * bytesPerSample, sample, Endian.little);
  }

  return bytes.buffer.asUint8List();
}
