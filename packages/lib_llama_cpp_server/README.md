# lib_llama_cpp_server

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp_server.svg)](https://pub.dev/packages/lib_llama_cpp_server)

Pure Dart local HTTP server for `lib_llama_cpp`.

This package provides a small OpenAI-compatible server around the persistent
`llcs_engine` binding. It exposes health, model listing, and chat completion
routes for local clients that want to talk to a GGUF model through HTTP while
keeping the model loaded in process.

Flutter apps should normally depend on `lib_llama_cpp`, which re-exports this
server API. Server mode is the recommended local-model integration path for
long-lived application sessions.

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final server = await LlamaHttpServer.openAsync(
  config: LlamaServerConfig(
    model: 'local',
    modelPath: '/models/model.gguf',
    port: 0,
  ),
);
final address = await server.start();

final client = LlamaServerClient(
  baseUri: Uri.parse('http://${address.host}:${address.port}/v1'),
);
```

```sh
dart run lib_llama_cpp_server \
  --library /path/to/liblib_llama_cpp_linux.so \
  --model local \
  --model-path /models/model.gguf \
  --gpu-layers 0 --backend cpu \
  --batch-size 256 --ubatch-size 128 \
  --host 127.0.0.1 \
  --port 8080
```

Supported first-pass endpoints:

- `GET /healthz`
- `GET /v1/models`
- `POST /v1/chat/completions`

Streaming chat completions are returned as OpenAI-style server-sent events.

This package is model inference only. It does not expose local filesystem,
shell, agent orchestration, or tool execution capabilities.

The asynchronous constructor owns a worker isolate for native load, submit, poll
and destroy. The legacy synchronous `open` remains compatible and needs an
application-owned worker to avoid blocking a UI/event loop. Always call
`await server.close()` for safe native cleanup.

When `--library` is omitted, Linux resolves `liblib_llama_cpp_linux.so` and Windows
resolves `lib_llama_cpp_windows.dll` using the system library search path. Bundled
pub.dev artifacts are CPU builds; explicit CUDA/Vulkan libraries must provide the
matching shim symbols and runtime dependencies. `GET /healthz` includes native
capabilities with requested/effective/unsupported settings and degradation.

Long-context options include `--ctx-size`, `--batch-size`, `--ubatch-size`,
`--threads`, `--threads-batch`, `--gpu-layers`, `--parallel`, `--flash-attn`,
`--cache-type-k`, `--cache-type-v`, `--swa-full`, `--backend` and
`--require-backend`. A required unavailable backend fails. Compact SWA/F16 KV is
the baseline; context shifting and automatic fitting are disabled.

All complete messages use the model template. Prompt plus finite output budget
must fit the effective per-slot window minus upstream's reserved position.
Overflow/invalid parameters return HTTP 400. Streaming requires actual payload
and a finish reason; native errors and cancellation are not normal completion.
Request queues are bounded and completed native results expire after 30 seconds.
See `docs/design/desktop-lifecycle-context.md` in the repository for architecture,
acceptance commands and the measured hardware matrix.
