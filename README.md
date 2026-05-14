# lib_llama_cpp

Federated Flutter FFI plugin workspace for direct llama.cpp inference from
Dart and Flutter.

The repository is intentionally split into narrow packages:

- `packages/lib_llama_cpp` is the app-facing facade and isolate scheduler.
- `packages/lib_llama_cpp_platform_interface` defines the federated contract.
- `packages/lib_llama_cpp_ffi` owns generated Dart FFI bindings and opaque
  native handle wrappers.
- `packages/lib_llama_cpp_android`, `packages/lib_llama_cpp_ios`,
  `packages/lib_llama_cpp_macos`, `packages/lib_llama_cpp_linux`, and
  `packages/lib_llama_cpp_windows` isolate native build integration.
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
