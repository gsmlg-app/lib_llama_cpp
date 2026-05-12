# lib_llama_cpp

App-facing Flutter plugin facade for direct llama.cpp inference.

This package exposes an OpenAI-shaped local client facade backed by a lower-level
command stream API. It is the package Flutter applications should depend on
directly.

## Import

Use the facade API from Flutter app code:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
```

Only import the platform interface directly when you need test injection or
custom native library resolution:

```dart
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
```

## Quick Start

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

Streaming uses typed response events with OpenAI-style event names:

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

Chat-style callers can use the compatibility adapter:

```dart
final completion = await client.chat.completions.create(
  model: 'local',
  messages: [
    const LlamaChatMessage(role: 'user', content: 'Write one sentence.'),
  ],
  maxTokens: 16,
);

print(completion.choices.first.message.content);
```

## Multimodal Input

Image and audio inputs use llama.cpp `mtmd` and require a matching multimodal
projector file:

```dart
final client = LlamaOpenAIClient(
  models: {
    'vision': const LlamaModelConfig(
      modelPath: '/path/to/model.gguf',
      mmprojPath: '/path/to/mmproj.gguf',
    ),
  },
);

final response = await client.responses.create(
  model: 'vision',
  input: [
    const LlamaResponseInputItem(
      role: 'user',
      content: [
        LlamaTextPart('Describe this image.'),
        LlamaImageFilePart(path: '/path/to/image.png'),
      ],
    ),
  ],
);
```

Byte parts accept encoded media bytes, such as PNG/JPEG/WAV/MP3/FLAC file
bytes. Raw pixels and raw audio samples are not part of the v1 Dart API. Remote
media URLs and first-class video decoding are not supported; apps can represent
video by extracting frames and sending multiple image parts.

## Tool Calling

Tool calling is model-generated only. The package streams structured tool-call
events and returns `requires_action`; apps execute tools externally and send a
follow-up request with tool result messages.

```dart
final events = client.responses.stream(
  model: 'local',
  input: 'Use search when needed.',
  tools: const [
    LlamaTool(
      name: 'search',
      description: 'Search local app data.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
  ],
);

await for (final event in events) {
  if (event case LlamaResponseToolCallDone(:final toolCall)) {
    // Execute the tool in the app, then send a follow-up request with a
    // LlamaChatMessage(role: 'tool', content: result, toolCallId: toolCall.id).
  }
}
```

## Advanced Lifecycle API

Use `LibLlamaCpp.transform(...)` directly when you need command-level lifecycle
control or focused tests around model loading, generation, and disposal.

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final client = const LibLlamaCpp();
final commands = Stream<LlamaCommand>.fromIterable([
  const LlamaLoadModelCommand(modelPath: '/path/to/model.gguf'),
  const LlamaGenerateCommand(prompt: 'Write one sentence.', maxTokens: 16),
  const LlamaDisposeCommand(),
]);

await for (final response in client.transform(commands)) {
  print(response);
}
```

## Public API

The facade exports these public types:

- `LlamaOpenAIClient`, `LlamaModelConfig`, `LlamaOpenAIException`
- `LlamaResponseObject`, `LlamaResponseInputItem`,
  `LlamaResponseStreamEvent`, `LlamaResponseOutputTextDelta`,
  `LlamaResponseFailed`
- `LlamaChatMessage`, `LlamaChatCompletion`
- `LlamaEngine`, `LibLlamaCpp`
- `LlamaCommand`, `LlamaLoadModelCommand`, `LlamaGenerateCommand`,
  `LlamaDisposeCommand`
- `LlamaResponse`, `LlamaReadyResponse`, `LlamaStateChangedResponse`,
  `LlamaTokenResponse`, `LlamaErrorResponse`, `LlamaDoneResponse`
- `LlamaState`

### `LibLlamaCpp`

```dart
const LibLlamaCpp({LibLlamaCppPlatform? platform});

Stream<LlamaResponse> transform(
  Stream<LlamaCommand> commands, {
  LlamaState initialState = const LlamaState.empty(),
  LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
});
```

`transform` resolves the platform native library, starts the inference isolate,
emits `LlamaReadyResponse`, then dispatches each command from the input stream.
When it receives `LlamaDisposeCommand`, it emits the disposal responses and
stops reading additional commands.

`LlamaEngine` is the injectable stream interface used by `LlamaOpenAIClient`.
Tests can provide a fake engine that emits `LlamaTokenResponse` values without a
real model.

The optional `platform` constructor argument and `libraryRequest` parameter use
types from `package:lib_llama_cpp_platform_interface`. Normal Flutter apps can
omit both and rely on federated plugin registration.

### Commands

| Command | Fields | Current behavior |
| --- | --- | --- |
| `LlamaLoadModelCommand` | `modelPath`, `contextSize`, `gpuLayerCount`, `mmprojPath`, `mmprojUseGpu`, `imageMinTokens`, `imageMaxTokens` | Loads the app-supplied GGUF model path and optional multimodal projector, then emits `LlamaStateChangedResponse` when the runtime state changes. |
| `LlamaGenerateCommand` | `prompt`, `maxTokens`, `temperature`, `topP`, `stop` | Requires a loaded model. Successful generation emits `LlamaTokenResponse` values; runtime failures emit `LlamaErrorResponse`. |
| `LlamaGenerateMessagesCommand` | `messages`, `tools`, `toolChoice`, `parallelToolCalls`, sampling fields | Applies the model chat template, evaluates typed media parts when present, and emits text or `LlamaToolCallResponse` values. |
| `LlamaDisposeCommand` | none | Resets state to `LlamaState.empty()`, emits `LlamaStateChangedResponse`, then emits `LlamaDoneResponse`. |

### Responses

| Response | Payload |
| --- | --- |
| `LlamaReadyResponse` | `library`, the resolved `LlamaCppLibraryDescriptor` |
| `LlamaStateChangedResponse` | `state`, the current `LlamaState` |
| `LlamaTokenResponse` | `text` and zero-based `index` for token streaming |
| `LlamaToolCallResponse` | structured tool call data emitted by message generation |
| `LlamaErrorResponse` | `message` |
| `LlamaDoneResponse` | none |

### State

`LlamaState` tracks the app-facing inference lifecycle:

```dart
const LlamaState({
  String? modelPath,
  bool isModelLoaded = false,
  LlamaModelCapabilities capabilities = const LlamaModelCapabilities(),
});
const LlamaState.empty();
```

It also provides `copyWith({String? modelPath, bool? isModelLoaded,
LlamaModelCapabilities? capabilities})`.

## Library Resolution

Default Flutter plugin registration chooses the platform resolver. For tests,
custom packaging, or local smoke runs, pass a `LlamaCppLibraryRequest`:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

final responses = const LibLlamaCpp().transform(
  commands,
  libraryRequest: const LlamaCppLibraryRequest(
    preferredPath: '/custom/path/to/libllama.so',
    requiredCapabilities: {LlamaCppLibraryCapability.cpu},
  ),
);
```

Current platform defaults:

| Platform | Resolution | Capabilities |
| --- | --- | --- |
| Android | lookup name `liblib_llama_cpp_android.so` | `cpu` |
| iOS | path `lib_llama_cpp_ios.framework/lib_llama_cpp_ios` | `cpu` |
| Linux | lookup name `liblib_llama_cpp_linux.so` | `cpu` |
| macOS | path `lib_llama_cpp_macos.framework/lib_llama_cpp_macos` | `cpu` |
| Windows | lookup name `lib_llama_cpp_windows.dll` | `cpu` |

`preferredPath` is honored by the current platform resolvers. The
`requiredCapabilities` set is carried in the request API, but the current
resolvers return their platform descriptor rather than rejecting unsupported
capability requests.

## Model Files and Smoke Tests

This package does not download or install models at runtime. Apps and CI
runners are responsible for choosing, downloading, verifying, and storing GGUF
model files, then passing an app-accessible absolute path through
`LlamaModelConfig.modelPath` or `LlamaLoadModelCommand.modelPath`.

The example integration smoke is opt-in and runs only when a model path is
provided. Passing an `mmproj` path enables the multimodal and tool-use cases:

```sh
cd example
flutter test \
  --dart-define=LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
  --dart-define=LIB_LLAMA_CPP_TEST_MMPROJ=/absolute/path/to/mmproj.gguf \
  integration_test/mobile_smoke_test.dart -d <device-id>
```

For non-Flutter Dart test entrypoints, `LIB_LLAMA_CPP_TEST_MODEL` can also be
provided through the process environment, along with
`LIB_LLAMA_CPP_TEST_LIBRARY` and `LIB_LLAMA_CPP_TEST_MMPROJ` for native e2e
tests. CI should keep model download and checksum verification in the runner
before invoking package or example tests.
