# Tool Calling via C++ Shim

## Status

Proposed. This note targets the tool-calling gap in `lib_llama_cpp`.

## Problem

The current architecture binds `packages/lib_llama_cpp_ffi` directly to the C
ABI exported by `include/llama.h`. That surface contains inference primitives:
tokenization, decoding, sampling, KV-cache management, and model/context
lifecycle.

The OpenAI-shaped facade needs behavior that lives one layer above that ABI:

- chat-template rendering with tool definitions,
- parsing model output back into `tool_calls`,
- deriving grammar constraints from tool schemas,
- and preserving model-family-specific wire formats.

Those behaviors live in llama.cpp's `common/` and `tools/server/` source trees
as C++ code. Reimplementing them in Dart would be unbounded maintenance work
because model families such as Llama 3.1, Qwen 2.5, Hermes, Functionary,
Mistral, DeepSeek, and Granite each use different tool-call formats, and the
upstream parsers change over time.

## Architectural Fix

Add a thin C++ shim that re-exports the required `common/` and server utility
functions through a stable `extern "C"` boundary. The shim is compiled into the
native binary alongside `libllama`; ffigen targets the shim header in addition
to `llama.h`.

```text
+--------------------+
| Dart facade (OAI)  |    pure Dart
+--------------------+
| ffigen bindings    |    generated from llcs.h and llama.h
+--------------------+
| llama_cpp_shim     |    extern "C" wrappers around common/ + server utils
+--------------------+
| libllama           |    unchanged upstream submodule
+--------------------+
```

The shim depends on upstream sources but does not fork them. When the pinned
llama.cpp submodule moves, the shim rebuilds against the new sources and ffigen
regenerates from the stable shim header. API drift should show up as a build
break, not as a production parser regression.

## ABI Surface

The boundary should marshal JSON strings and opaque handles only. Every returned
`char *` is allocated by the shim and freed with `llcs_string_free`.

### Prompt Rendering

```c
char * llcs_chat_render(
    const llama_model * model,
    const char * messages_json,
    const char * tools_json,
    const char * chat_template,
    bool add_generation_prompt);
```

This wraps the `common_chat_templates_apply()` family. Tool-call format is
detected from the model chat template via `common_chat_templates_init()` and can
be cached per `llama_model *`.

### Response Parsing

```c
char * llcs_chat_parse(
    const llama_model * model,
    const char * output);
```

This wraps `common_chat_parse()` and returns an OpenAI-compatible JSON object:

```json
{
  "content": "...",
  "tool_calls": [
    {
      "id": "call_0",
      "name": "get_weather",
      "arguments": "{\"location\":\"Tokyo\"}"
    }
  ]
}
```

The Dart layer should not reshape model-family parser output beyond translating
this JSON into public Dart types.

### Grammar From Tools

```c
char * llcs_grammar_from_tools(const char * tools_json);
```

This wraps llama.cpp's JSON-schema-to-grammar support. The resulting grammar is
fed into the existing sampler path, for example through
`llama_sampler_init_grammar` or the lazy grammar sampler where appropriate.

### Streaming Parser

```c
typedef struct llcs_stream_parser llcs_stream_parser;

llcs_stream_parser * llcs_stream_parser_create(const llama_model * model);

char * llcs_stream_parser_feed(
    llcs_stream_parser * parser,
    const char * token_text);

char * llcs_stream_parser_finish(llcs_stream_parser * parser);

void llcs_stream_parser_destroy(llcs_stream_parser * parser);
```

Streaming tool calls need state because OpenAI-compatible deltas can split tool
names and argument JSON across tokens. The shim should wrap the same diffing
machinery used by llama-server so Dart receives OpenAI-shaped streaming deltas
instead of model-family-specific fragments.

### Memory Ownership

```c
void llcs_string_free(char * value);
```

All shim-owned strings are freed through the paired function above. Dart should
wrap returned pointers and opaque handles with finalizers, while still
destroying long-lived handles deterministically when an engine closes.

## Federation Impact

No new package is required. The shim belongs in `packages/lib_llama_cpp_ffi` and
is compiled into the same native target as the existing wrapper.

```text
packages/lib_llama_cpp_ffi/
  src/
    shim/
      llcs.h
      llcs_chat.cpp
      llcs_grammar.cpp
      llcs_stream.cpp
    CMakeLists.txt
  ffigen.yaml
```

`melos run ffigen` remains the regeneration entrypoint. The config gains the
shim header in addition to the upstream llama.cpp headers.

## Build Integration

The shim compiles selected llama.cpp C++ sources from the pinned submodule,
including the chat-template, parser, JSON-schema grammar, minja, and nlohmann
JSON components required by the upstream common layer.

Platform notes:

- macOS and iOS append shim sources to the existing podspec source list and
  require C++17.
- Android appends shim sources to the existing CMake target and continues to
  use the existing NDK/libc++ setup.
- Linux and Windows use the same CMake additions; MSVC builds require C++17 and
  exception handling enabled.

The binary-size impact is expected to be small relative to model weights, but
the implementation PR should report the measured delta for every published
platform package.

## Drift Discipline

`common/` is not a stable ABI. The shim must make upstream drift explicit:

- The submodule commit and shim source move together.
- Wrapped upstream signatures get compile-time canaries where practical.
- Fixture tests cover `(model_family, messages, tools) -> parsed output`.

If the shim builds and the fixture suite passes after a submodule bump, the bump
is safe to land. If upstream renames or reshapes a dependency, the build should
break in the shim instead of silently changing runtime behavior.

## Dart Facade Changes

`LlamaOpenAIClient.chat.completions.create(..., tools: [...])` and
`client.responses.create(..., tools: [...])` should use the shim for real tool
semantics.

The command-stream transformer flow is:

1. Serialize messages and tools to JSON.
2. Render the prompt through `llcs_chat_render`.
3. Attach a grammar from tools when tools are present and a grammar is
   available for the model format.
4. Decode tokens through the existing native runtime.
5. For non-streaming calls, parse the full response through `llcs_chat_parse`.
6. For streaming calls, feed token text into `llcs_stream_parser_feed` and emit
   resulting deltas.

The public Dart types do not need a breaking change. Tool calling becomes
functional where it was previously absent or best-effort.

## Testing Strategy

Use three layers:

- Dart unit tests with fixed model-output strings and parser fixture JSON.
- Per-family integration tests with small GGUF models that support tool calling.
- Opt-in real-model smoke tests using
  `LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf`.

The fixture set must cover at least Llama 3.1, Qwen 2.5, and Hermes-style tool
formats.

## Migration

Plain text chat calls without tools should see no behavior change. Suggested
versioning:

- `v0.6.0`: non-streaming tool calling backed by the shim.
- `v0.7.0`: streaming tool-call deltas backed by the streaming parser.
- `v0.8.0`: remove any transitional Dart-side parser fallback that is no
  longer needed.

## Out Of Scope

- GPU backend matrix changes.
- Vision and multimodal shims around `tools/mtmd/`.
- Speculative decoding.
- Embeddings and reranking helpers.

Those surfaces can use the same shim pattern later, but they should be tracked
separately.

## Acceptance Criteria

- `client.chat.completions.create(model, messages, tools)` returns populated
  `tool_calls` for at least Llama 3.1, Qwen 2.5, and Hermes-style fixtures.
- Streaming calls emit incremental tool-call deltas matching the OpenAI wire
  shape.
- The submodule-bump workflow is documented and tested with shim canaries.
- Binary-size growth is measured and reported per platform.
