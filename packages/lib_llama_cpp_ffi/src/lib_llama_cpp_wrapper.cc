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

struct lib_llama_cpp_chat_templates {
    explicit lib_llama_cpp_chat_templates(common_chat_templates_ptr value)
        : templates(std::move(value)) {}

    common_chat_templates_ptr templates;
};

struct lib_llama_cpp_media_context {
    explicit lib_llama_cpp_media_context(mtmd_context * value)
        : context(value) {}

    mtmd_context * context;
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
        {"message", message},
    };
}

static void llcpp_set_error(char ** error_json, const std::string & code, const std::string & message) {
    if (error_json == nullptr) {
        return;
    }
    *error_json = llcpp_copy_string(llcpp_error_json(code, message).dump());
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
        llcpp_set_error(error_json, "chat_template_init_failed", error.what());
        return nullptr;
    }
}

void lib_llama_cpp_chat_templates_free(lib_llama_cpp_chat_templates * handle) {
    delete handle;
}

char * lib_llama_cpp_chat_templates_apply_json(
    const lib_llama_cpp_chat_templates * handle,
    const char * request_json,
    char ** error_json) {
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
        llcpp_set_error(error_json, "chat_template_apply_failed", error.what());
        return nullptr;
    }
}

char * lib_llama_cpp_chat_parse_json(
    const char * parser_request_json,
    char ** error_json) {
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
        llcpp_set_error(error_json, "chat_parse_failed", error.what());
        return nullptr;
    }
}

lib_llama_cpp_media_context * lib_llama_cpp_media_init(
    const char * mmproj_path,
    const struct llama_model * model,
    const char * options_json,
    char ** error_json) {
    try {
        if (mmproj_path == nullptr || std::strlen(mmproj_path) == 0) {
            throw std::invalid_argument("mmproj_path must not be empty");
        }

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

        mtmd_context * context = mtmd_init_from_file(mmproj_path, model, params);
        if (context == nullptr) {
            throw std::runtime_error("llama.cpp did not return an mtmd context");
        }
        return new lib_llama_cpp_media_context(context);
    } catch (const std::exception & error) {
        llcpp_set_error(error_json, "media_init_failed", error.what());
        return nullptr;
    }
}

void lib_llama_cpp_media_free(lib_llama_cpp_media_context * handle) {
    if (handle != nullptr) {
        mtmd_free(handle->context);
    }
    delete handle;
}

bool lib_llama_cpp_media_supports_vision(const lib_llama_cpp_media_context * handle) {
    return handle != nullptr && mtmd_support_vision(handle->context);
}

bool lib_llama_cpp_media_supports_audio(const lib_llama_cpp_media_context * handle) {
    return handle != nullptr && mtmd_support_audio(handle->context);
}

lib_llama_cpp_media_blob * lib_llama_cpp_media_blob_from_file(
    lib_llama_cpp_media_context * handle,
    const char * path,
    const char * id,
    char ** error_json) {
    try {
        if (handle == nullptr) {
            throw std::invalid_argument("media handle must not be null");
        }
        if (path == nullptr || std::strlen(path) == 0) {
            throw std::invalid_argument("path must not be empty");
        }
        mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_file(handle->context, path);
        if (bitmap == nullptr) {
            throw std::runtime_error("failed to decode media file");
        }
        if (id != nullptr) {
            mtmd_bitmap_set_id(bitmap, id);
        }
        return new lib_llama_cpp_media_blob(bitmap);
    } catch (const std::exception & error) {
        llcpp_set_error(error_json, "media_blob_decode_failed", error.what());
        return nullptr;
    }
}

lib_llama_cpp_media_blob * lib_llama_cpp_media_blob_from_encoded_bytes(
    lib_llama_cpp_media_context * handle,
    const unsigned char * bytes,
    size_t byte_count,
    const char * id,
    char ** error_json) {
    try {
        if (handle == nullptr) {
            throw std::invalid_argument("media handle must not be null");
        }
        if (bytes == nullptr || byte_count == 0) {
            throw std::invalid_argument("bytes must not be empty");
        }
        mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_buf(handle->context, bytes, byte_count);
        if (bitmap == nullptr) {
            throw std::runtime_error("failed to decode encoded media bytes");
        }
        if (id != nullptr) {
            mtmd_bitmap_set_id(bitmap, id);
        }
        return new lib_llama_cpp_media_blob(bitmap);
    } catch (const std::exception & error) {
        llcpp_set_error(error_json, "media_blob_decode_failed", error.what());
        return nullptr;
    }
}

void lib_llama_cpp_media_blob_free(lib_llama_cpp_media_blob * handle) {
    if (handle != nullptr) {
        mtmd_bitmap_free(handle->bitmap);
    }
    delete handle;
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
                "media_tokenize_failed",
                "mtmd_tokenize failed with code " + std::to_string(tokenize_result));
            return tokenize_result;
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
                "media_eval_failed",
                "mtmd_helper_eval_chunks failed with code " + std::to_string(eval_result));
        }
        return eval_result;
    } catch (const std::exception & error) {
        llcpp_set_error(error_json, "media_eval_failed", error.what());
        return -1;
    }
}

} // extern "C"
