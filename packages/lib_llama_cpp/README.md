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
- `LibLlamaCpp`
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

The optional `platform` constructor argument and `libraryRequest` parameter use
types from `package:lib_llama_cpp_platform_interface`. Normal Flutter apps can
omit both and rely on federated plugin registration.

### Commands

| Command | Fields | Current behavior |
| --- | --- | --- |
| `LlamaLoadModelCommand` | `modelPath`, `contextSize`, `gpuLayerCount` | Marks the isolate state as loaded with `modelPath` and emits `LlamaStateChangedResponse`. The sizing fields are accepted by the API but native model loading is not wired yet. |
| `LlamaGenerateCommand` | `prompt`, `maxTokens` | Emits `LlamaErrorResponse(message: 'Cannot generate before a model is loaded.')` if no model has been loaded. After a load command, it currently emits `LlamaErrorResponse(message: 'Native llama.cpp generation is not wired yet.')`. |
| `LlamaDisposeCommand` | none | Resets state to `LlamaState.empty()`, emits `LlamaStateChangedResponse`, then emits `LlamaDoneResponse`. |

### Responses

| Response | Payload |
| --- | --- |
| `LlamaReadyResponse` | `library`, the resolved `LlamaCppLibraryDescriptor` |
| `LlamaStateChangedResponse` | `state`, the current `LlamaState` |
| `LlamaTokenResponse` | `text` and zero-based `index` for token streaming; this response is part of the public API but is not emitted by the current generation worker |
| `LlamaErrorResponse` | `message` |
| `LlamaDoneResponse` | none |

### State

`LlamaState` tracks the app-facing inference lifecycle:

```dart
const LlamaState({String? modelPath, bool isModelLoaded = false});
const LlamaState.empty();
```

It also provides `copyWith({String? modelPath, bool? isModelLoaded})`.

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
| Android | lookup name `liblib_llama_cpp_android.so` | `cpu`, `vulkan` |
| iOS | path `lib_llama_cpp_ios.framework/lib_llama_cpp_ios` | `cpu`, `metal` |
| Linux | lookup name `liblib_llama_cpp_linux.so` | `cpu`, `openBlas`, `vulkan` |
| macOS | path `lib_llama_cpp_macos.framework/lib_llama_cpp_macos` | `cpu`, `metal` |
| Windows | lookup name `lib_llama_cpp_windows.dll` | `cpu`, `vulkan` |

`preferredPath` is honored by the current platform resolvers. The
`requiredCapabilities` set is carried in the request API, but the current
resolvers return their platform descriptor rather than rejecting unsupported
capability requests.

## Current Limits

Native llama.cpp model loading, generation, and token streaming are still under
active development. Until the inference worker emits real token responses,
OpenAI-shaped generation calls fail with `generation_failed`.
