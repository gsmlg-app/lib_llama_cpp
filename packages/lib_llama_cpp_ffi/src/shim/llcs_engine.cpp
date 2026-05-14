// llcs_engine.cpp — lib_llama_cpp server-context engine shim
//
// ~460-line extern "C" wrapper around llama.cpp server_context.
// See llcs.h for the public ABI and docs/design/server-context-engine.md
// for the full design rationale.

#include "llcs.h"

// Upstream server headers (no httplib dependency in header-only path)
#include "server-context.h"
#include "server-common.h"
#include "server-task.h"
#include "server-queue.h"

#include "common.h"
#include "llama.h"
#include "log.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <queue>

using json = nlohmann::ordered_json;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static char * heap_copy(const std::string & s) {
    char * p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p) {
        std::memcpy(p, s.c_str(), s.size() + 1);
    }
    return p;
}

static char * heap_empty() {
    char * p = static_cast<char *>(std::malloc(1));
    if (p) p[0] = '\0';
    return p;
}

static void set_error(char ** error_out, const std::string & msg) {
    if (error_out) {
        json err_json = {{"error", msg}};
        *error_out = heap_copy(err_json.dump());
    }
}

// ---------------------------------------------------------------------------
// Per-task event queue: collects streamed results from server_context
// ---------------------------------------------------------------------------

struct llcs_task_events {
    std::mutex mtx;
    std::condition_variable cv;
    std::queue<std::string> events;  // JSON strings
    bool finished = false;
    int task_id = -1;
};

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

struct llcs_engine {
    common_params params;
    server_context ctx_server;
    std::thread loop_thread;

    // Map of active task IDs to their event queues
    std::mutex tasks_mtx;
    std::unordered_map<int, std::shared_ptr<llcs_task_events>> task_map;

    // Cached capabilities JSON string
    mutable std::string caps_cache;
    mutable bool caps_valid = false;

    std::atomic<bool> running{false};
};

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

llcs_engine * llcs_engine_create(const char * params_json, char ** error_out) {
    if (!params_json) {
        set_error(error_out, "params_json must not be NULL");
        return nullptr;
    }

    json params;
    try {
        params = json::parse(params_json);
    } catch (const std::exception & e) {
        set_error(error_out, std::string("Invalid JSON: ") + e.what());
        return nullptr;
    }

    auto engine = std::make_unique<llcs_engine>();

    // Map JSON params to common_params
    engine->params = common_params();

    // Required: model path
    if (!params.contains("model_path") || !params["model_path"].is_string()) {
        set_error(error_out, "params_json must contain 'model_path' (string)");
        return nullptr;
    }
    engine->params.model.path = params["model_path"].get<std::string>();

    // Optional params
    if (params.contains("n_ctx")) {
        engine->params.n_ctx = params["n_ctx"].get<int>();
    }
    if (params.contains("n_gpu_layers")) {
        engine->params.n_gpu_layers = params["n_gpu_layers"].get<int>();
    }
    if (params.contains("n_parallel")) {
        engine->params.n_parallel = params["n_parallel"].get<int>();
    } else {
        engine->params.n_parallel = 1;
    }
    if (params.contains("chat_template")) {
        engine->params.chat_template = params["chat_template"].get<std::string>();
    }
    if (params.contains("reasoning_format")) {
        const auto & rf = params["reasoning_format"].get<std::string>();
        if (rf == "deepseek") {
            engine->params.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        } else if (rf == "none") {
            engine->params.reasoning_format = COMMON_REASONING_FORMAT_NONE;
        }
        // default: COMMON_REASONING_FORMAT_AUTO
    }
    if (params.contains("use_jinja")) {
        engine->params.use_jinja = params["use_jinja"].get<bool>();
    } else {
        engine->params.use_jinja = true;  // default: use jinja
    }

    // Initialize backends
    llama_backend_init();
    llama_numa_init(engine->params.numa);

    // Load model via server_context
    if (!engine->ctx_server.load_model(engine->params)) {
        set_error(error_out, "Failed to load model: " + engine->params.model.path);
        llama_backend_free();
        return nullptr;
    }

    // Start the server's main processing loop in a background thread
    engine->running.store(true);
    engine->loop_thread = std::thread([e = engine.get()]() {
        e->ctx_server.start_loop();
    });

    return engine.release();
}

void llcs_engine_destroy(llcs_engine * engine) {
    if (!engine) return;

    // Terminate the processing loop
    engine->ctx_server.terminate();

    // Wait for the loop thread to exit
    if (engine->loop_thread.joinable()) {
        engine->loop_thread.join();
    }

    engine->running.store(false);

    llama_backend_free();
    delete engine;
}

char * llcs_engine_caps(const llcs_engine * engine) {
    if (!engine) return heap_copy("{}");

    if (engine->caps_valid) {
        return heap_copy(engine->caps_cache);
    }

    auto meta = engine->ctx_server.get_meta();

    json caps = {
        {"model_name",                    meta.model_name},
        {"chat_template",                 !meta.chat_params.tmpls ? "" : "present"},
        {"supports_tools",                meta.chat_template_caps.count("tools") && meta.chat_template_caps.at("tools")},
        {"supports_parallel_tool_calls",  meta.chat_template_caps.count("parallel_tool_calls") && meta.chat_template_caps.at("parallel_tool_calls")},
        {"supports_reasoning",            meta.chat_template_caps.count("thinking") && meta.chat_template_caps.at("thinking")},
        {"supports_vision",               meta.has_inp_image},
        {"supports_audio",                meta.has_inp_audio},
    };

    engine->caps_cache = caps.dump();
    engine->caps_valid = true;
    return heap_copy(engine->caps_cache);
}

// ---------------------------------------------------------------------------
// Request lifecycle
// ---------------------------------------------------------------------------

llcs_task_id llcs_engine_submit(
        llcs_engine * engine,
        const char  * oai_request_json,
        char       ** error_out) {
    if (!engine || !oai_request_json) {
        set_error(error_out, "engine and oai_request_json must not be NULL");
        return -1;
    }

    json body;
    try {
        body = json::parse(oai_request_json);
    } catch (const std::exception & e) {
        set_error(error_out, std::string("Invalid request JSON: ") + e.what());
        return -1;
    }

    // Create a response reader for this request
    auto rd_ptr = std::make_unique<server_response_reader>(
        engine->ctx_server.get_response_reader());
    auto & rd = *rd_ptr;

    auto meta = engine->ctx_server.get_meta();

    // Parse the OAI chat completions request
    std::vector<raw_buffer> files;
    json data;
    try {
        data = oaicompat_chat_params_parse(body, meta.chat_params, files);
    } catch (const std::exception & e) {
        set_error(error_out, std::string("Failed to parse chat completion request: ") + e.what());
        return -1;
    }

    // Build the task
    server_task task(SERVER_TASK_TYPE_COMPLETION);
    task.id = rd.get_new_id();

    // Tokenize the prompt
    try {
        const auto & prompt = data.at("prompt");
        if (meta.has_mtmd) {
            task.tokens = process_mtmd_prompt(nullptr /* TODO: mtmd ctx */, prompt.get<std::string>(), files);
        } else {
            auto inputs = tokenize_input_prompts(
                llama_model_get_vocab(llama_get_model(engine->ctx_server.get_llama_context())),
                nullptr, prompt, true, true);
            if (!inputs.empty()) {
                task.tokens = std::move(inputs[0]);
            }
        }
    } catch (const std::exception & e) {
        set_error(error_out, std::string("Failed to tokenize prompt: ") + e.what());
        return -1;
    }

    // Set task params
    task.params = server_task::params_from_json_cmpl(
        llama_model_get_vocab(llama_get_model(engine->ctx_server.get_llama_context())),
        engine->params,
        meta.slot_n_ctx,
        meta.logit_bias_eog,
        data);

    bool is_stream = json_value(data, "stream", false);
    task.params.stream = is_stream;
    task.params.res_type = TASK_RESPONSE_TYPE_OAI_CHAT;
    task.params.oaicompat_cmpl_id = gen_chatcmplid();
    task.params.oaicompat_model = meta.model_name;

    int task_id = task.id;

    // Create event queue for this task
    auto events = std::make_shared<llcs_task_events>();
    events->task_id = task_id;

    {
        std::lock_guard<std::mutex> lock(engine->tasks_mtx);
        engine->task_map[task_id] = events;
    }

    // Post the task
    rd.post_task(std::move(task));

    // Create a state for tracking streaming diffs
    auto state = std::make_unique<task_result_state>(
        task.params.chat_parser_params);

    // Spawn a drainer thread that pumps results into the event queue
    std::thread([events, rd = std::move(rd_ptr), state = std::move(state),
                 is_stream]() mutable {
        auto should_stop = []() { return false; };

        while (rd->has_next()) {
            auto result = rd->next(should_stop);
            if (!result) break;

            // Let the result update streaming state
            result->update(*state);

            json result_json = result->to_json();
            bool is_final = result->is_stop();

            {
                std::lock_guard<std::mutex> lock(events->mtx);
                events->events.push(result_json.dump());
                if (is_final || result->is_error()) {
                    events->finished = true;
                }
            }
            events->cv.notify_one();

            if (is_final || result->is_error()) break;
        }

        // Mark as finished
        {
            std::lock_guard<std::mutex> lock(events->mtx);
            events->finished = true;
        }
        events->cv.notify_one();
    }).detach();

    return static_cast<llcs_task_id>(task_id);
}

char * llcs_engine_poll(
        llcs_engine * engine,
        llcs_task_id  task_id,
        int32_t       timeout_ms) {
    if (!engine) return nullptr;

    std::shared_ptr<llcs_task_events> events;
    {
        std::lock_guard<std::mutex> lock(engine->tasks_mtx);
        auto it = engine->task_map.find(static_cast<int>(task_id));
        if (it == engine->task_map.end()) {
            return nullptr;  // task not found or already drained
        }
        events = it->second;
    }

    std::unique_lock<std::mutex> lock(events->mtx);

    // Wait for an event or timeout
    if (events->events.empty() && !events->finished) {
        events->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&events]() {
            return !events->events.empty() || events->finished;
        });
    }

    // Check if we have an event
    if (!events->events.empty()) {
        std::string event = std::move(events->events.front());
        events->events.pop();
        return heap_copy(event);
    }

    // If finished and no more events, return NULL (drained)
    if (events->finished) {
        lock.unlock();
        // Clean up the task entry
        std::lock_guard<std::mutex> tasks_lock(engine->tasks_mtx);
        engine->task_map.erase(static_cast<int>(task_id));
        return nullptr;
    }

    // Timeout — return empty string
    return heap_empty();
}

void llcs_engine_cancel(llcs_engine * engine, llcs_task_id task_id) {
    if (!engine) return;

    std::shared_ptr<llcs_task_events> events;
    {
        std::lock_guard<std::mutex> lock(engine->tasks_mtx);
        auto it = engine->task_map.find(static_cast<int>(task_id));
        if (it == engine->task_map.end()) return;
        events = it->second;
    }

    // Post a cancellation task
    auto rd = engine->ctx_server.get_response_reader();
    server_task cancel_task(SERVER_TASK_TYPE_CANCEL);
    cancel_task.id = rd.get_new_id();
    cancel_task.id_target = static_cast<int>(task_id);
    rd.post_task(std::move(cancel_task));

    // Mark as finished
    {
        std::lock_guard<std::mutex> lock(events->mtx);
        events->finished = true;
    }
    events->cv.notify_one();
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

void llcs_string_free(char * str) {
    std::free(str);
}

// ---------------------------------------------------------------------------
// Stubs for server-http.cpp symbols that server-context.cpp references
// via server_res_generator inheriting server_http_res.
//
// server_http_context is declared in server-http.h but we never instantiate
// the HTTP server. We provide stub implementations so the linker is happy.
// The Impl class uses a pimpl pattern — we define an empty stub so the
// unique_ptr destructor compiles.
// ---------------------------------------------------------------------------

class server_http_context::Impl {};

server_http_context::server_http_context()
    : pimpl(std::make_unique<server_http_context::Impl>()) {}
server_http_context::~server_http_context() = default;
bool server_http_context::init(const common_params &) { return false; }
bool server_http_context::start() { return false; }
void server_http_context::stop() const {}
void server_http_context::get(const std::string &, const handler_t &) const {}
void server_http_context::post(const std::string &, const handler_t &) const {}

// ---------------------------------------------------------------------------
// Stubs for download.cpp symbols referenced by server-common.cpp
//
// download.cpp is excluded from the embedded build because it depends on
// libcurl. The only caller in server code is handle_media() which fetches
// remote images over HTTP — we don't support that in in-process mode.
// Users should provide images as base64 data URIs or local file:// paths.
// ---------------------------------------------------------------------------

#include "download.h"

std::pair<long, std::vector<char>> common_remote_get_content(
        const std::string & /* url */,
        const common_remote_params & /* params */) {
    // Return 501 Not Implemented — handle_media() will check the status
    // code and throw "Failed to download image"
    return {501, {}};
}
