# OpenAI-Shaped Client API Design

## Context

`lib_llama_cpp` currently exposes an app-facing command stream:

```dart
final client = const LibLlamaCpp();
final responses = client.transform(commands);
```

That API is useful as a lifecycle engine, but it is not shaped like the current
OpenAI clients. The official OpenAI client pattern is resource based:

```dart
client.responses.create(...)
client.chat.completions.create(...)
```

Official OpenAI docs used for this design:

- Responses API reference: https://developers.openai.com/api/reference/resources/responses/methods/create
- Streaming Responses guide: https://developers.openai.com/api/docs/guides/streaming-responses
- Chat Completions API reference: https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
- SDKs and CLI overview: https://developers.openai.com/api/docs/libraries
- Responses migration guide: https://developers.openai.com/api/docs/guides/migrate-to-responses

## Goal

Add a high-level Dart facade that lets app code use an OpenAI-shaped local
client for llama.cpp text generation while preserving the current
`LibLlamaCpp.transform(...)` command stream as the lower-level engine API.

## Non-Goals

- Do not remove or rename the current command stream API.
- Do not claim support for hosted-only OpenAI behavior such as remote
  conversations, hosted file inputs, hosted vector stores, background jobs, or
  stored responses.
- Do not add tool calling, images, audio, embeddings, moderation, or file APIs
  in this iteration.
- Do not silently accept unsupported OpenAI request fields.

## Recommended API

The new high-level client is `LlamaOpenAIClient`.

```dart
final client = LlamaOpenAIClient(
  models: {
    'local': LlamaModelConfig(modelPath: '/models/model.gguf'),
  },
);

final response = await client.responses.create(
  model: 'local',
  input: 'Write one sentence.',
  maxOutputTokens: 64,
);

print(response.outputText);
```

Use a typed streaming method instead of making one method return different
types based on a `stream` boolean:

```dart
await for (final event in client.responses.stream(
  model: 'local',
  input: 'Write one sentence.',
)) {
  if (event case LlamaResponseOutputTextDelta(:final delta)) {
    stdout.write(delta);
  }
}
```

Support a compatibility adapter for chat-style callers:

```dart
final completion = await client.chat.completions.create(
  model: 'local',
  messages: [
    const LlamaChatMessage(role: 'user', content: 'Write one sentence.'),
  ],
);

print(completion.choices.first.message.content);
```

## Model Resolution

OpenAI APIs use `model` as a string identifier. Local llama.cpp needs a model
path and loading options. The client should bridge this with an explicit model
registry:

```dart
final client = LlamaOpenAIClient(
  models: {
    'local': LlamaModelConfig(
      modelPath: '/models/model.gguf',
      contextSize: 4096,
      gpuLayerCount: 0,
    ),
  },
);
```

If a request references an unknown model string, fail before loading the native
library with `LlamaOpenAIException(code: 'model_not_found', ...)`.

## Responses Resource

`client.responses.create(...)` should be the primary public API.

Supported request fields for the first iteration:

- `model`
- `input`
- `instructions`
- `maxOutputTokens`
- `temperature`
- `topP`
- `stop`
- `metadata`
- `store`

Accepted input forms:

- `String`
- `List<LlamaResponseInputItem>`

The initial implementation can map input items into a single prompt string. It
must preserve the API boundary so richer input item handling can be added later.

Response shape:

```dart
final class LlamaResponseObject {
  const LlamaResponseObject({
    required this.id,
    required this.createdAt,
    required this.model,
    required this.status,
    required this.output,
    required this.outputText,
    this.error,
    this.metadata = const {},
    this.usage,
  });
}
```

The response should expose `outputText` as the primary convenience field, like
the official SDK examples.

## Streaming

`client.responses.stream(...)` returns `Stream<LlamaResponseStreamEvent>`.

Initial event set:

- `LlamaResponseCreated`
- `LlamaResponseOutputTextDelta`
- `LlamaResponseOutputTextDone`
- `LlamaResponseCompleted`
- `LlamaResponseFailed`

Each event should expose a `type` string with OpenAI-style event names:

- `response.created`
- `response.output_text.delta`
- `response.output_text.done`
- `response.completed`
- `response.failed`

## Chat Compatibility

`client.chat.completions.create(...)` is a compatibility adapter over
`responses.create(...)`.

Supported request fields:

- `model`
- `messages`
- `maxTokens`
- `temperature`
- `topP`
- `stop`

Unsupported fields such as tools, function calling, multimodal content, and
response formats should fail explicitly. The adapter should convert messages to
a local prompt using simple role-prefixed text until llama.cpp chat template
support is wired into the generation path.

## Unsupported Fields

Unsupported OpenAI fields should throw `LlamaOpenAIException` with:

- `code`
- `message`
- `param`
- `type`

Use stable codes such as:

- `unsupported_parameter`
- `model_not_found`
- `generation_failed`

This keeps failures visible and prevents callers from thinking local llama.cpp
supports hosted OpenAI features that are not available.

## Existing API Compatibility

Keep these exports working:

- `LibLlamaCpp`
- `LlamaCommand`
- `LlamaLoadModelCommand`
- `LlamaGenerateCommand`
- `LlamaDisposeCommand`
- `LlamaResponse`
- `LlamaState`

The OpenAI-shaped client should call the existing command stream API internally.
The command stream remains useful for low-level lifecycle tests and advanced
callers.

## Plugin-Backed Generation Target

The OpenAI-shaped facade should be tested around request mapping, response
shape, errors, event ordering, and successful token output. Unit tests can use a
fake `LlamaEngine` to emit `LlamaTokenResponse` values, while opt-in smoke tests
use a real app-supplied GGUF path to exercise plugin-backed inference.

`responses.create(...)` should join token responses into `outputText`.
`responses.stream(...)` should emit token deltas, text done, and completed
events. Runtime failures should still map lower-level `LlamaErrorResponse`
values to `generation_failed`.

## Testing Strategy

Add focused tests under `packages/lib_llama_cpp/test/`:

- model registry resolves `model` strings to local paths
- unknown model fails before native library resolution
- `responses.create` maps string input to load/generate/dispose commands
- `responses.create` maps fake token output to completed OpenAI-shaped output
- `responses.create` maps lower-level generation errors to OpenAI-shaped errors
- `responses.stream` emits created, token deltas, text done, and completed
- chat completions adapter maps messages to Responses input
- unsupported fields fail with `unsupported_parameter`
- existing `LibLlamaCpp.transform(...)` tests continue to pass
- mobile smoke runs only when `LIB_LLAMA_CPP_TEST_MODEL` is supplied by
  dart-define or the test environment

Run scoped verification:

```sh
flutter test packages/lib_llama_cpp
```

## Documentation Strategy

Update the README so the OpenAI-shaped API is the first app-facing example.
Move the command stream API into an advanced lifecycle section.

The docs must state that successful native text generation is still blocked
until the inference worker is wired to llama.cpp.
