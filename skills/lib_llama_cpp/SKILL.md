---
name: lib-llama-cpp
description: Use when integrating, demonstrating, testing, or explaining the lib_llama_cpp Flutter plugin package in this repository. Covers the app-facing Dart API, command/response stream contract, model loading and disposal flow, platform library resolution, and current implementation limits for llama.cpp inference.
---

# lib_llama_cpp

## Overview

Use this skill when a task asks how to consume the `lib_llama_cpp` package from a Flutter app or how to explain its public API. Prefer the app-facing `package:lib_llama_cpp/lib_llama_cpp.dart` facade unless the task explicitly asks for platform internals or low-level FFI bindings.

## Usage Pattern

Drive inference as a command stream and consume responses as a response stream:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final client = const LibLlamaCpp();

final commands = Stream<LlamaCommand>.fromIterable([
  const LlamaLoadModelCommand(
    modelPath: '/absolute/path/to/model.gguf',
    contextSize: 2048,
    gpuLayerCount: 0,
  ),
  const LlamaGenerateCommand(
    prompt: 'Write one short sentence.',
    maxTokens: 32,
  ),
  const LlamaDisposeCommand(),
]);

await for (final response in client.transform(commands)) {
  switch (response) {
    case LlamaReadyResponse(:final library):
      // Native library resolution is ready.
      print(library);
    case LlamaStateChangedResponse(:final state):
      print('loaded=${state.isModelLoaded} model=${state.modelPath}');
    case LlamaTokenResponse(:final text):
      print(text);
    case LlamaErrorResponse(:final message):
      throw StateError(message);
    case LlamaDoneResponse():
      print('disposed');
  }
}
```

The required lifecycle is:

1. Send `LlamaLoadModelCommand` with an app-accessible GGUF path.
2. Send one or more `LlamaGenerateCommand` values after the model is loaded.
3. Send `LlamaDisposeCommand` to release state and end the stream.

## Public API

- `LibLlamaCpp().transform(commands, initialState, libraryRequest)` resolves the platform native library, starts the inference isolate, emits `LlamaReadyResponse`, then dispatches each command.
- `LlamaLoadModelCommand` carries `modelPath`, optional `contextSize`, and optional `gpuLayerCount`.
- `LlamaGenerateCommand` carries `prompt` and optional `maxTokens`.
- `LlamaDisposeCommand` resets state and should be the final command in normal app flows.
- `LlamaState` currently tracks `modelPath` and `isModelLoaded`.
- `LlamaResponse` variants are `LlamaReadyResponse`, `LlamaStateChangedResponse`, `LlamaTokenResponse`, `LlamaErrorResponse`, and `LlamaDoneResponse`.

## Library Resolution

Use the default federated plugin registration for normal Flutter apps. Override the native library path only for tests, custom packaging, or local smoke runs:

```dart
final responses = client.transform(
  commands,
  libraryRequest: const LlamaCppLibraryRequest(
    preferredPath: '/custom/path/to/libllama.so',
    requiredCapabilities: {LlamaCppLibraryCapability.cpu},
  ),
);
```

Platform defaults are resolved by the federated packages:

- Android: lookup name `liblib_llama_cpp_android.so`, capabilities `cpu`, `vulkan`.
- iOS: framework path `lib_llama_cpp_ios.framework/lib_llama_cpp_ios`, capabilities `cpu`, `metal`.
- macOS: framework path `lib_llama_cpp_macos.framework/lib_llama_cpp_macos`, capabilities `cpu`, `metal`.
- Linux: lookup name `liblib_llama_cpp_linux.so`, capabilities `cpu`, `openBlas`, `vulkan`.
- Windows: lookup name `lib_llama_cpp_windows.dll`, capabilities `cpu`, `vulkan`.

## Current Limits

Check current implementation before promising real token streaming from the Dart facade. At this repo state, `InferenceIsolate` models the actor boundary and lifecycle, but native generation is still scaffolded: generation after loading a model emits `LlamaErrorResponse(message: 'Native llama.cpp generation is not wired yet.')`.

Use the GitHub E2E workflow scripts when validating real llama.cpp binary inference outside the Dart facade:

- `.github/scripts/android-real-model-smoke.sh`
- `.github/scripts/ios-real-model-smoke.sh`
- `.github/workflows/e2e.yml`

## Testing Guidance

For unit tests, inject a fake platform instead of loading a real dynamic library:

```dart
final class FakePlatform extends LibLlamaCppPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async {
    return const LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.lookupName,
      lookupName: 'libtest_llama.so',
      capabilities: {LlamaCppLibraryCapability.cpu},
    );
  }
}

final client = LibLlamaCpp(platform: FakePlatform());
```

Prefer assertions on response order:

- first response is `LlamaReadyResponse`
- load emits `LlamaStateChangedResponse(isModelLoaded: true)`
- generation before load emits `LlamaErrorResponse`
- dispose emits `LlamaStateChangedResponse(LlamaState.empty())` then `LlamaDoneResponse`

## App Integration Notes

- Keep model files outside the package source path assumptions; pass real runtime paths from app storage, bundled assets copied to disk, or downloaded model locations.
- Do not call low-level `lib_llama_cpp_ffi` APIs from app UI code unless the task explicitly requires native binding work.
- Treat native handles and finalizers as infrastructure details owned by the FFI layer.
- Avoid adding blocking llama.cpp calls to Flutter UI code; the facade is intended to route lifecycle and inference work through an isolate.
