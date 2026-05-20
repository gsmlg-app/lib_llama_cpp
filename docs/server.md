# Local llama server

`lib_llama_cpp_server` runs a single local GGUF model behind a minimal
OpenAI-compatible HTTP API. It uses the repo-owned `llcs_engine` ABI, which
wraps llama.cpp `server_context` in process. It does not start the upstream C++
HTTP server and does not expose tools, filesystem access, or agent behavior.

## Build or locate the native library

Use a `lib_llama_cpp` dynamic library built for the current platform. For
Linux examples this is usually a `.so` such as:

```sh
/absolute/path/to/liblib_llama_cpp_linux.so
```

If `--library` is omitted, the server uses the platform default dynamic-library
lookup path from `lib_llama_cpp_ffi`. Passing an explicit `--library` is
recommended while developing.

## Run

```sh
dart run lib_llama_cpp_server \
  --library /absolute/path/to/liblib_llama_cpp_linux.so \
  --model local \
  --model-path /models/model.gguf \
  --ctx-size 32768 \
  --gpu-layers 99 \
  --parallel 4 \
  --host 127.0.0.1 \
  --port 8080
```

The model path must be a local file. Remote model URLs are not accepted in the
v1 CLI.

## Endpoints

| Endpoint | Status |
| --- | --- |
| `GET /healthz` | implemented |
| `GET /v1/models` | implemented |
| `POST /v1/chat/completions` | implemented |
| `POST /v1/chat/completions` with `stream: true` | implemented |
| `POST /v1/responses` | not implemented |
| embeddings/reranking | not implemented |
| vision/audio content | rejected until server-mode `mtmd` is complete |

## Curl

```sh
curl http://127.0.0.1:8080/healthz
```

```sh
curl http://127.0.0.1:8080/v1/models
```

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Write one sentence."}],
    "max_tokens": 64
  }'
```

Streaming:

```sh
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Write one sentence."}],
    "stream": true,
    "max_tokens": 64
  }'
```

## Dart client

```dart
import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';

Future<void> main() async {
  final client = LlamaServerClient(
    baseUri: Uri.parse('http://127.0.0.1:8080/v1'),
  );

  final response = await client.createChatCompletion(
    model: 'local',
    messages: [
      {'role': 'user', 'content': 'Write one sentence.'},
    ],
    maxTokens: 64,
  );

  print(response);
}
```

Streaming:

```dart
await for (final event in client.streamChatCompletion(
  model: 'local',
  messages: [
    {'role': 'user', 'content': 'Count from one to five.'},
  ],
  maxTokens: 64,
)) {
  print(event);
}
```

## Native integration tests

Native tests are opt-in and require both environment variables:

```sh
LIB_LLAMA_CPP_TEST_LIBRARY=/absolute/path/to/liblib_llama_cpp_linux.so \
LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
dart test -p vm packages/lib_llama_cpp_server/test/native_server_e2e_test.dart
```

Without those variables, the native server tests are skipped.

## Troubleshooting

- If the server fails to start with a dynamic-library error, pass `--library`
  with an absolute path to the platform library.
- If model loading fails, verify the `--model-path` file exists and matches the
  library/backend build.
- If requests containing images or audio fail with
  `unsupported_model_capability`, that is expected for v1 server mode. The
  `mtmd` server path is intentionally disabled until it is complete and tested.
- Full prompts, headers, and API keys are not logged by default.
