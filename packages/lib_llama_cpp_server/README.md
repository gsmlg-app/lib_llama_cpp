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

final server = LlamaHttpServer.open(
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
