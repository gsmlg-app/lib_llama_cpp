# lib_llama_cpp

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp.svg)](https://pub.dev/packages/lib_llama_cpp)

Federated Flutter FFI plugin workspace for direct llama.cpp inference from
Dart and Flutter.

## Packages

The repository is intentionally split into narrow packages. Flutter apps should
usually depend on `lib_llama_cpp`; the other packages are consumed transitively
or by advanced integrations.

| Package | Pub | Purpose |
| --- | --- | --- |
| [`lib_llama_cpp`](packages/lib_llama_cpp) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp.svg)](https://pub.dev/packages/lib_llama_cpp) | App-facing facade and inference isolate scheduler. |
| [`lib_llama_cpp_platform_interface`](packages/lib_llama_cpp_platform_interface) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_platform_interface.svg)](https://pub.dev/packages/lib_llama_cpp_platform_interface) | Federated platform contract and native library resolution API. |
| [`lib_llama_cpp_ffi`](packages/lib_llama_cpp_ffi) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_ffi.svg)](https://pub.dev/packages/lib_llama_cpp_ffi) | Generated Dart FFI bindings and opaque native handle wrappers. |
| [`lib_llama_cpp_server`](packages/lib_llama_cpp_server) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_server.svg)](https://pub.dev/packages/lib_llama_cpp_server) | Local OpenAI-compatible HTTP server for GGUF model inference. |
| [`lib_llama_cpp_android`](packages/lib_llama_cpp_android) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_android.svg)](https://pub.dev/packages/lib_llama_cpp_android) | Android registration, native build integration, and packaged binaries. |
| [`lib_llama_cpp_ios`](packages/lib_llama_cpp_ios) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_ios.svg)](https://pub.dev/packages/lib_llama_cpp_ios) | iOS registration, CocoaPods metadata, and packaged binaries. |
| [`lib_llama_cpp_macos`](packages/lib_llama_cpp_macos) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_macos.svg)](https://pub.dev/packages/lib_llama_cpp_macos) | macOS registration, CocoaPods metadata, and packaged binaries. |
| [`lib_llama_cpp_linux`](packages/lib_llama_cpp_linux) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_linux.svg)](https://pub.dev/packages/lib_llama_cpp_linux) | Linux registration, CMake metadata, and packaged binaries. |
| [`lib_llama_cpp_windows`](packages/lib_llama_cpp_windows) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp_windows.svg)](https://pub.dev/packages/lib_llama_cpp_windows) | Windows registration, CMake metadata, and packaged binaries. |

- `third_party/llama.cpp` is a pinned git submodule.
- `example` is the Flutter integration app.

Published Apple platform packages ship CPU and Metal native binaries; other
published platform packages currently ship CPU binaries. Local monorepo builds
fall back to compiling the pinned `third_party/llama.cpp` checkout when those
prebuilts are not present. The supported GPU backend direction is documented in
[`docs/design/gpu-backend-support.md`](docs/design/gpu-backend-support.md):
Metal for Apple platforms, Vulkan for Android/Linux/Windows, and CUDA out of
scope for the default federated packages.

## Current App-Facing API

Flutter apps should import the facade package:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
```

Flutter apps should start with `LlamaOpenAIClient` and use
`client.responses.create(...)` or `client.chat.completions.create(...)`:

```dart
final client = LlamaOpenAIClient(
  models: {
    'local': const LlamaModelConfig(modelPath: '/path/to/model.gguf'),
  },
);

final response = await client.responses.create(
  model: 'local',
  input: 'Write one sentence.',
);
```

The lower-level `LibLlamaCpp.transform(...)` command stream remains available
for lifecycle control and engine tests.

Model files are always supplied by the host app or CI runner. The package
accepts app-accessible GGUF paths for plugin-backed loading and generation, but
does not download, cache, or verify models at runtime.

See `packages/lib_llama_cpp/README.md` for constructor signatures, request and
response payloads, platform library resolution, and current behavior details.

## Development

On macOS, use the system Flutter/Dart toolchain and system packages. On NixOS,
enter the project shell with `devenv shell`; `.envrc` only enables devenv on
NixOS.

```sh
dart pub get
melos bootstrap
melos run analyze
melos run test
```

Opt-in real-model smoke tests require a pre-existing GGUF file:

```sh
cd example
flutter test \
  --dart-define=LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
  integration_test/mobile_smoke_test.dart -d <device-id>
```

CI workflows that run this smoke download and verify the model in the runner
before passing the path to Flutter with `--dart-define`.

Regenerate FFI bindings after changing the pinned llama.cpp header:

```sh
melos run ffigen
```

## Design Constraints

- Flutter UI isolates must not call blocking llama.cpp APIs directly.
- Native state is represented as opaque Dart references.
- Cross-language native allocations must be tied to `NativeFinalizer`.
- Platform packages own native build side effects; pure Dart packages do not.
