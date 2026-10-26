#include "lib_llama_cpp_wrapper.h"

#include "chat.h"
#include "mtmd-helper.h"
#include "nlohmann/json.hpp"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using json = nlohmann::ordered_json;

#ifdef __ANDROID__
__attribute__((constructor)) static void llcpp_android_vulkan_init() {
    setenv("GGML_VK_DISABLE_COOPMAT2", "1", 1);
}
#endif


struct lib_llama_cpp_chat_templates {
    explicit lib_llama_cpp_chat_templates(common_chat_templates_ptr value)
        : templates(std::move(value)) {}

    common_chat_templates_ptr templates;
};

struct lib_llama_cpp_media_context {
    explicit lib_llama_cpp_media_context(mtmd_context * value)
        : context(value) {}

    mtmd_context * context;
    int64_t last_prompt_tokens = 0;
};

struct lib_llama_cpp_media_blob {
    explicit lib_llama_cpp_media_blob(mtmd_bitmap * value)
        : bitmap(value) {}

    mtmd_bitmap * bitmap;
};

static char * llcpp_copy_string(const std::string & value) {
    char * result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result == nullptr) {
        return nullptr;
    }
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

static const char * llcpp_cstr_or_empty(const char * value) {
    return value == nullptr ? "" : value;
}

static json llcpp_error_json(const std::string & code, const std::string & message) {
    return json{
        {"code", code},
        {"type", code},
        {"message", message},
    };
}

static void llcpp_set_error(char ** error_json, const char * code, const char * message) noexcept {
    if (error_json == nullptr) {
        return;
    }
    try {
        *error_json = llcpp_copy_string(llcpp_error_json(code, message).dump());
    } catch (...) {
        static const char fallback[] = "{\"code\":\"allocation\",\"type\":\"allocation\",\"message\":\"error allocation failed\"}";
        *error_json = static_cast<char *>(std::malloc(sizeof(fallback)));
        if (*error_json) std::memcpy(*error_json, fallback, sizeof(fallback));
    }
}

static void llcpp_set_error(char ** out, const char * code, const std::string & message) noexcept {
    llcpp_set_error(out, code, message.c_str());
}

static void llcpp_exception(char ** out, const std::exception & error, const char * fallback = "backend") noexcept {
    const char * code = dynamic_cast<const std::bad_alloc *>(&error) ? "allocation" :
        (dynamic_cast<const std::invalid_argument *>(&error) || dynamic_cast<const json::exception *>(&error)) ? "invalid_request" : fallback;
    llcpp_set_error(out, code, error.what());
}

static json llcpp_parse_json_object(const char * value, const char * argument_name) {
    if (value == nullptr) {
        throw std::invalid_argument(std::string(argument_name) + " must not be null");
    }
    json parsed = json::parse(value);
    if (!parsed.is_object()) {
        throw std::invalid_argument(std::string(argument_name) + " must be a JSON object");
    }
    return parsed;
}

static common_chat_format llcpp_chat_format_from_name(const std::string & name) {
    if (name == "Content-only" || name == "content-only") {
        return COMMON_CHAT_FORMAT_CONTENT_ONLY;
    }
    if (name == "peg-simple") {
        return COMMON_CHAT_FORMAT_PEG_SIMPLE;
    }
    if (name == "peg-native") {
        return COMMON_CHAT_FORMAT_PEG_NATIVE;
    }
    if (name == "peg-gemma4") {
        return COMMON_CHAT_FORMAT_PEG_GEMMA4;
    }
    throw std::invalid_argument("Unknown chat format: " + name);
}

static std::string llcpp_grammar_trigger_type_name(common_grammar_trigger_type type) {
    switch (type) {
        case COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN:
            return "token";
        case COMMON_GRAMMAR_TRIGGER_TYPE_WORD:
            return "word";
        case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN:
            return "pattern";
        case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN_FULL:
            return "pattern_full";
    }
    return "unknown";
}

static common_chat_tool_choice llcpp_tool_choice_from_json(const json & request) {
    if (!request.contains("tool_choice") || request.at("tool_choice").is_null()) {
        return COMMON_CHAT_TOOL_CHOICE_AUTO;
    }

    const json & tool_choice = request.at("tool_choice");
    if (tool_choice.is_string()) {
        return common_chat_tool_choice_parse_oaicompat(tool_choice.get<std::string>());
    }

    if (tool_choice.is_object()) {
        const std::string type = tool_choice.value("type", "");
        if (type == "function") {
            return COMMON_CHAT_TOOL_CHOICE_REQUIRED;
        }
    }

    throw std::invalid_argument("Unsupported tool_choice: " + tool_choice.dump());
}

static void llcpp_apply_optional_inputs(common_chat_templates_inputs & inputs, const json & request) {
    inputs.add_generation_prompt = request.value("add_generation_prompt", inputs.add_generation_prompt);
    inputs.use_jinja = request.value("use_jinja", inputs.use_jinja);
    inputs.parallel_tool_calls = request.value("parallel_tool_calls", inputs.parallel_tool_calls);
    inputs.enable_thinking = request.value("enable_thinking", inputs.enable_thinking);
    inputs.add_bos = request.value("add_bos", inputs.add_bos);
    inputs.add_eos = request.value("add_eos", inputs.add_eos);
    inputs.force_pure_content = request.value("force_pure_content", inputs.force_pure_content);
    inputs.grammar = request.value("grammar", inputs.grammar);
    inputs.json_schema = request.value("json_schema", inputs.json_schema);

    if (request.contains("reasoning_format") && request.at("reasoning_format").is_string()) {
        inputs.reasoning_format =
            common_reasoning_format_from_name(request.at("reasoning_format").get<std::string>());
    }

    if (request.contains("chat_template_kwargs") && request.at("chat_template_kwargs").is_object()) {
        for (const auto & item : request.at("chat_template_kwargs").items()) {
            if (item.value().is_string()) {
                inputs.chat_template_kwargs[item.key()] = item.value();
            }
        }
    }
}

extern "C" {

int32_t lib_llama_cpp_abi_version(void) {
    return 1;
}

void lib_llama_cpp_string_free(char * value) {
    std::free(value);
}

lib_llama_cpp_chat_templates * lib_llama_cpp_chat_templates_init(
    const struct llama_model * model,
    const char * chat_template_override,
    const char * bos_token_override,
    const char * eos_token_override,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        auto templates = common_chat_templates_init(
            model,
            llcpp_cstr_or_empty(chat_template_override),
            llcpp_cstr_or_empty(bos_token_override),
            llcpp_cstr_or_empty(eos_token_override));
        if (!templates) {
            throw std::runtime_error("llama.cpp did not return chat templates");
        }
        return new lib_llama_cpp_chat_templates(std::move(templates));
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "chat template initialization failed");
        return nullptr;
    }
}

void lib_llama_cpp_chat_templates_free(lib_llama_cpp_chat_templates * handle) {
    try { delete handle; } catch (...) {}
}

char * lib_llama_cpp_chat_templates_caps_json(
    const lib_llama_cpp_chat_templates * handle,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        if (!handle || !handle->templates) throw std::invalid_argument("chat template handle must not be null");
        json caps = common_chat_templates_get_caps(handle->templates.get());
        caps["supports_reasoning"] = nullptr;
        try { caps["supports_reasoning"] = common_chat_templates_support_enable_thinking(handle->templates.get()); }
        catch (...) {} // An unavailable reasoning probe must not imply support.
        return llcpp_copy_string(caps.dump());
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
    } catch (...) {
        llcpp_set_error(error_json, "backend", "chat template capability inspection failed");
    }
    return nullptr;
}

char * lib_llama_cpp_chat_templates_apply_json(
    const lib_llama_cpp_chat_templates * handle,
    const char * request_json,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        if (handle == nullptr || !handle->templates) {
            throw std::invalid_argument("chat template handle must not be null");
        }

        const json request = llcpp_parse_json_object(request_json, "request_json");
        if (!request.contains("messages")) {
            throw std::invalid_argument("request_json is missing messages");
        }

        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(request.at("messages"));
        if (request.contains("tools") && !request.at("tools").is_null()) {
            inputs.tools = common_chat_tools_parse_oaicompat(request.at("tools"));
        }
        inputs.tool_choice = llcpp_tool_choice_from_json(request);
        llcpp_apply_optional_inputs(inputs, request);

        const common_chat_params params =
            common_chat_templates_apply(handle->templates.get(), inputs);

        json output = {
            {"prompt", params.prompt},
            {"grammar", params.grammar},
            {"grammar_lazy", params.grammar_lazy},
            {"generation_prompt", params.generation_prompt},
            {"format", common_chat_format_name(params.format)},
            {"parser", params.parser},
            {"supports_thinking", params.supports_thinking},
            {"thinking_start_tag", params.thinking_start_tag},
            {"thinking_end_tag", params.thinking_end_tag},
            {"grammar_triggers", json::array()},
            {"additional_stops", params.additional_stops},
            {"preserved_tokens", params.preserved_tokens},
            {"caps", common_chat_templates_get_caps(handle->templates.get())},
        };
        for (const auto & trigger : params.grammar_triggers) {
            output["grammar_triggers"].push_back({
                {"type", llcpp_grammar_trigger_type_name(trigger.type)},
                {"value", trigger.value},
                {"token", trigger.token},
            });
        }

        return llcpp_copy_string(output.dump());
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error, "invalid_request");
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "chat template application failed");
        return nullptr;
    }
}

char * lib_llama_cpp_chat_parse_json(
    const char * parser_request_json,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        const json request = llcpp_parse_json_object(parser_request_json, "parser_request_json");

        common_chat_parser_params params;
        params.format = llcpp_chat_format_from_name(request.value("format", "content-only"));
        params.generation_prompt = request.value("generation_prompt", "");
        params.parse_tool_calls = request.value("parse_tool_calls", true);
        params.reasoning_in_content = request.value("reasoning_in_content", false);
        params.debug = request.value("debug", false);

        if (request.contains("reasoning_format") && request.at("reasoning_format").is_string()) {
            params.reasoning_format =
                common_reasoning_format_from_name(request.at("reasoning_format").get<std::string>());
        }

        const std::string parser = request.value("parser", "");
        if (!parser.empty()) {
            params.parser.load(parser);
        }

        const std::string text = request.value("text", "");
        const bool is_partial = request.value("is_partial", false);
        const common_chat_msg message = common_chat_parse(text, is_partial, params);
        json output = {
            {"message", message.to_json_oaicompat(false)},
        };
        return llcpp_copy_string(output.dump());
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error, "invalid_request");
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "chat parsing failed");
        return nullptr;
    }
}

lib_llama_cpp_media_context * lib_llama_cpp_media_init(
    const char * mmproj_path,
    const struct llama_model * model,
    const char * options_json,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        if (mmproj_path == nullptr || std::strlen(mmproj_path) == 0) {
            throw std::invalid_argument("mmproj_path must not be empty");
        }
        if (!model) throw std::invalid_argument("model must not be null");

        mtmd_context_params params = mtmd_context_params_default();
        std::string media_marker;
        if (options_json != nullptr && std::strlen(options_json) > 0) {
            const json options = llcpp_parse_json_object(options_json, "options_json");
            params.use_gpu = options.value("use_gpu", params.use_gpu);
            params.n_threads = options.value("n_threads", params.n_threads);
            params.print_timings = options.value("print_timings", params.print_timings);
            params.warmup = options.value("warmup", params.warmup);
            params.image_min_tokens = options.value("image_min_tokens", params.image_min_tokens);
            params.image_max_tokens = options.value("image_max_tokens", params.image_max_tokens);
            if (options.contains("media_marker") && options.at("media_marker").is_string()) {
                media_marker = options.at("media_marker").get<std::string>();
                params.media_marker = media_marker.c_str();
            }
        }
        if (params.n_threads <= 0) throw std::invalid_argument("media n_threads must be positive");
        if (params.image_min_tokens < -1 || params.image_max_tokens < -1 ||
            (params.image_min_tokens > 0 && params.image_max_tokens > 0 && params.image_min_tokens > params.image_max_tokens))
            throw std::invalid_argument("invalid media image token bounds");

        std::unique_ptr<mtmd_context, decltype(&mtmd_free)> context(mtmd_init_from_file(mmproj_path, model, params), mtmd_free);
        if (!context) {
            throw std::runtime_error("llama.cpp did not return an mtmd context");
        }
        auto * result = new lib_llama_cpp_media_context(context.get());
        context.release();
        return result;
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "media initialization failed");
        return nullptr;
    }
}

void lib_llama_cpp_media_free(lib_llama_cpp_media_context * handle) {
    try {
    if (handle != nullptr) {
        mtmd_free(handle->context);
    }
    delete handle;
    } catch (...) {}
}

bool lib_llama_cpp_media_supports_vision(const lib_llama_cpp_media_context * handle) {
    try { return handle != nullptr && mtmd_support_vision(handle->context); } catch (...) { return false; }
}

bool lib_llama_cpp_media_supports_audio(const lib_llama_cpp_media_context * handle) {
    try { return handle != nullptr && mtmd_support_audio(handle->context); } catch (...) { return false; }
}

int64_t lib_llama_cpp_media_last_prompt_tokens(const lib_llama_cpp_media_context * handle) {
    try { return handle ? handle->last_prompt_tokens : 0; } catch (...) { return 0; }
}

lib_llama_cpp_media_blob * lib_llama_cpp_media_blob_from_file(
    lib_llama_cpp_media_context * handle,
    const char * path,
    const char * id,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        if (handle == nullptr) {
            throw std::invalid_argument("media handle must not be null");
        }
        if (path == nullptr || std::strlen(path) == 0) {
            throw std::invalid_argument("path must not be empty");
        }
        std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(mtmd_helper_bitmap_init_from_file(handle->context, path), mtmd_bitmap_free);
        if (!bitmap) {
            throw std::runtime_error("failed to decode media file");
        }
        if (id != nullptr) {
            mtmd_bitmap_set_id(bitmap.get(), id);
        }
        auto * result = new lib_llama_cpp_media_blob(bitmap.get());
        bitmap.release();
        return result;
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "media file decoding failed");
        return nullptr;
    }
}

lib_llama_cpp_media_blob * lib_llama_cpp_media_blob_from_encoded_bytes(
    lib_llama_cpp_media_context * handle,
    const unsigned char * bytes,
    size_t byte_count,
    const char * id,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    try {
        if (handle == nullptr) {
            throw std::invalid_argument("media handle must not be null");
        }
        if (bytes == nullptr || byte_count == 0) {
            throw std::invalid_argument("bytes must not be empty");
        }
        std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(mtmd_helper_bitmap_init_from_buf(handle->context, bytes, byte_count), mtmd_bitmap_free);
        if (!bitmap) {
            throw std::runtime_error("failed to decode encoded media bytes");
        }
        if (id != nullptr) {
            mtmd_bitmap_set_id(bitmap.get(), id);
        }
        auto * result = new lib_llama_cpp_media_blob(bitmap.get());
        bitmap.release();
        return result;
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
        return nullptr;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "encoded media decoding failed");
        return nullptr;
    }
}

void lib_llama_cpp_media_blob_free(lib_llama_cpp_media_blob * handle) {
    try {
    if (handle != nullptr) {
        mtmd_bitmap_free(handle->bitmap);
    }
    delete handle;
    } catch (...) {}
}

int32_t lib_llama_cpp_media_eval_prompt(
    lib_llama_cpp_media_context * media,
    struct llama_context * llama,
    const char * prompt,
    const lib_llama_cpp_media_blob * const * blobs,
    size_t blob_count,
    int32_t n_past,
    int32_t seq_id,
    int32_t n_batch,
    bool logits_last,
    bool add_special,
    bool parse_special,
    int32_t * new_n_past,
    char ** error_json) {
    return lib_llama_cpp_media_eval_prompt_with_budget(media, llama, prompt, blobs,
        blob_count, n_past, seq_id, n_batch, logits_last, add_special,
        parse_special, 0, new_n_past, error_json);
}

int32_t lib_llama_cpp_media_eval_prompt_with_budget(
    lib_llama_cpp_media_context * media,
    struct llama_context * llama,
    const char * prompt,
    const lib_llama_cpp_media_blob * const * blobs,
    size_t blob_count,
    int32_t n_past,
    int32_t seq_id,
    int32_t n_batch,
    bool logits_last,
    bool add_special,
    bool parse_special,
    int32_t reserved_output_tokens,
    int32_t * new_n_past,
    char ** error_json) {
    if (error_json) *error_json = nullptr;
    if (new_n_past) *new_n_past = n_past;
    try {
        if (media == nullptr) {
            throw std::invalid_argument("media handle must not be null");
        }
        if (llama == nullptr) {
            throw std::invalid_argument("llama context must not be null");
        }
        if (prompt == nullptr) {
            throw std::invalid_argument("prompt must not be null");
        }
        if (blob_count > 0 && blobs == nullptr) {
            throw std::invalid_argument("blobs must not be null when blob_count is non-zero");
        }
        if (n_past < 0 || seq_id < 0 || n_batch <= 0 || reserved_output_tokens < 0)
            throw std::invalid_argument("positions, sequence, and output budget must be nonnegative; batch must be positive");
        if (static_cast<uint32_t>(seq_id) >= llama_n_seq_max(llama))
            throw std::invalid_argument("sequence id exceeds configured sequence count");
        if (static_cast<uint32_t>(n_batch) > llama_n_batch(llama))
            throw std::invalid_argument("media batch exceeds configured llama batch size");

        std::vector<const mtmd_bitmap *> bitmaps;
        bitmaps.reserve(blob_count);
        for (size_t i = 0; i < blob_count; i += 1) {
            if (blobs[i] == nullptr || blobs[i]->bitmap == nullptr) {
                throw std::invalid_argument("media blob must not be null");
            }
            bitmaps.push_back(blobs[i]->bitmap);
        }

        std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(
            mtmd_input_chunks_init(),
            mtmd_input_chunks_free);
        if (!chunks) {
            throw std::runtime_error("failed to allocate mtmd input chunks");
        }

        mtmd_input_text text = {
            prompt,
            add_special,
            parse_special,
        };

        const int32_t tokenize_result = mtmd_tokenize(
            media->context,
            chunks.get(),
            &text,
            bitmaps.data(),
            bitmaps.size());
        if (tokenize_result != 0) {
            llcpp_set_error(
                error_json,
                "invalid_request",
                "mtmd_tokenize failed with code " + std::to_string(tokenize_result));
            return tokenize_result;
        }

        const int64_t positions = mtmd_helper_get_n_pos(chunks.get());
        const uint64_t tokens = mtmd_helper_get_n_tokens(chunks.get());
        media->last_prompt_tokens = tokens > static_cast<uint64_t>(INT64_MAX) ? INT64_MAX : static_cast<int64_t>(tokens);
        const int64_t context = llama_n_ctx_seq(llama);
        // Count both storage tokens and positional coordinates: M-RoPE image
        // chunks can have different counts. Never evaluate a truncated prompt.
        if (positions < 0 || tokens > static_cast<uint64_t>(INT32_MAX) ||
            static_cast<int64_t>(n_past) + positions >= context ||
            static_cast<int64_t>(n_past) + positions + reserved_output_tokens > context ||
            static_cast<uint64_t>(n_past) + tokens + static_cast<uint64_t>(reserved_output_tokens) > static_cast<uint64_t>(context)) {
            if (error_json) *error_json = llcpp_copy_string(json({
                {"code", "context_overflow"}, {"type", "context_overflow"},
                {"message", "media prompt plus requested output exceeds context"},
                {"prompt_tokens", tokens}, {"prompt_positions", positions}, {"n_past", n_past},
                {"max_tokens", reserved_output_tokens}, {"n_ctx", context}}).dump());
            return -1;
        }

        llama_pos updated_n_past = n_past;
        const int32_t eval_result = mtmd_helper_eval_chunks(
            media->context,
            llama,
            chunks.get(),
            static_cast<llama_pos>(n_past),
            static_cast<llama_seq_id>(seq_id),
            n_batch,
            logits_last,
            &updated_n_past);
        if (new_n_past != nullptr) {
            *new_n_past = static_cast<int32_t>(updated_n_past);
        }
        if (eval_result != 0) {
            llcpp_set_error(
                error_json,
                eval_result == 2 ? "cancelled" : "backend",
                "mtmd_helper_eval_chunks failed with code " + std::to_string(eval_result));
        }
        return eval_result;
    } catch (const std::exception & error) {
        llcpp_exception(error_json, error);
        return -1;
    } catch (...) {
        llcpp_set_error(error_json, "backend", "media evaluation failed");
        return -1;
    }
}

} // extern "C"
