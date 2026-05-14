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
//   n_ctx, n_gpu_layers, n_parallel, chat_template (override),
//   reasoning_format, and all common_params fields.
//
// On success returns a non-NULL engine pointer.
// On failure returns NULL and writes a JSON error string to *error_out
// (caller must free via llcs_string_free).
llcs_engine * llcs_engine_create(const char * params_json, char ** error_out);

// Destroy the engine and release all resources.
// Safe to call with NULL.
void llcs_engine_destroy(llcs_engine * engine);

// Return a JSON object describing engine capabilities after model load:
//   { "chat_template": "...", "supports_tools": bool,
//     "supports_parallel_tool_calls": bool, "supports_reasoning": bool,
//     "supports_vision": bool, "supports_audio": bool }
//
// The returned string is heap-allocated; caller must free via llcs_string_free.
// Cached internally; cheap to call repeatedly.
char * llcs_engine_caps(const llcs_engine * engine);

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
llcs_task_id llcs_engine_submit(
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
char * llcs_engine_poll(
    llcs_engine * engine,
    llcs_task_id  task_id,
    int32_t       timeout_ms);

// Cancel a running task. Idempotent; safe to call after the task
// has already finished.
void llcs_engine_cancel(llcs_engine * engine, llcs_task_id task_id);

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

// Free a string returned by any llcs_engine_* function.
// Safe to call with NULL.
void llcs_string_free(char * str);

#ifdef __cplusplus
}
#endif

#endif // LLCS_H
