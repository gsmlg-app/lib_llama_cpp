// llcs.h — lib_llama_cpp server-context engine ABI
//
// Thin extern "C" boundary around llama.cpp's server_context.
// JSON is the wire format at every boundary. All returned strings
// are heap-allocated by the engine and freed via llcs_string_free.
//
// See docs/design/server-context-engine.md for the full design.

#ifndef LLCS_H
#define LLCS_H

#include <stdint.h>

#if defined(_WIN32)
#define LLCS_API __declspec(dllexport)
#else
#define LLCS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

typedef struct llcs_engine llcs_engine;

// Create an engine from a JSON params blob.
//
// params_json must carry at least "model_path". Optional fields include:
//   n_ctx (total context), n_batch, n_ubatch, n_threads, n_threads_batch,
//   n_gpu_layers, n_parallel, flash_attn (auto/on/off or boolean),
//   cache_type_k, cache_type_v, swa_full, chat_template, reasoning_format,
//   use_jinja, backend (auto/cpu/cuda/vulkan), require_backend (default true).
//   result_retention_ms (100..86400000, default 30000).
// Explicit optional GPU fallback requires require_backend=false and is reported
// as degradation. n_ctx above the GGUF native context is rejected before model
// allocation; no RoPE extrapolation. Defaults use F16 compact SWA/shared KV.
// Unknown fields are reported in caps.unsupported and are not applied.
//
// On success returns a non-NULL engine pointer.
// On failure returns NULL and writes a JSON error string to *error_out
// (caller must free via llcs_string_free).
LLCS_API llcs_engine * llcs_engine_create(const char * params_json, char ** error_out);

// Destroy the engine and release all resources.
// Safe to call with NULL.
LLCS_API void llcs_engine_destroy(llcs_engine * engine);

// Return a JSON object describing engine capabilities after model load:
//   { "chat_template": "...", "supports_tools": bool,
//     "supports_parallel_tool_calls": bool, "supports_reasoning": bool,
//     "supports_vision": bool, "supports_audio": bool }
//
// The returned string is heap-allocated; caller must free via llcs_string_free.
// Cached internally; cheap to call repeatedly.
LLCS_API char * llcs_engine_caps(const llcs_engine * engine);

// Bounded collector/task/result counters, tasks[id,state,prompt_progress], and
// sampled upstream slot metrics. Streaming task states follow upstream prompt
// progress and decode results. Nonstream exposes sampled active/decoding;
// its precise prefill phase is unavailable. Cancelled tasks are reclaimed
// immediately and counted in cancelled; terminal failures increment failed.
// Returned string uses llcs_string_free.
LLCS_API char * llcs_engine_stats(const llcs_engine * engine);

// Render/tokenize without prefill, queueing, or KV mutation. Uses exactly the
// submission preparation path. Returns prompt_tokens, reserved_output_tokens,
// effective_context, usable_context, fits. Overflow still returns counts with
// fits=false; malformed requests return NULL plus a structured error.
LLCS_API char * llcs_engine_prepare(llcs_engine * engine, const char * request_json, char ** error_out);

// Shared process backend ownership, also used by the direct Dart runtime.
// Acquire returns 0 or -1 with a structured error. Every successful acquire
// requires one release after all associated contexts/models are freed.
LLCS_API int32_t llcs_backend_acquire(char ** error_out);
LLCS_API void llcs_backend_release(void);

// Atomic cancellation flag for direct synchronous llama_decode callers.
// The flag owner must wait for worker shutdown before freeing it. Install is
// called by the context-owning worker; request only writes the atomic flag.
struct llama_context;
LLCS_API void * llcs_cancel_create(void);
LLCS_API void llcs_cancel_free(void * flag);
LLCS_API void llcs_cancel_request(void * flag);
LLCS_API void llcs_cancel_reset(void * flag);
LLCS_API int32_t llcs_cancel_is_requested(void * flag);
LLCS_API void llcs_cancel_install(void * flag, struct llama_context * ctx);
// Reset grants 64 response credits. Wait blocks until credit or cancellation;
// only worker threads may call wait. Release after a consumer resumes its yield.
LLCS_API int32_t llcs_cancel_wait_credit(void * flag);
LLCS_API void llcs_cancel_release_credit(void * flag);

// ---------------------------------------------------------------------------
// Request lifecycle
// ---------------------------------------------------------------------------

typedef int64_t llcs_task_id;

// Submit an OAI-shaped chat completion request.
//
// oai_request_json is the full request body (messages, tools, stream, etc.)
// matching the OpenAI /v1/chat/completions schema.
//
// Returns a task ID >= 0 on success.
// Returns -1 on failure and writes a JSON error to *error_out.
LLCS_API llcs_task_id llcs_engine_submit(
    llcs_engine * engine,
    const char  * oai_request_json,
    char       ** error_out);

// Block up to timeout_ms for the next event for the given task.
//
// Returns:
//   - JSON string (chunk or final event) when one is available.
//     The caller must free the string via llcs_string_free.
//   - Empty string "" (heap-allocated) when the timeout expires
//     with no event available.
//   - NULL when the task is fully drained (no more events).
// Completed results expire after result_retention_ms even without polling.
// A bounded ring retains the latest 64 expiry IDs; the first subsequent poll
// returns error.code=result_expired/type=consumer_timeout, then NULL.
LLCS_API char * llcs_engine_poll(
    llcs_engine * engine,
    llcs_task_id  task_id,
    int32_t       timeout_ms);

// Cancel queued/prefill/decode work through upstream CANCEL. Reclaims retained
// request state without requiring another poll. Idempotent after completion.
LLCS_API void llcs_engine_cancel(llcs_engine * engine, llcs_task_id task_id);

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

// Free a string returned by any llcs_engine_* function.
// Safe to call with NULL.
LLCS_API void llcs_string_free(char * str);

#ifdef __cplusplus
}
#endif

#endif // LLCS_H
