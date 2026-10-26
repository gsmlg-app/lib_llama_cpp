#include "llcs.h"
#include "server-context.h"
#include "server-common.h"
#include "server-task.h"
#include "server-queue.h"
#include "common.h"
#include "llama.h"
#include "ggml-backend.h"
#include "gguf.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using json = nlohmann::ordered_json;

static char * heap_copy(const std::string & s) noexcept {
    char * p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
static char * heap_copy(const char * s) noexcept {
    const size_t length = std::strlen(s) + 1;
    char * p = static_cast<char *>(std::malloc(length));
    if (p) std::memcpy(p, s, length);
    return p;
}

static json error_json(const char * code, const std::string & message) {
    return {{"code", code}, {"type", code}, {"message", message}};
}

// Error reporting itself must not throw, including when handling bad_alloc.
static void set_error(char ** out, const char * message, const char * code = "invalid_request") noexcept {
    if (!out) return;
    try { *out = heap_copy(error_json(code, message).dump()); }
    catch (...) { *out = heap_copy("{\"code\":\"allocation\",\"type\":\"allocation\",\"message\":\"error allocation failed\"}"); }
}

static std::mutex g_backend_mtx;
static size_t g_backend_ref_count = 0;

static void backend_acquire() {
    std::lock_guard<std::mutex> lock(g_backend_mtx);
    if (!g_backend_ref_count) llama_backend_init();
    ++g_backend_ref_count;
}

static void backend_release() {
    std::lock_guard<std::mutex> lock(g_backend_mtx);
    if (g_backend_ref_count && !--g_backend_ref_count) llama_backend_free();
}

int32_t llcs_backend_acquire(char ** error_out) {
    if (error_out) *error_out = nullptr;
    try { backend_acquire(); return 0; }
    catch (const std::bad_alloc &) { set_error(error_out, "backend allocation failed", "allocation"); }
    catch (const std::exception & e) { set_error(error_out, e.what(), "backend"); }
    catch (...) { set_error(error_out, "backend initialization failed", "backend"); }
    return -1;
}

void llcs_backend_release() { try { backend_release(); } catch (...) {} }

struct llcs_cancel_flag {
    std::atomic<bool> requested{false};
    std::mutex mtx;
    std::condition_variable cv;
    size_t credits = 64;
};
void * llcs_cancel_create() { try { return new llcs_cancel_flag; } catch (...) { return nullptr; } }
void llcs_cancel_free(void * p) { try { delete static_cast<llcs_cancel_flag *>(p); } catch (...) {} }
void llcs_cancel_request(void * p) {
    try {
        if (!p) return;
        auto * flag = static_cast<llcs_cancel_flag *>(p);
        flag->requested.store(true);
        // Synchronize with wait's check/sleep transition to prevent a lost wake.
        { std::lock_guard<std::mutex> lock(flag->mtx); }
        flag->cv.notify_all();
    } catch (...) {}
}
void llcs_cancel_reset(void * p) {
    try {
        if (!p) return;
        auto * flag = static_cast<llcs_cancel_flag *>(p);
        std::lock_guard<std::mutex> lock(flag->mtx);
        flag->credits = 64;
        flag->requested.store(false);
    } catch (...) {}
}
int32_t llcs_cancel_wait_credit(void * p) {
    try {
        if (!p) return 0;
        auto * flag = static_cast<llcs_cancel_flag *>(p);
        std::unique_lock<std::mutex> lock(flag->mtx);
        flag->cv.wait(lock, [&] { return flag->requested.load() || flag->credits > 0; });
        if (flag->requested.load()) return 0;
        --flag->credits;
        return 1;
    } catch (...) { return 0; }
}
void llcs_cancel_release_credit(void * p) {
    try {
        if (!p) return;
        auto * flag = static_cast<llcs_cancel_flag *>(p);
        { std::lock_guard<std::mutex> lock(flag->mtx); if (flag->credits < 64) ++flag->credits; }
        flag->cv.notify_one();
    } catch (...) {}
}
int32_t llcs_cancel_is_requested(void * p) { try { return p && static_cast<llcs_cancel_flag *>(p)->requested.load(); } catch (...) { return 1; } }
void llcs_cancel_install(void * p, llama_context * ctx) {
    try {
        if (ctx) llama_set_abort_callback(ctx, p ? +[](void * flag) -> bool {
            return static_cast<llcs_cancel_flag *>(flag)->requested.load();
        } : nullptr, p);
    } catch (...) {}
}

static bool contains_media_word(std::string value) {
    for (char & c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return value.find("image") != std::string::npos || value.find("audio") != std::string::npos;
}
static bool request_contains_media(const json & value) {
    if (value.is_array()) {
        for (const auto & item : value) if (request_contains_media(item)) return true;
    } else if (value.is_object()) {
        if (value.contains("type") && value["type"].is_string() && contains_media_word(value["type"])) return true;
        for (auto it = value.begin(); it != value.end(); ++it)
            if (contains_media_word(it.key()) || request_contains_media(it.value())) return true;
    }
    return false;
}

struct llcs_task_events {
    std::deque<std::string> events;
    size_t bytes = 0;
    bool finished = false;
    bool streaming = false;
    bool emit_progress = false;
    int64_t finished_at_ms = 0;
    std::string phase = "queued";
    json prompt_progress = json::object();
    std::unique_ptr<task_result_state> state;
};

struct backend_lease {
    bool held = false;
    ~backend_lease() { if (held) llcs_backend_release(); }
};

struct llcs_engine {
    // Destruction order keeps the backend alive until server context/model teardown.
    backend_lease backend;
    common_params params;
    server_context ctx_server;
    std::unique_ptr<server_context_meta> meta;
    const llama_vocab * vocab = nullptr;
    server_queue * queue_tasks = nullptr;
    server_response * queue_results = nullptr;
    std::thread loop_thread;
    std::thread collector;
    mutable std::mutex tasks_mtx;
    std::condition_variable cv;
    std::unordered_map<int, std::shared_ptr<llcs_task_events>> task_map;
    // Metrics tasks acknowledge that upstream processed each cancellation.
    std::unordered_set<int> cancellation_barriers;
    int metrics_probe = -1;
    int64_t next_probe_ms = 0;
    std::atomic<bool> running{false};
    std::atomic<bool> closing{false};
    int32_t result_retention_ms = 30000;
    std::deque<int> expired_tasks; // bounded lightweight timeout tombstones
    std::string caps_cache;
    json last_metrics = json::object();
    size_t submitted = 0, completed = 0, cancelled = 0, failed = 0, expired = 0;
    static constexpr size_t max_tasks = 64;
    static constexpr size_t max_event_bytes = 1024 * 1024;
    static constexpr size_t max_events = 1024;

    void cancel_locked(int id) {
        queue_results->remove_waiting_task_id(id);
        server_task cancel(SERVER_TASK_TYPE_CANCEL);
        cancel.id = queue_tasks->get_new_id();
        cancel.id_target = id;
        server_task barrier(SERVER_TASK_TYPE_METRICS);
        barrier.id = queue_tasks->get_new_id();
        const int barrier_id = barrier.id;
        cancellation_barriers.insert(barrier_id);
        queue_results->add_waiting_task_id(barrier_id);
        // front-post reverses order, so cancellation executes before the barrier.
        std::vector<server_task> batch;
        batch.push_back(std::move(barrier));
        batch.push_back(std::move(cancel));
        queue_tasks->post(std::move(batch), true);
    }

    void shutdown() noexcept {
        closing.store(true);
        running.store(false);
        cv.notify_all();
        // The collector uses the non-terminating upstream timed receive. Never
        // terminate queue_results: its upstream shutdown path calls terminate().
        if (collector.joinable()) collector.join();
        try { if (queue_tasks) {
            std::lock_guard<std::mutex> lock(tasks_mtx);
            for (const auto & item : task_map) {
                queue_results->remove_waiting_task_id(item.first);
                server_task task(SERVER_TASK_TYPE_CANCEL);
                task.id = queue_tasks->get_new_id();
                task.id_target = item.first;
                queue_tasks->post(std::move(task), true);
            }
            for (int id : cancellation_barriers) queue_results->remove_waiting_task_id(id);
            if (metrics_probe >= 0) queue_results->remove_waiting_task_id(metrics_probe);
        } } catch (...) {}
        try { ctx_server.terminate(); } catch (...) {}
        if (loop_thread.joinable()) loop_thread.join();
        task_map.clear();
        cancellation_barriers.clear();
        expired_tasks.clear();
    }
    ~llcs_engine() { shutdown(); }
};

static void fail_engine(llcs_engine * e) noexcept {
    e->running.store(false);
    try {
        std::lock_guard<std::mutex> lock(e->tasks_mtx);
        for (auto & item : e->task_map) {
            auto & events = *item.second;
            if (events.finished) continue;
            events.finished = true;
            events.finished_at_ms = ggml_time_ms();
            events.phase = "failed";
            ++e->failed;
            events.state.reset();
            events.events.clear();
            events.events.emplace_back("{\"error\":{\"code\":\"backend\",\"type\":\"backend\",\"message\":\"native processing thread failed\"}}");
            events.bytes = events.events.front().size();
        }
    } catch (...) {}
    e->cv.notify_all();
}

static void collect_results(llcs_engine * e) noexcept {
    try {
        while (!e->closing.load()) {
            std::unordered_set<int> ids;
            {
                std::unique_lock<std::mutex> lock(e->tasks_mtx);
                const int64_t now = ggml_time_ms();
                for (auto it = e->task_map.begin(); it != e->task_map.end();) {
                    auto & events = *it->second;
                    if (events.finished && now - events.finished_at_ms >= e->result_retention_ms) {
                        if (e->expired_tasks.size() == llcs_engine::max_tasks) e->expired_tasks.pop_front();
                        e->expired_tasks.push_back(it->first);
                        events.events.clear();
                        events.bytes = 0;
                        events.state.reset();
                        it = e->task_map.erase(it);
                        ++e->expired;
                    } else ++it;
                }
                for (const auto & item : e->task_map) if (!item.second->finished) ids.insert(item.first);
                if (!ids.empty() && e->metrics_probe < 0 && ggml_time_ms() >= e->next_probe_ms) {
                    server_task probe(SERVER_TASK_TYPE_METRICS);
                    probe.id = e->queue_tasks->get_new_id();
                    e->metrics_probe = probe.id;
                    e->next_probe_ms = ggml_time_ms() + 100;
                    e->queue_results->add_waiting_task_id(probe.id);
                    e->queue_tasks->post(std::move(probe));
                }
                if (e->metrics_probe >= 0) ids.insert(e->metrics_probe);
                ids.insert(e->cancellation_barriers.begin(), e->cancellation_barriers.end());
                if (ids.empty()) {
                    e->cv.wait_for(lock, std::chrono::milliseconds(100));
                    continue;
                }
            }
            auto result = e->queue_results->recv_with_timeout(ids, 1);
            if (!result) continue;
            std::lock_guard<std::mutex> lock(e->tasks_mtx);
            const bool is_probe = e->metrics_probe == result->id;
            if (is_probe || e->cancellation_barriers.erase(result->id)) {
                if (is_probe) e->metrics_probe = -1;
                e->last_metrics = result->to_json();
                for (const auto & slot : e->last_metrics.at("slots")) {
                    if (!slot.value("is_processing", false) || !slot.contains("id_task")) continue;
                    auto active = e->task_map.find(slot.at("id_task").get<int>());
                    if (active == e->task_map.end() || active->second->finished || active->second->streaming) continue;
                    int decoded = 0;
                    if (slot.contains("next_token")) {
                        const auto & next = slot.at("next_token");
                        if (next.is_object()) decoded = next.value("n_decoded", 0);
                        else if (next.is_array() && !next.empty()) decoded = next.front().value("n_decoded", 0);
                    }
                    if (decoded > 0) active->second->phase = "decoding";
                    else if (active->second->phase == "queued") active->second->phase = "active";
                }
                e->queue_results->remove_waiting_task_id(result->id);
                e->cv.notify_all();
                continue;
            }
            auto it = e->task_map.find(result->id);
            if (it == e->task_map.end() || it->second->finished) continue;
            auto & events = *it->second;
            try {
                if (const auto * partial = dynamic_cast<server_task_result_cmpl_partial *>(result.get())) {
                    if (partial->is_progress || partial->is_begin) {
                        events.phase = "prefilling";
                        if (partial->is_progress) events.prompt_progress = partial->progress.to_json();
                        if (!events.emit_progress) { e->cv.notify_all(); continue; }
                    } else events.phase = "decoding";
                }
                // We receive directly from server_response, so update exactly
                // once. A server_response_reader::next() would already do this.
                result->update(*events.state);
                json value = result->to_json();
                if (result->is_error()) {
                    const auto * err = dynamic_cast<server_task_result_error *>(result.get());
                    const char * code = !err ? "backend" : err->err_type == ERROR_TYPE_EXCEED_CONTEXT_SIZE ? "context_overflow" :
                        (err->err_type == ERROR_TYPE_INVALID_REQUEST || err->err_type == ERROR_TYPE_NOT_SUPPORTED) ? "invalid_request" : "backend";
                    value = {{"error", error_json(code, err ? err->err_msg : "native generation failed")}};
                }
                auto append = [&](const json & event) {
                    if (event.is_null()) return; // upstream begin marker
                    std::string encoded = event.dump();
                    if (events.events.size() >= llcs_engine::max_events || encoded.size() > llcs_engine::max_event_bytes - events.bytes)
                        throw std::length_error("result buffer capacity exceeded; poll the task faster");
                    events.bytes += encoded.size();
                    events.events.push_back(std::move(encoded));
                };
                if (value.is_array()) { for (const auto & delta : value) append(delta); }
                else append(value);
                if (result->is_stop() || result->is_error()) {
                    events.finished = true;
                    events.finished_at_ms = ggml_time_ms();
                    events.phase = result->is_error() ? "failed" : "completed";
                    events.state.reset();
                    e->queue_results->remove_waiting_task_id(result->id);
                    if (result->is_error()) ++e->failed;
                    else ++e->completed;
                }
            } catch (const std::exception & ex) {
                e->cancel_locked(result->id);
                events.events.clear();
                events.events.push_back(json({{"error", error_json(dynamic_cast<const std::bad_alloc *>(&ex) ? "allocation" : "backend", ex.what())}}).dump());
                events.bytes = events.events.front().size();
                events.finished = true;
                events.finished_at_ms = ggml_time_ms();
                events.phase = "failed";
                ++e->failed;
                events.state.reset();
            }
            e->cv.notify_all();
        }
    } catch (...) { fail_engine(e); }
}

static int config_int(const json & params, const char * key, int fallback, int minimum, int maximum = INT32_MAX) {
    if (!params.contains(key)) return fallback;
    const auto & v = params.at(key);
    if (!v.is_number_integer()) throw std::invalid_argument(std::string(key) + " must be an integer");
    const int64_t n = v.get<int64_t>();
    if (n < minimum || n > maximum) throw std::invalid_argument(std::string(key) + " is out of range");
    return static_cast<int>(n);
}
static ggml_type cache_type(const json & params, const char * key) {
    if (!params.contains(key)) return GGML_TYPE_F16;
    const std::string name = params.at(key).get<std::string>();
    for (ggml_type type : {GGML_TYPE_F16, GGML_TYPE_F32, GGML_TYPE_BF16, GGML_TYPE_Q8_0, GGML_TYPE_Q4_0, GGML_TYPE_Q4_1, GGML_TYPE_Q5_0, GGML_TYPE_Q5_1, GGML_TYPE_IQ4_NL})
        if (name == ggml_type_name(type)) return type;
    throw std::invalid_argument(std::string(key) + " is unsupported");
}

// Metadata-only GGUF inspection: no tensor buffers or llama_context allocation.
static int64_t native_context_limit(const std::string & path) {
    std::unique_ptr<gguf_context, decltype(&gguf_free)> metadata(
        gguf_init_from_file(path.c_str(), {true, nullptr}), gguf_free);
    if (!metadata) throw std::runtime_error("failed to read model GGUF metadata");
    const int64_t architecture = gguf_find_key(metadata.get(), "general.architecture");
    if (architecture < 0 || gguf_get_kv_type(metadata.get(), architecture) != GGUF_TYPE_STRING) return 0;
    const std::string key = std::string(gguf_get_val_str(metadata.get(), architecture)) + ".context_length";
    const int64_t id = gguf_find_key(metadata.get(), key.c_str());
    if (id < 0) return 0;
    switch (gguf_get_kv_type(metadata.get(), id)) {
        case GGUF_TYPE_UINT32: return gguf_get_val_u32(metadata.get(), id);
        case GGUF_TYPE_INT32: return gguf_get_val_i32(metadata.get(), id);
        case GGUF_TYPE_UINT64: {
            const uint64_t value = gguf_get_val_u64(metadata.get(), id);
            return value <= INT64_MAX ? static_cast<int64_t>(value) : 0;
        }
        case GGUF_TYPE_INT64: return gguf_get_val_i64(metadata.get(), id);
        default: return 0;
    }
}

llcs_engine * llcs_engine_create(const char * params_json, char ** error_out) {
    if (error_out) *error_out = nullptr;
    const char * phase = "invalid_request";
    try {
        if (!params_json) throw std::invalid_argument("params_json must not be NULL");
        const json config = json::parse(params_json);
        if (!config.is_object()) throw std::invalid_argument("engine configuration must be an object");
        auto e = std::make_unique<llcs_engine>();
        e->params.model.path = config.at("model_path").get<std::string>();
        if (e->params.model.path.empty()) throw std::invalid_argument("model_path must not be empty");
        e->params.n_ctx = config_int(config, "n_ctx", 0, 0);
        e->params.n_batch = config_int(config, "n_batch", 2048, 1);
        e->params.n_ubatch = config_int(config, "n_ubatch", 512, 1);
        if (e->params.n_ubatch > e->params.n_batch) {
            if (config.contains("n_ubatch")) throw std::invalid_argument("n_ubatch must not exceed n_batch");
            e->params.n_ubatch = e->params.n_batch;
        }
        e->params.n_parallel = config_int(config, "n_parallel", 1, 1, 64);
        e->result_retention_ms = config_int(config, "result_retention_ms", 30000, 100, 86400000);
        e->params.n_gpu_layers = config_int(config, "n_gpu_layers", -1, -2);
        e->params.cpuparams.n_threads = config_int(config, "n_threads", -1, 1, GGML_MAX_N_THREADS);
        e->params.cpuparams_batch.n_threads = config_int(config, "n_threads_batch", -1, 1, GGML_MAX_N_THREADS);
        // The CLI normally resolves these defaults. Embedding server_context
        // bypasses argument parsing, so use the same upstream postprocessing.
        postprocess_cpu_params(e->params.cpuparams, nullptr);
        postprocess_cpu_params(e->params.cpuparams_batch, &e->params.cpuparams);
        e->params.cache_type_k = cache_type(config, "cache_type_k");
        e->params.cache_type_v = cache_type(config, "cache_type_v");
        e->params.swa_full = config.value("swa_full", false);
        e->params.kv_unified = true;
        e->params.ctx_shift = false;
        e->params.fit_params = false; // never silently reduce the requested budget
        e->params.n_predict = 256;
        e->params.sleep_idle_seconds = -1;
        e->params.use_jinja = config.value("use_jinja", true);
        e->params.chat_template = config.value("chat_template", std::string());
        if (config.contains("reasoning_format")) {
            const auto rf = config.at("reasoning_format").get<std::string>();
            if (rf == "deepseek") e->params.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
            else if (rf == "none") e->params.reasoning_format = COMMON_REASONING_FORMAT_NONE;
            else if (rf != "auto") throw std::invalid_argument("unsupported reasoning_format");
        }
        if (config.contains("flash_attn")) {
            const auto & fa = config.at("flash_attn");
            const std::string mode = fa.is_boolean() ? (fa.get<bool>() ? "on" : "off") : fa.get<std::string>();
            if (mode == "on") e->params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
            else if (mode == "off") e->params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
            else if (mode == "auto") e->params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
            else throw std::invalid_argument("flash_attn must be auto, on, off, or boolean");
        }
        const std::string requested_backend = config.value("backend", std::string("auto"));
        const bool require_backend = config.value("require_backend", true);
        if (requested_backend != "auto" && requested_backend != "cpu" && requested_backend != "cuda" && requested_backend != "vulkan")
            throw std::invalid_argument("backend must be auto, cpu, cuda, or vulkan");
        if (require_backend && requested_backend != "auto" && requested_backend != "cpu" && e->params.n_gpu_layers == 0)
            throw std::invalid_argument("required GPU backend conflicts with n_gpu_layers=0");
        phase = "backend";
        const int64_t native_n_ctx = native_context_limit(e->params.model.path);
        if (native_n_ctx > 0 && e->params.n_ctx > native_n_ctx) {
            set_error(error_out, "requested n_ctx exceeds model native context; RoPE extrapolation is disabled", "context_overflow");
            return nullptr;
        }
        backend_acquire();
        e->backend.held = true;
        llama_numa_init(e->params.numa);
        json compiled_backends = json::array();
        for (size_t i = 0; i < ggml_backend_reg_count(); ++i) compiled_backends.push_back(ggml_backend_reg_name(ggml_backend_reg_get(i)));
        json device_info = json::array();
        std::string selected_backend = requested_backend;
        std::string degradation;
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            auto * device = ggml_backend_dev_get(i);
            std::string backend_name = ggml_backend_reg_name(ggml_backend_dev_backend_reg(device));
            std::string lower_name = backend_name;
            for (char & ch : lower_name) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            const auto type = ggml_backend_dev_type(device);
            device_info.push_back({{"name", ggml_backend_dev_name(device)}, {"backend", backend_name},
                {"type", type == GGML_BACKEND_DEVICE_TYPE_CPU ? "cpu" : type == GGML_BACKEND_DEVICE_TYPE_IGPU ? "igpu" : type == GGML_BACKEND_DEVICE_TYPE_GPU ? "gpu" : "accelerator"}});
            if (requested_backend != "auto" && requested_backend != "cpu" && lower_name == requested_backend &&
                (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU)) e->params.devices.push_back(device);
        }
        if (requested_backend != "auto" && requested_backend != "cpu" && e->params.devices.empty()) {
            if (require_backend) throw std::runtime_error("required " + requested_backend + " backend/device is unavailable");
            selected_backend = "cpu";
            degradation = "requested " + requested_backend + " backend/device unavailable; explicit optional fallback to cpu";
        }
        if (selected_backend == "cpu") {
            e->params.n_gpu_layers = 0;
            e->params.devices = {nullptr}; // explicitly exclude all GPU devices
        } else if (!e->params.devices.empty()) e->params.devices.push_back(nullptr);
        if (!e->ctx_server.load_model(e->params)) throw std::runtime_error("failed to load model: " + e->params.model.path);
        e->meta = std::make_unique<server_context_meta>(e->ctx_server.get_meta());
        if (e->params.n_ctx > e->meta->model_n_ctx_train) {
            set_error(error_out, "requested n_ctx exceeds model native context; RoPE extrapolation is disabled", "context_overflow");
            return nullptr;
        }
        auto * ctx = e->ctx_server.get_llama_context();
        e->vocab = llama_model_get_vocab(llama_get_model(ctx));
        // This reader never owns tasks. Only borrow the stable queues; its empty
        // destructor cannot cancel a cancellation task.
        { auto reader = e->ctx_server.get_response_reader(); e->queue_tasks = &reader.queue_tasks; e->queue_results = &reader.queue_results; }
        const auto & meta = *e->meta;
        json unsupported = json::array();
        const std::unordered_set<std::string> supported = {"model_path", "backend", "require_backend", "result_retention_ms", "n_ctx", "n_batch", "n_ubatch", "n_threads", "n_threads_batch", "n_gpu_layers", "n_parallel", "cache_type_k", "cache_type_v", "swa_full", "flash_attn", "use_jinja", "chat_template", "reasoning_format"};
        for (auto it = config.begin(); it != config.end(); ++it) if (!supported.count(it.key())) unsupported.push_back(it.key());
        json devices = json::array();
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) devices.push_back(ggml_backend_dev_name(ggml_backend_dev_get(i)));
        json supports_reasoning = nullptr;
        try { if (meta.chat_params.tmpls) supports_reasoning = common_chat_templates_support_enable_thinking(meta.chat_params.tmpls.get()); }
        catch (...) {} // Report unknown when upstream cannot inspect the template.
        e->caps_cache = json({
            {"model_name", meta.model_name}, {"chat_template", meta.chat_params.tmpls ? "present" : ""},
            {"native_n_ctx", meta.model_n_ctx_train}, {"rope_extrapolation", false},
            {"task_state_observation", "streaming: upstream prompt progress and decode results; nonstream: sampled active/decoding metrics, prefill phase unavailable"},
            {"supports_tools", meta.chat_template_caps.count("supports_tools") && meta.chat_template_caps.at("supports_tools")},
            {"supports_parallel_tool_calls", meta.chat_template_caps.count("supports_parallel_tool_calls") && meta.chat_template_caps.at("supports_parallel_tool_calls")},
            {"supports_reasoning", supports_reasoning}, {"chat_template_caps", meta.chat_template_caps},
            {"supports_vision", false}, {"supports_audio", false}, {"requested", config}, {"unsupported", unsupported},
            {"effective", {{"n_ctx", llama_n_ctx(ctx)}, {"slot_n_ctx", meta.slot_n_ctx}, {"n_batch", llama_n_batch(ctx)},
                {"n_ubatch", llama_n_ubatch(ctx)}, {"n_threads", llama_n_threads(ctx)}, {"n_threads_batch", llama_n_threads_batch(ctx)},
                {"n_parallel", e->params.n_parallel}, {"cache_type_k", ggml_type_name(e->params.cache_type_k)},
                {"cache_type_v", ggml_type_name(e->params.cache_type_v)}, {"swa_full", e->params.swa_full},
                {"kv_unified", true}, {"context_shift", false}, {"flash_attn", nullptr}, {"n_gpu_layers", nullptr}}},
            {"result_retention_ms", e->result_retention_ms},
            {"available_devices", devices}, {"compiled_backends", compiled_backends}, {"device_info", device_info},
            {"selected_backend", selected_backend}, {"require_backend", require_backend}, {"degradation", degradation},
            {"backend", selected_backend == "cpu" ? json("cpu") : json(nullptr)}, {"device", nullptr},
            {"offload", selected_backend == "cpu" ? json(false) : json(nullptr)},
            {"diagnostic_limits", {"upstream public API does not expose actual flash attention, device placement, or offloaded layer count"}},
        }).dump();
        // A readiness barrier prevents terminate-before-start races if collector
        // thread allocation fails immediately after launching the loop.
        server_task ready(SERVER_TASK_TYPE_METRICS);
        ready.id = e->queue_tasks->get_new_id();
        const int ready_id = ready.id;
        e->queue_results->add_waiting_task_id(ready_id);
        e->queue_tasks->post(std::move(ready));
        e->running.store(true);
        e->loop_thread = std::thread([engine = e.get()]() noexcept {
            try { engine->ctx_server.start_loop(); }
            catch (...) { fail_engine(engine); }
        });
        while (e->running.load()) {
            auto result = e->queue_results->recv_with_timeout({ready_id}, 1);
            if (!result) continue;
            e->last_metrics = result->to_json();
            break;
        }
        e->queue_results->remove_waiting_task_id(ready_id);
        if (!e->running.load()) throw std::runtime_error("native processing loop failed to start");
        e->collector = std::thread(collect_results, e.get());
        return e.release();
    } catch (const std::bad_alloc &) { set_error(error_out, "engine allocation failed", "allocation"); }
    catch (const std::exception & ex) { set_error(error_out, ex.what(), phase); }
    catch (...) { set_error(error_out, "engine initialization failed", "backend"); }
    return nullptr;
}

void llcs_engine_destroy(llcs_engine * e) { try { delete e; } catch (...) {} }
char * llcs_engine_caps(const llcs_engine * e) { try { return heap_copy(e ? e->caps_cache : "{}"); } catch (...) { return nullptr; } }

char * llcs_engine_stats(const llcs_engine * e) {
    try {
        if (!e) return heap_copy("{}");
        std::lock_guard<std::mutex> lock(e->tasks_mtx);
        size_t active = 0, bytes = 0, count = 0;
        json tasks = json::array();
        for (const auto & item : e->task_map) {
            active += !item.second->finished; bytes += item.second->bytes; count += item.second->events.size();
            tasks.push_back({{"id", item.first}, {"state", item.second->phase}, {"prompt_progress", item.second->prompt_progress}});
        }
        return heap_copy(json({{"active_tasks", active}, {"retained_tasks", e->task_map.size()},
            {"tasks", tasks},
            {"pending_cancellations", e->cancellation_barriers.size()}, {"buffered_bytes", bytes}, {"buffered_events", count},
            {"expired_results", e->expired}, {"expiry_tombstones", e->expired_tasks.size()}, {"result_retention_ms", e->result_retention_ms},
            {"max_tasks", llcs_engine::max_tasks}, {"max_event_bytes_per_task", llcs_engine::max_event_bytes},
            {"collector_threads", e->collector.joinable() ? 1 : 0}, {"submitted", e->submitted},
            {"completed", e->completed}, {"cancelled", e->cancelled}, {"failed", e->failed}, {"running", e->running.load()},
            {"upstream_metrics", e->last_metrics}}).dump());
    } catch (...) { return nullptr; }
}

// Shared by preparation and submission, so budget measurement uses exactly the
// same upstream template, tokenizer, special tokens, and completion parameters.
static void validate_request_types(const json & body) {
    auto check = [&](const char * name, bool valid) {
        if (!valid) throw std::invalid_argument(std::string(name) + " has an invalid JSON type or range");
    };
    for (const char * name : {"stream", "ignore_eos", "cache_prompt", "return_tokens", "return_progress", "timings_per_token",
            "parallel_tool_calls", "logprobs", "backend_sampling", "post_sampling_probs", "enable_thinking",
            "add_generation_prompt", "continue_final_message", "skip_chat_parsing"}) {
        const auto it = body.find(name);
        if (it != body.end() && !it->is_null()) check(name, it->is_boolean());
    }
    for (const char * name : {"max_tokens", "max_completion_tokens", "n_predict", "n", "n_cmpl", "top_k", "top_logprobs",
            "repeat_last_n", "n_keep", "n_discard", "n_indent", "n_cache_reuse", "n_probs", "min_keep", "mirostat",
            "dry_allowed_length", "dry_penalty_last_n", "reasoning_budget", "thinking_budget_tokens", "seed"}) {
        const auto it = body.find(name);
        if (it == body.end() || it->is_null()) continue;
        check(name, it->is_number_integer());
        const int64_t maximum = std::strcmp(name, "seed") == 0 ? static_cast<int64_t>(UINT32_MAX) : INT32_MAX;
        if (it->is_number_unsigned()) check(name, it->get<uint64_t>() <= static_cast<uint64_t>(maximum));
        else check(name, it->get<int64_t>() >= INT32_MIN && it->get<int64_t>() <= maximum);
    }
    for (const char * name : {"temperature", "top_p", "min_p", "top_n_sigma", "typical_p", "xtc_probability", "xtc_threshold",
            "dynatemp_range", "dynatemp_exponent", "repeat_penalty", "frequency_penalty", "presence_penalty",
            "dry_multiplier", "dry_base", "mirostat_tau", "mirostat_eta", "adaptive_target", "adaptive_decay"}) {
        const auto it = body.find(name);
        if (it == body.end() || it->is_null()) continue;
        check(name, it->is_number());
        const double number = it->get<double>();
        check(name, std::isfinite(number) && std::fabs(number) <= std::numeric_limits<float>::max());
    }
    for (const char * name : {"stream_options", "response_format", "chat_template_kwargs", "logit_bias"}) {
        const auto it = body.find(name);
        if (it != body.end() && !it->is_null()) check(name, it->is_object());
    }
    for (const char * name : {"messages", "tools", "functions"}) {
        const auto it = body.find(name);
        if (it != body.end() && !it->is_null()) check(name, it->is_array());
    }
    if (body.contains("stream_options") && body.at("stream_options").is_object()) {
        const auto & options = body.at("stream_options");
        if (options.contains("include_usage") && !options.at("include_usage").is_null())
            check("stream_options.include_usage", options.at("include_usage").is_boolean());
    }
    if (body.contains("tool_choice") && !body.at("tool_choice").is_null())
        check("tool_choice", body.at("tool_choice").is_string() || body.at("tool_choice").is_object());
}

static server_task prepare_task(llcs_engine * e, const char * request) {
    if (std::strlen(request) > 16 * 1024 * 1024) throw std::invalid_argument("request exceeds 16 MiB");
    json body = json::parse(request);
    if (!body.is_object()) throw std::invalid_argument("request must be an object");
    validate_request_types(body);
    if (request_contains_media(body)) throw std::invalid_argument("unsupported_model_capability: server mode supports text only");
    std::vector<raw_buffer> files;
    json data = oaicompat_chat_params_parse(body, e->meta->chat_params, files);
    if (!files.empty()) throw std::invalid_argument("unsupported_model_capability: server mode supports text only");
    server_task task(SERVER_TASK_TYPE_COMPLETION);
    auto inputs = tokenize_input_prompts(e->vocab, nullptr, data.at("prompt"), true, true);
    if (inputs.size() != 1) throw std::invalid_argument("exactly one prompt is required");
    task.tokens = std::move(inputs.front());
    task.params = server_task::params_from_json_cmpl(e->vocab, e->params, e->meta->slot_n_ctx, e->meta->logit_bias_eog, data);
    if (task.params.n_predict <= 0) throw std::invalid_argument("max_tokens must be finite and positive");
    return task;
}

char * llcs_engine_prepare(llcs_engine * e, const char * request, char ** error_out) {
    if (error_out) *error_out = nullptr;
    try {
        if (!e || !request) throw std::invalid_argument("engine and request must not be NULL");
        std::lock_guard<std::mutex> lock(e->tasks_mtx);
        auto task = prepare_task(e, request);
        const int64_t prompt = task.n_tokens();
        const int64_t usable = static_cast<int64_t>(e->meta->slot_n_ctx) - 1;
        return heap_copy(json({{"prompt_tokens", prompt}, {"reserved_output_tokens", task.params.n_predict},
            {"effective_context", e->meta->slot_n_ctx}, {"usable_context", usable},
            {"fits", prompt + static_cast<int64_t>(task.params.n_predict) <= usable}}).dump());
    } catch (const std::bad_alloc &) { set_error(error_out, "preparation allocation failed", "allocation"); }
    catch (const std::exception & ex) { set_error(error_out, ex.what()); }
    catch (...) { set_error(error_out, "request preparation failed", "backend"); }
    return nullptr;
}

llcs_task_id llcs_engine_submit(llcs_engine * e, const char * request, char ** error_out) {
    if (error_out) *error_out = nullptr;
    try {
        if (!e || !request) throw std::invalid_argument("engine and request must not be NULL");
        std::lock_guard<std::mutex> lock(e->tasks_mtx);
        if (!e->running.load()) { set_error(error_out, "engine is closed", "backend"); return -1; }
        if (e->task_map.size() + e->cancellation_barriers.size() >= llcs_engine::max_tasks) {
            set_error(error_out, "task capacity reached; drain or cancel existing tasks", "allocation"); return -1;
        }
        auto task = prepare_task(e, request);
        task.id = e->queue_tasks->get_new_id();
        const int64_t prompt_tokens = task.n_tokens();
        const int64_t budget = prompt_tokens + static_cast<int64_t>(task.params.n_predict);
        // Upstream reserves the last context position while decoding.
        if (budget >= e->meta->slot_n_ctx) {
            if (error_out) *error_out = heap_copy(json({{"code", "context_overflow"}, {"type", "context_overflow"},
                {"message", "prompt plus requested output exceeds usable slot context"}, {"prompt_tokens", prompt_tokens},
                {"max_tokens", task.params.n_predict}, {"n_ctx", e->meta->slot_n_ctx}, {"reserved_tokens", 1}}).dump());
            return -1;
        }
        task.params.res_type = TASK_RESPONSE_TYPE_OAI_CHAT;
        task.params.oaicompat_cmpl_id = gen_chatcmplid();
        task.params.oaicompat_model = e->meta->model_name;
        task.index = 0;
        auto events = std::make_shared<llcs_task_events>();
        events->streaming = task.params.stream;
        events->emit_progress = task.params.return_progress;
        if (task.params.stream) task.params.return_progress = true;
        events->state = std::make_unique<task_result_state>(task.create_state());
        const int id = task.id;
        e->task_map.emplace(id, events);
        try {
            e->queue_results->add_waiting_task_id(id);
            e->queue_tasks->post(std::move(task));
        } catch (...) { e->queue_results->remove_waiting_task_id(id); e->task_map.erase(id); throw; }
        ++e->submitted;
        e->cv.notify_all();
        return id;
    } catch (const std::bad_alloc &) { set_error(error_out, "request allocation failed", "allocation"); }
    catch (const std::exception & ex) { set_error(error_out, ex.what()); }
    catch (...) { set_error(error_out, "request submission failed", "backend"); }
    return -1;
}

char * llcs_engine_poll(llcs_engine * e, llcs_task_id task, int32_t timeout_ms) {
    try {
        if (!e || task < 0 || task > INT32_MAX) return nullptr;
        std::unique_lock<std::mutex> lock(e->tasks_mtx);
        auto expired = std::find(e->expired_tasks.begin(), e->expired_tasks.end(), static_cast<int>(task));
        if (expired != e->expired_tasks.end()) {
            e->expired_tasks.erase(expired);
            return heap_copy(json({{"error", {{"code", "result_expired"}, {"type", "consumer_timeout"},
                {"message", "completed result retention expired before consumption"}, {"task_id", task}}}}).dump());
        }
        const auto it = e->task_map.find(static_cast<int>(task));
        if (it == e->task_map.end()) return nullptr;
        auto events = it->second;
        e->cv.wait_for(lock, std::chrono::milliseconds(std::max(0, timeout_ms)), [&] {
            return !events->events.empty() || events->finished || !e->running.load();
        });
        expired = std::find(e->expired_tasks.begin(), e->expired_tasks.end(), static_cast<int>(task));
        if (expired != e->expired_tasks.end()) {
            e->expired_tasks.erase(expired);
            return heap_copy(json({{"error", {{"code", "result_expired"}, {"type", "consumer_timeout"},
                {"message", "completed result retention expired before consumption"}, {"task_id", task}}}}).dump());
        }
        if (!events->events.empty()) {
            char * out = heap_copy(events->events.front());
            if (!out) return nullptr;
            events->bytes -= events->events.front().size();
            events->events.pop_front();
            if (events->finished && events->events.empty()) e->task_map.erase(static_cast<int>(task));
            return out;
        }
        if (events->finished || !e->running.load()) { e->task_map.erase(static_cast<int>(task)); return nullptr; }
        return heap_copy("");
    } catch (...) { return nullptr; }
}

void llcs_engine_cancel(llcs_engine * e, llcs_task_id task) {
    try {
        if (!e || task < 0 || task > INT32_MAX) return;
        std::lock_guard<std::mutex> lock(e->tasks_mtx);
        auto it = e->task_map.find(static_cast<int>(task));
        if (it == e->task_map.end()) return;
        if (!it->second->finished) {
            e->cancel_locked(static_cast<int>(task));
            ++e->cancelled;
        }
        it->second->finished = true;
        it->second->state.reset();
        it->second->events.clear();
        e->task_map.erase(it);
        e->cv.notify_all();
    } catch (...) {}
}

void llcs_string_free(char * str) { std::free(str); }

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
// remote images over HTTP. Server mode rejects media before that path until
// the in-process mtmd flow is complete.
// ---------------------------------------------------------------------------

#include "download.h"

std::pair<long, std::vector<char>> common_remote_get_content(
        const std::string & /* url */,
        const common_remote_params & /* params */) {
    // Return 501 Not Implemented — handle_media() will check the status
    // code and throw "Failed to download image"
    return {501, {}};
}
