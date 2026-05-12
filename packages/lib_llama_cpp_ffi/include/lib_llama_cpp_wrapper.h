#ifndef LIB_LLAMA_CPP_WRAPPER_H
#define LIB_LLAMA_CPP_WRAPPER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "llama.h"
#include "mtmd.h"

#if defined(_WIN32)
#define LIB_LLAMA_CPP_API __declspec(dllexport)
#else
#define LIB_LLAMA_CPP_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lib_llama_cpp_chat_templates lib_llama_cpp_chat_templates;
typedef struct lib_llama_cpp_media_context lib_llama_cpp_media_context;
typedef struct lib_llama_cpp_media_blob lib_llama_cpp_media_blob;

LIB_LLAMA_CPP_API int32_t lib_llama_cpp_abi_version(void);
LIB_LLAMA_CPP_API void lib_llama_cpp_string_free(char * value);

LIB_LLAMA_CPP_API lib_llama_cpp_chat_templates *
lib_llama_cpp_chat_templates_init(
    const struct llama_model * model,
    const char * chat_template_override,
    const char * bos_token_override,
    const char * eos_token_override,
    char ** error_json);

LIB_LLAMA_CPP_API void lib_llama_cpp_chat_templates_free(
    lib_llama_cpp_chat_templates * handle);

LIB_LLAMA_CPP_API char * lib_llama_cpp_chat_templates_apply_json(
    const lib_llama_cpp_chat_templates * handle,
    const char * request_json,
    char ** error_json);

LIB_LLAMA_CPP_API char * lib_llama_cpp_chat_parse_json(
    const char * parser_request_json,
    char ** error_json);

LIB_LLAMA_CPP_API lib_llama_cpp_media_context * lib_llama_cpp_media_init(
    const char * mmproj_path,
    const struct llama_model * model,
    const char * options_json,
    char ** error_json);

LIB_LLAMA_CPP_API void lib_llama_cpp_media_free(
    lib_llama_cpp_media_context * handle);

LIB_LLAMA_CPP_API bool lib_llama_cpp_media_supports_vision(
    const lib_llama_cpp_media_context * handle);

LIB_LLAMA_CPP_API bool lib_llama_cpp_media_supports_audio(
    const lib_llama_cpp_media_context * handle);

LIB_LLAMA_CPP_API lib_llama_cpp_media_blob *
lib_llama_cpp_media_blob_from_file(
    lib_llama_cpp_media_context * handle,
    const char * path,
    const char * id,
    char ** error_json);

LIB_LLAMA_CPP_API lib_llama_cpp_media_blob *
lib_llama_cpp_media_blob_from_encoded_bytes(
    lib_llama_cpp_media_context * handle,
    const unsigned char * bytes,
    size_t byte_count,
    const char * id,
    char ** error_json);

LIB_LLAMA_CPP_API void lib_llama_cpp_media_blob_free(
    lib_llama_cpp_media_blob * handle);

LIB_LLAMA_CPP_API int32_t lib_llama_cpp_media_eval_prompt(
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
    char ** error_json);

#ifdef __cplusplus
}
#endif

#endif
