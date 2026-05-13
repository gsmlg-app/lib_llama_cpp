---
name: lib-llama-cpp
description: Use when integrating, modifying, testing, or explaining the lib_llama_cpp Flutter plugin workspace in this repository. Covers the app-facing Dart API, OpenAI-style local client, command/response stream contract, native llama.cpp runtime, model loading and disposal flow, platform library resolution, GPU backend support for Metal/CUDA/Vulkan, and repo-specific verification workflow.
---

# lib_llama_cpp

## Overview

Use this skill when a task touches the `lib_llama_cpp` federated Flutter plugin workspace. Prefer the app-facing `package:lib_llama_cpp/lib_llama_cpp.dart` facade unless the task explicitly asks for platform internals, native build metadata, or low-level FFI bindings.

Before reading source in this repo, read `graphify-out/GRAPH_REPORT.md`. If code edits touch a function, class, or method, run GitNexus impact analysis for that symbol before editing and run GitNexus change detection before committing.

## Usage Pattern

For direct lifecycle control, drive inference as a command stream and consume responses as a response stream:

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
2. Send one or more `LlamaGenerateCommand` or `LlamaGenerateMessagesCommand` values after the model is loaded.
3. Send `LlamaDisposeCommand` to release state and end the stream.

For OpenAI-shaped app code, use `LlamaOpenAIClient` with `LlamaModelConfig` instead of manually constructing lifecycle commands.

## Public API

- `LibLlamaCpp().transform(commands, initialState, libraryRequest)` resolves the platform native library, starts the inference isolate, emits `LlamaReadyResponse`, then dispatches each command.
- `LlamaOpenAIClient` exposes Responses-style and Chat Completions-style local facades over the same engine.
- `LlamaModelConfig` carries `modelPath`, optional `contextSize`, `gpuLayerCount`, `mmprojPath`, `mmprojUseGpu`, and image token bounds.
- `LlamaLoadModelCommand` carries `modelPath`, optional `contextSize`, optional `gpuLayerCount`, and optional multimodal projector options.
- `LlamaGenerateCommand` carries `prompt`, optional `maxTokens`, `temperature`, `topP`, and `stop`; omitted token limits use the remaining model context window.
- `LlamaGenerateMessagesCommand` applies the model chat template and supports typed multimodal content and tool definitions.
- `LlamaDisposeCommand` resets state and should be the final command in normal app flows.
- `LlamaState` tracks `modelPath`, `isModelLoaded`, and model capabilities.
- `LlamaResponse` variants include ready/state/token/error/done responses plus tool-call responses.

## Native Runtime

The Dart runtime path is implemented. `NativeLlamaRuntime` initializes llama.cpp, loads GGUF models with `llama_model_load_from_file`, applies `gpuLayerCount` to `llama_model_params.n_gpu_layers`, creates a context, tokenizes, decodes, samples, and streams token responses. Do not describe generation as scaffolded or stubbed in this branch.

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

- Android: lookup name `liblib_llama_cpp_android.so`, capabilities `cpu`.
- iOS: framework path `lib_llama_cpp_ios.framework/lib_llama_cpp_ios`, capabilities `cpu`, `metal`.
- macOS: framework path `lib_llama_cpp_macos.framework/lib_llama_cpp_macos`, capabilities `cpu`, `metal`.
- Linux: lookup name `liblib_llama_cpp_linux.so`, capabilities `cpu`.
- Windows: lookup name `lib_llama_cpp_windows.dll`, capabilities `cpu`.

Bundled libraries reject unsupported `requiredCapabilities`. When `preferredPath` is set, the descriptor reports `cpu` plus the requested capabilities so apps can route to caller-provided GPU builds.

## GPU Backend Builds

Native source/prebuilt builds use `packages/cmake/lib_llama_cpp_cpu_backend.cmake`:

- Apple builds enable Metal by default and embed the Metal source library.
- Linux and Windows builds can opt into CUDA with `LIB_LLAMA_CPP_ENABLE_CUDA=ON` when CUDA Toolkit is available.
- Linux, Windows, and Android builds can opt into Vulkan with `LIB_LLAMA_CPP_ENABLE_VULKAN=ON` when the Vulkan SDK and `glslc` are available.
- Use `LIB_LLAMA_CPP_CMAKE_ARGS` for extra CMake arguments in native prebuilt scripts.
- Do not hand-edit generated FFI bindings; update headers or `ffigen.yaml` and regenerate when bindings are actually missing.

## Testing Guidance

For unit tests, inject a fake platform instead of loading a real dynamic library. Platform resolver tests live under each federated package. OpenAI/client command mapping tests live in `packages/lib_llama_cpp/test`.

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

Use scoped verification:

- Run `dart analyze .` or `flutter analyze` from the touched package.
- Run package-local tests from the package directory.
- Run `ruby -c` for changed podspecs.
- Run `bash -n` for changed shell scripts and extracted podspec prepare commands when applicable.
- Run native CMake configure/build checks when `cmake` and the required SDKs are installed; otherwise report the missing tool explicitly.
- Run `graphify update .` after code changes.

## App Integration Notes

- Keep model files outside the package source path assumptions; pass real runtime paths from app storage, bundled assets copied to disk, or downloaded model locations.
- Do not call low-level `lib_llama_cpp_ffi` APIs from app UI code unless the task explicitly requires native binding work.
- Treat native handles and finalizers as infrastructure details owned by the FFI layer.
- Avoid adding blocking llama.cpp calls to Flutter UI code; the facade is intended to route lifecycle and inference work through an isolate.
