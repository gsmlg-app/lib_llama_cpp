# lib_llama_cpp

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp.svg)](https://pub.dev/packages/lib_llama_cpp)

Federated Flutter FFI plugin workspace for direct llama.cpp inference from
Dart and Flutter.

## Packages

The repository is intentionally split into narrow packages. Flutter apps should
usually depend on `lib_llama_cpp`; the facade exports the local HTTP server API
from `lib_llama_cpp_server`, and the platform packages are consumed
transitively or by advanced integrations.

| Package | Pub | Purpose |
| --- | --- | --- |
| [`lib_llama_cpp`](packages/lib_llama_cpp) | [![pub package](https://img.shields.io/pub/v/lib_llama_cpp.svg)](https://pub.dev/packages/lib_llama_cpp) | App-facing facade, recommended local server export, and inference isolate scheduler. |
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

Published pub.dev platform packages ship CPU native binaries only. Metal,
Vulkan, and CUDA prebuilts are built as separate GitHub release assets so the
pub packages stay small and deterministic. Local monorepo builds fall back to
compiling the pinned `third_party/llama.cpp` checkout when CPU prebuilts are not
present. Optional accelerator archives can be downloaded from the matching
GitHub release directly or, from a repository checkout, with
`.github/scripts/download-release-prebuilts.sh`.

## Current App-Facing API

Flutter apps should import the facade package:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
```

For production local-model use, start the OpenAI-compatible local server and
talk to it through HTTP. The server keeps the model loaded in process, isolates
the native runtime behind a small API boundary, and is exported by the facade
package:

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final server = LlamaHttpServer.open(
  config: LlamaServerConfig(
    model: 'local',
    modelPath: '/path/to/model.gguf',
    port: 0,
  ),
);
final address = await server.start();

final client = LlamaServerClient(
  baseUri: Uri.parse('http://${address.host}:${address.port}/v1'),
);

final response = await client.createChatCompletion(
  model: 'local',
  messages: [
    {'role': 'user', 'content': 'Write one sentence.'},
  ],
);
```

The same server can be started from the CLI:

```sh
dart run lib_llama_cpp_server \
  --model local \
  --model-path /path/to/model.gguf \
  --host 127.0.0.1 \
  --port 8080
```

`LlamaOpenAIClient` remains available for direct in-process integrations and
focused tests:

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

See `packages/lib_llama_cpp/README.md` for server-mode details, constructor
signatures, request and response payloads, platform library resolution, and
current behavior details.

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
