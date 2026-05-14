# Tool Calling via In-Process `server_context` — Architecture

> **Status:** Active
> **Version:** v0.6.0
> **Supersedes:** [c-shim-tool-calling.md](c-shim-tool-calling.md)

## Why the Pivot

The original C-shim plan reimplemented in C++ the orchestration that `server.cpp`
already provides: render → grammar/triggers → decode loop with slot cache → parse
→ OAI-shaped streaming deltas → `finish_reason` synthesis. Reimplementing it means:

- Chasing upstream parser refinements with hand-written glue.
- Re-deriving `finish_reason`, parallel tool calls, reasoning extraction,
  prompt-cache reuse.
- Missing future features (vision, embeddings, reranking) until each is shimmed
  separately.

Binding `server_context` directly inherits the orchestration upstream tests against
every model family on every commit. The cost is ~2 MB binary overhead (server
routing code we compile but never call) and a tighter coupling to upstream's
internal data structures, managed via compile-time canaries and tagged releases.

## Architecture

```
┌─────────────────────────────────────────────────┐
│             Dart facade                         │
│  LlamaOpenAIClient  ←  OAI types, messages      │
│       ↕                                         │
│  Engine Worker Isolate                          │
│       ↕ (SendPort / ReceivePort)                │
│  llcs_engine bindings (ffigen)                  │
└─────────────┬───────────────────────────────────┘
              │ extern "C"  (JSON in, JSON out)
┌─────────────▼───────────────────────────────────┐
│           llcs_engine.cpp   (~460 lines)         │
│  create → server_context.load_model()           │
│  submit → oaicompat_chat_params_parse()         │
│           → server_response_reader.post_task()  │
│  poll   → server_response_reader.next()         │
│  cancel → SERVER_TASK_TYPE_CANCEL               │
│  caps   → chat_template_caps, model metadata    │
│  destroy→ terminate + join                      │
└─────────────┬───────────────────────────────────┘
              │ C++ (direct linkage)
┌─────────────▼───────────────────────────────────┐
│  server_context + server-common + server-task    │
│  server-queue + server-chat                      │
│  (upstream, compiled WITHOUT server-http.cpp)    │
└─────────────┬───────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────┐
│          libllama  (unchanged)                   │
└─────────────────────────────────────────────────┘
```

## ABI: `llcs.h`

Seven entry points, all `extern "C"`:

| Function | Signature | Semantics |
|---|---|---|
| `llcs_engine_create` | `(const char* params_json, char** error_out) → llcs_engine*` | Load model, start processing loop |
| `llcs_engine_destroy` | `(llcs_engine*)` | Terminate loop, free resources |
| `llcs_engine_caps` | `(const llcs_engine*) → char*` | JSON capabilities (tools, reasoning, vision) |
| `llcs_engine_submit` | `(engine, const char* oai_json, char** err) → llcs_task_id` | Post OAI chat completion request |
| `llcs_engine_poll` | `(engine, task_id, timeout_ms) → char*` | Block for next event; NULL = drained |
| `llcs_engine_cancel` | `(engine, task_id)` | Cancel running task |
| `llcs_string_free` | `(char*)` | Free heap-allocated strings |

**Wire format:** JSON at every boundary. No custom structs cross the ABI.

## httplib Stripping

The upstream server is already modularized:

- `server-http.cpp` is the **only** file that `#include`s `<cpp-httplib/httplib.h>`
- `server-context.h/cpp` has zero httplib dependency
- `server_http_req`, `server_http_res`, `server_http_context` in `server-http.h`
  are pure C++ structs

**Strategy:** Exclude `server-http.cpp` from compilation and provide 10-line stubs
for `server_http_context` methods in `llcs_engine.cpp`. Zero upstream patches needed.

### Excluded Files

| File | Reason |
|---|---|
| `server-http.cpp` | httplib implementation |
| `server-models.cpp` | Router mode, multi-model management |
| `server-tools.cpp` | Built-in tools (needs `sheredom/subprocess.h`) |
| `server.cpp` | `main()`, signal handlers |
| `server-cors-proxy.h` | CORS proxy for WebUI MCP |

## Drift Discipline

### Compile-Time

```cpp
static_assert(sizeof(server_task) == EXPECTED_SIZE,
  "server_task struct has changed — update llcs_engine");
```

### Runtime

On `llcs_engine_create`, submit a minimal "hello" completion and verify the
response parses as valid OAI JSON.

### Submodule Strategy

- Pin to upstream release tags (e.g., `b5678`)
- Update tag → compile → canaries fire → update shim → re-test

## Build Integration

### Apple (CocoaPods)

Both macOS and iOS podspecs:
- Include `llama_cpp_sources/llama.cpp/tools/server/*.cpp` in source_files
- Exclude `server.cpp`, `server-http.cpp`, `server-models.cpp`, `server-tools.cpp`
- Add `tools/server` to HEADER_SEARCH_PATHS
- Include `lib_llama_cpp_ffi/src/shim/*.cpp`

### CMake (Android, Linux, Windows)

Shared `lib_llama_cpp_cpu_backend.cmake`:
- Builds `llcs-server` static library from 5 server source files
- Links against `llama-common` and `llama`
- `llcs_engine.cpp` compiled as part of the main shared library
- Linked via `$<TARGET_NAME_IF_EXISTS:llcs-server>` (graceful if missing)

## Compatibility

- Existing `LibLlamaCpp.transform` and `LlamaModelHandle` APIs remain functional
  as deprecated code paths for one minor version
- New `LlamaServerEngine` coexists alongside old engine
- Users can opt-in via `LlamaOpenAIClient(engine: LlamaServerEngine(...))`
