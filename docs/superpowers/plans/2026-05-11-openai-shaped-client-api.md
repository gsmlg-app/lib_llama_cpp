# OpenAI-Shaped Client API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an OpenAI-shaped local client facade for `lib_llama_cpp` with `client.responses.create(...)`, `client.responses.stream(...)`, and `client.chat.completions.create(...)`.

**Architecture:** Keep the current `LibLlamaCpp.transform(...)` command stream as the lower-level engine. Add resource-style facade classes in `packages/lib_llama_cpp/lib/src/openai/` that translate OpenAI-shaped requests into load/generate/dispose commands and map command-stream responses back into OpenAI-shaped response objects, stream events, or exceptions.

**Tech Stack:** Dart 3.11, Flutter plugin package, existing `LibLlamaCpp` command stream, `flutter_test`.

---

## File Structure

- Create `packages/lib_llama_cpp/lib/src/openai/llama_openai_client.dart`: top-level `LlamaOpenAIClient`, resource accessors, and model registry wiring.
- Create `packages/lib_llama_cpp/lib/src/openai/model_config.dart`: `LlamaModelConfig` and local model resolution.
- Create `packages/lib_llama_cpp/lib/src/openai/errors.dart`: `LlamaOpenAIException` and stable error codes.
- Create `packages/lib_llama_cpp/lib/src/openai/responses.dart`: Responses request/input/output/event models and `LlamaResponsesResource`.
- Create `packages/lib_llama_cpp/lib/src/openai/chat.dart`: chat message/completion models and chat adapter resource.
- Modify `packages/lib_llama_cpp/lib/lib_llama_cpp.dart`: export the new OpenAI-shaped API files.
- Modify `packages/lib_llama_cpp/README.md`: make the OpenAI-shaped API the primary example and keep command streams as advanced API.
- Modify `README.md`: summarize the new app-facing API at the workspace level.
- Modify `packages/lib_llama_cpp/test/lib_llama_cpp_test.dart`: keep existing low-level tests.
- Create `packages/lib_llama_cpp/test/openai_client_test.dart`: test the new facade.

## Task 1: Add OpenAI-shaped model config and errors

**Files:**
- Create: `packages/lib_llama_cpp/lib/src/openai/model_config.dart`
- Create: `packages/lib_llama_cpp/lib/src/openai/errors.dart`
- Test: `packages/lib_llama_cpp/test/openai_client_test.dart`

- [ ] **Step 1: Write failing tests for model lookup and OpenAI-shaped errors**

Add this test file:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

void main() {
  group('LlamaOpenAIClient model registry', () {
    test('unknown model fails with model_not_found', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
      );

      await expectLater(
        client.responses.create(model: 'missing', input: 'Hello'),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'model_not_found')
              .having((error) => error.param, 'param', 'model'),
        ),
      );
    });
  });
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: fail because `LlamaOpenAIClient`, `LlamaModelConfig`, and
`LlamaOpenAIException` do not exist.

- [ ] **Step 3: Add model config and exception types**

Create `packages/lib_llama_cpp/lib/src/openai/model_config.dart`:

```dart
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
```

Create `packages/lib_llama_cpp/lib/src/openai/errors.dart`:

```dart
final class LlamaOpenAIException implements Exception {
  const LlamaOpenAIException({
    required this.code,
    required this.message,
    this.param,
    this.type = 'invalid_request_error',
  });

  final String code;
  final String message;
  final String? param;
  final String type;

  @override
  String toString() {
    final parameter = param == null ? '' : ', param: $param';
    return 'LlamaOpenAIException(code: $code$parameter, message: $message)';
  }
}
```

- [ ] **Step 4: Add temporary client shell for the failing model lookup test**

Create `packages/lib_llama_cpp/lib/src/openai/llama_openai_client.dart`:

```dart
import 'errors.dart';
import 'model_config.dart';
import 'responses.dart';
import 'chat.dart';

final class LlamaOpenAIClient {
  LlamaOpenAIClient({required Map<String, LlamaModelConfig> models})
    : _models = Map.unmodifiable(models) {
    responses = LlamaResponsesResource(resolveModel: _resolveModel);
    chat = LlamaChatResource(responses: responses);
  }

  final Map<String, LlamaModelConfig> _models;
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
```

Create minimal resource shells used by the client:

```dart
// packages/lib_llama_cpp/lib/src/openai/responses.dart
import 'model_config.dart';

typedef LlamaModelResolver = LlamaModelConfig Function(String model);

final class LlamaResponsesResource {
  const LlamaResponsesResource({required LlamaModelResolver resolveModel})
    : _resolveModel = resolveModel;

  final LlamaModelResolver _resolveModel;

  Future<Object> create({required String model, required Object input}) async {
    _resolveModel(model);
    throw UnimplementedError('responses.create is implemented in Task 2.');
  }
}
```

```dart
// packages/lib_llama_cpp/lib/src/openai/chat.dart
import 'responses.dart';

final class LlamaChatResource {
  const LlamaChatResource({required LlamaResponsesResource responses})
    : _responses = responses;

  final LlamaResponsesResource _responses;
}
```

- [ ] **Step 5: Export the new API**

Modify `packages/lib_llama_cpp/lib/lib_llama_cpp.dart`:

```dart
export 'src/lib_llama_cpp.dart';
export 'src/llama_command.dart';
export 'src/llama_response.dart';
export 'src/llama_state.dart';
export 'src/openai/chat.dart';
export 'src/openai/errors.dart';
export 'src/openai/llama_openai_client.dart';
export 'src/openai/model_config.dart';
export 'src/openai/responses.dart';
```

- [ ] **Step 6: Run the focused test**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: pass. The test uses an unknown model, so `create` should throw
`model_not_found` before reaching the temporary `UnimplementedError`.

## Task 2: Implement `client.responses.create(...)`

**Files:**
- Modify: `packages/lib_llama_cpp/lib/src/openai/llama_openai_client.dart`
- Modify: `packages/lib_llama_cpp/lib/src/openai/responses.dart`
- Modify: `packages/lib_llama_cpp/test/openai_client_test.dart`

- [ ] **Step 1: Add tests for command mapping and unwired generation errors**

Append to `packages/lib_llama_cpp/test/openai_client_test.dart`:

```dart
  group('responses.create', () {
    test('returns a failed generation exception while native generation is unwired', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
        engine: const LibLlamaCpp(),
      );

      await expectLater(
        client.responses.create(
          model: 'local',
          input: 'Write one sentence.',
          maxOutputTokens: 16,
        ),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'generation_failed')
              .having(
                (error) => error.message,
                'message',
                contains('Native llama.cpp generation is not wired yet.'),
              ),
        ),
      );
    });
  });
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: fail because `engine`, response models, and `maxOutputTokens` are not
implemented.

- [ ] **Step 3: Add response request and response object models**

Replace `packages/lib_llama_cpp/lib/src/openai/responses.dart` with:

```dart
import '../lib_llama_cpp.dart';
import '../llama_command.dart';
import '../llama_response.dart';
import 'errors.dart';
import 'model_config.dart';

typedef LlamaModelResolver = LlamaModelConfig Function(String model);

final class LlamaResponseObject {
  const LlamaResponseObject({
    required this.id,
    required this.createdAt,
    required this.model,
    required this.status,
    required this.output,
    required this.outputText,
    this.error,
    this.metadata = const {},
    this.usage,
  });

  final String id;
  final DateTime createdAt;
  final String model;
  final String status;
  final List<LlamaResponseOutputItem> output;
  final String outputText;
  final LlamaOpenAIException? error;
  final Map<String, String> metadata;
  final LlamaResponseUsage? usage;
}

final class LlamaResponseOutputItem {
  const LlamaResponseOutputItem({required this.text});

  final String text;
}

final class LlamaResponseUsage {
  const LlamaResponseUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
}

final class LlamaResponsesResource {
  const LlamaResponsesResource({
    required LlamaModelResolver resolveModel,
    required LibLlamaCpp engine,
  }) : _resolveModel = resolveModel,
       _engine = engine;

  final LlamaModelResolver _resolveModel;
  final LibLlamaCpp _engine;

  Future<LlamaResponseObject> create({
    required String model,
    required Object input,
    String? instructions,
    int? maxOutputTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
    Map<String, String> metadata = const {},
    bool store = false,
  }) async {
    if (store) {
      throw const LlamaOpenAIException(
        code: 'unsupported_parameter',
        message: 'Stored responses are not supported by local llama.cpp.',
        param: 'store',
      );
    }

    final config = _resolveModel(model);
    final prompt = _promptFromInput(input, instructions: instructions);
    final output = StringBuffer();

    final commands = Stream<LlamaCommand>.fromIterable([
      LlamaLoadModelCommand(
        modelPath: config.modelPath,
        contextSize: config.contextSize,
        gpuLayerCount: config.gpuLayerCount,
      ),
      LlamaGenerateCommand(prompt: prompt, maxTokens: maxOutputTokens),
      const LlamaDisposeCommand(),
    ]);

    await for (final response in _engine.transform(commands)) {
      switch (response) {
        case LlamaTokenResponse(:final text):
          output.write(text);
        case LlamaErrorResponse(:final message):
          throw LlamaOpenAIException(
            code: 'generation_failed',
            message: message,
            type: 'server_error',
          );
        case LlamaReadyResponse() ||
            LlamaStateChangedResponse() ||
            LlamaDoneResponse():
          break;
      }
    }

    final outputText = output.toString();
    return LlamaResponseObject(
      id: 'resp_${DateTime.now().microsecondsSinceEpoch}',
      createdAt: DateTime.now().toUtc(),
      model: model,
      status: 'completed',
      output: [LlamaResponseOutputItem(text: outputText)],
      outputText: outputText,
      metadata: metadata,
      usage: LlamaResponseUsage(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
      ),
    );
  }

  String _promptFromInput(Object input, {String? instructions}) {
    final body = switch (input) {
      final String text => text,
      _ => throw const LlamaOpenAIException(
        code: 'unsupported_parameter',
        message: 'Only string input is supported in this iteration.',
        param: 'input',
      ),
    };

    if (instructions == null || instructions.isEmpty) {
      return body;
    }

    return '$instructions\n\n$body';
  }
}
```

- [ ] **Step 4: Pass the engine into the Responses resource**

Modify `packages/lib_llama_cpp/lib/src/openai/llama_openai_client.dart`:

```dart
import '../lib_llama_cpp.dart';
import 'errors.dart';
import 'model_config.dart';
import 'responses.dart';
import 'chat.dart';

final class LlamaOpenAIClient {
  LlamaOpenAIClient({
    required Map<String, LlamaModelConfig> models,
    LibLlamaCpp engine = const LibLlamaCpp(),
  }) : _models = Map.unmodifiable(models) {
    responses = LlamaResponsesResource(
      resolveModel: _resolveModel,
      engine: engine,
    );
    chat = LlamaChatResource(responses: responses);
  }

  final Map<String, LlamaModelConfig> _models;
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
```

- [ ] **Step 5: Run the focused test**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: pass. The successful generation path is not expected yet because the
current engine returns `Native llama.cpp generation is not wired yet.`

## Task 3: Implement `client.responses.stream(...)`

**Files:**
- Modify: `packages/lib_llama_cpp/lib/src/openai/responses.dart`
- Modify: `packages/lib_llama_cpp/test/openai_client_test.dart`

- [ ] **Step 1: Add streaming event-order test**

Append to `packages/lib_llama_cpp/test/openai_client_test.dart`:

```dart
    test('stream emits created then failed while native generation is unwired', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
      );

      final events = await client.responses
          .stream(model: 'local', input: 'Hello', maxOutputTokens: 4)
          .toList();

      expect(events.first.type, 'response.created');
      expect(events.last.type, 'response.failed');
      expect(
        (events.last as LlamaResponseFailed).error.message,
        contains('Native llama.cpp generation is not wired yet.'),
      );
    });
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: fail because stream events are not implemented.

- [ ] **Step 3: Add stream event classes and stream method**

Add these classes to `packages/lib_llama_cpp/lib/src/openai/responses.dart`:

```dart
sealed class LlamaResponseStreamEvent {
  const LlamaResponseStreamEvent({required this.type});

  final String type;
}

final class LlamaResponseCreated extends LlamaResponseStreamEvent {
  const LlamaResponseCreated({required this.response})
    : super(type: 'response.created');

  final LlamaResponseObject response;
}

final class LlamaResponseOutputTextDelta extends LlamaResponseStreamEvent {
  const LlamaResponseOutputTextDelta({
    required this.delta,
    required this.index,
  }) : super(type: 'response.output_text.delta');

  final String delta;
  final int index;
}

final class LlamaResponseOutputTextDone extends LlamaResponseStreamEvent {
  const LlamaResponseOutputTextDone({required this.text})
    : super(type: 'response.output_text.done');

  final String text;
}

final class LlamaResponseCompleted extends LlamaResponseStreamEvent {
  const LlamaResponseCompleted({required this.response})
    : super(type: 'response.completed');

  final LlamaResponseObject response;
}

final class LlamaResponseFailed extends LlamaResponseStreamEvent {
  const LlamaResponseFailed({required this.error})
    : super(type: 'response.failed');

  final LlamaOpenAIException error;
}
```

Add this method inside `LlamaResponsesResource`:

```dart
  Stream<LlamaResponseStreamEvent> stream({
    required String model,
    required Object input,
    String? instructions,
    int? maxOutputTokens,
    double? temperature,
    double? topP,
    List<String> stop = const [],
    Map<String, String> metadata = const {},
    bool store = false,
  }) async* {
    final created = LlamaResponseObject(
      id: 'resp_${DateTime.now().microsecondsSinceEpoch}',
      createdAt: DateTime.now().toUtc(),
      model: model,
      status: 'in_progress',
      output: const [],
      outputText: '',
      metadata: metadata,
    );
    yield LlamaResponseCreated(response: created);

    try {
      final response = await create(
        model: model,
        input: input,
        instructions: instructions,
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        stop: stop,
        metadata: metadata,
        store: store,
      );
      if (response.outputText.isNotEmpty) {
        yield LlamaResponseOutputTextDelta(
          delta: response.outputText,
          index: 0,
        );
        yield LlamaResponseOutputTextDone(text: response.outputText);
      }
      yield LlamaResponseCompleted(response: response);
    } on LlamaOpenAIException catch (error) {
      yield LlamaResponseFailed(error: error);
    }
  }
```

- [ ] **Step 4: Run the focused test**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: pass.

## Task 4: Implement chat completions compatibility

**Files:**
- Modify: `packages/lib_llama_cpp/lib/src/openai/chat.dart`
- Modify: `packages/lib_llama_cpp/test/openai_client_test.dart`

- [ ] **Step 1: Add chat adapter test**

Append to `packages/lib_llama_cpp/test/openai_client_test.dart`:

```dart
  group('chat.completions.create', () {
    test('maps chat messages through responses and preserves generation errors', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
      );

      await expectLater(
        client.chat.completions.create(
          model: 'local',
          messages: [
            const LlamaChatMessage(role: 'user', content: 'Hello'),
          ],
          maxTokens: 4,
        ),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'generation_failed'),
        ),
      );
    });
  });
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: fail because chat models and `completions` are not implemented.

- [ ] **Step 3: Replace chat resource implementation**

Replace `packages/lib_llama_cpp/lib/src/openai/chat.dart` with:

```dart
import 'responses.dart';

final class LlamaChatResource {
  LlamaChatResource({required LlamaResponsesResource responses})
    : completions = LlamaChatCompletionsResource(responses: responses);

  final LlamaChatCompletionsResource completions;
}

final class LlamaChatCompletionsResource {
  const LlamaChatCompletionsResource({required LlamaResponsesResource responses})
    : _responses = responses;

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
      id: 'chatcmpl_${DateTime.now().microsecondsSinceEpoch}',
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
```

- [ ] **Step 4: Run the focused test**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: pass.

## Task 5: Add unsupported parameter coverage

**Files:**
- Modify: `packages/lib_llama_cpp/lib/src/openai/responses.dart`
- Modify: `packages/lib_llama_cpp/test/openai_client_test.dart`

- [ ] **Step 1: Add unsupported parameter tests**

Append to `packages/lib_llama_cpp/test/openai_client_test.dart`:

```dart
    test('store true fails explicitly', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
      );

      await expectLater(
        client.responses.create(model: 'local', input: 'Hello', store: true),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'unsupported_parameter')
              .having((error) => error.param, 'param', 'store'),
        ),
      );
    });

    test('non-string input fails explicitly in the first iteration', () async {
      final client = LlamaOpenAIClient(
        models: {
          'local': const LlamaModelConfig(modelPath: '/models/local.gguf'),
        },
      );

      await expectLater(
        client.responses.create(model: 'local', input: const ['Hello']),
        throwsA(
          isA<LlamaOpenAIException>()
              .having((error) => error.code, 'code', 'unsupported_parameter')
              .having((error) => error.param, 'param', 'input'),
        ),
      );
    });
```

- [ ] **Step 2: Run the focused test**

Run:

```sh
flutter test packages/lib_llama_cpp/test/openai_client_test.dart
```

Expected: pass. These paths were implemented in Task 2.

## Task 6: Update documentation

**Files:**
- Modify: `packages/lib_llama_cpp/README.md`
- Modify: `README.md`

- [ ] **Step 1: Update package README primary example**

In `packages/lib_llama_cpp/README.md`, make this the first usage example:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final client = LlamaOpenAIClient(
  models: {
    'local': const LlamaModelConfig(modelPath: '/path/to/model.gguf'),
  },
);

final response = await client.responses.create(
  model: 'local',
  input: 'Write one sentence.',
  maxOutputTokens: 16,
);

print(response.outputText);
```

- [ ] **Step 2: Add streaming example**

Add this example near the primary usage block:

```dart
await for (final event in client.responses.stream(
  model: 'local',
  input: 'Write one sentence.',
  maxOutputTokens: 16,
)) {
  if (event case LlamaResponseOutputTextDelta(:final delta)) {
    print(delta);
  }
}
```

- [ ] **Step 3: Move current command stream docs under advanced API**

Keep the existing command stream example, but introduce it with:

```markdown
## Advanced Lifecycle API

Use `LibLlamaCpp.transform(...)` directly when you need command-level lifecycle
control or focused tests around model loading, generation, and disposal.
```

- [ ] **Step 4: State the native generation limit**

Keep this exact warning in the README:

```markdown
Native llama.cpp model loading, generation, and token streaming are still under
active development. Until the inference worker emits real token responses,
OpenAI-shaped generation calls fail with `generation_failed`.
```

- [ ] **Step 5: Update workspace README**

In `README.md`, summarize the new high-level API:

```markdown
Flutter apps should start with `LlamaOpenAIClient` and use
`client.responses.create(...)` or `client.chat.completions.create(...)`.
The lower-level `LibLlamaCpp.transform(...)` command stream remains available
for lifecycle control and engine tests.
```

## Task 7: Run scoped verification

**Files:**
- No file edits.

- [ ] **Step 1: Run package tests**

Run:

```sh
flutter test packages/lib_llama_cpp
```

Expected: all tests pass.

- [ ] **Step 2: Run analyzer for the package**

Run:

```sh
flutter analyze packages/lib_llama_cpp
```

Expected: no issues in `packages/lib_llama_cpp`.

- [ ] **Step 3: Check docs and diff**

Run:

```sh
git diff --check -- README.md packages/lib_llama_cpp/README.md packages/lib_llama_cpp/lib packages/lib_llama_cpp/test
git status --short
```

Expected: no whitespace errors. Status should show only files touched by this
plan plus any pre-existing README changes from the API documentation update.

## Execution Notes

- The implementation should not touch platform packages in this iteration.
- Keep the OpenAI-shaped API narrowly focused on local text generation.
- Preserve all existing public exports and tests for `LibLlamaCpp.transform`.
- Do not add hosted OpenAI API keys or network behavior; this is a local
  compatibility facade, not an OpenAI service client.
- Successful text output remains blocked until native llama.cpp generation is
  wired. That is a separate implementation plan.
