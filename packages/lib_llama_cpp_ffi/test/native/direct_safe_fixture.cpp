// Uses the real upstream sampler + grammar code with a one-token vocabulary.
// Native work/model IO are stubbed so ABI faults are deterministic and bounded.
#include "lib_llama_cpp_wrapper.h"
#include "llama-vocab.h"
#include "llama-impl.h"
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <stdexcept>
#include <string>

static int fault = 0;
static bool allocation_fault = false;
static long live_allocations = 0;
void * operator new(std::size_t size) {
    if (allocation_fault) { allocation_fault = false; throw std::bad_alloc(); }
    if (void * pointer = std::malloc(size ? size : 1)) { ++live_allocations; return pointer; }
    throw std::bad_alloc();
}
void operator delete(void * pointer) noexcept {
    if (pointer) --live_allocations;
    std::free(pointer);
}
void operator delete(void * pointer, std::size_t) noexcept { ::operator delete(pointer); }
extern "C" void direct_test_allocation_fault() { allocation_fault = true; }
extern "C" long direct_test_live_allocations() { return live_allocations; }
extern "C" void direct_test_chain_add(llama_sampler * chain, llama_sampler * child) {
    if (fault == 4) { fault = 0; allocation_fault = true; }
    llama_sampler_chain_add(chain, child);
}
static const llama_vocab * vocab = reinterpret_cast<const llama_vocab *>(0x1000);
static llama_model * model = reinterpret_cast<llama_model *>(0x2000);
static llama_context * context = reinterpret_cast<llama_context *>(0x3000);
static void maybe_throw() {
    const int value = fault;
    fault = 0;
    if (value == 1) throw std::bad_alloc();
    if (value == 2) throw std::runtime_error("injected backend failure");
    if (value == 3) throw 17;
}
extern "C" void direct_test_fault(int value) { fault = value; }
time_meas::time_meas(int64_t & accumulator, bool) : t_start_us(0), t_acc(accumulator) {}
time_meas::~time_meas() {}
void llama_log_internal(ggml_log_level, const char *, ...) {}
uint32_t llama_vocab::n_tokens() const { return 1; }
bool llama_vocab::is_eog(llama_token) const { return false; }
const std::string & llama_vocab::token_to_piece(llama_token) const {
    maybe_throw();
    static const std::string piece = "a";
    return piece;
}
extern "C" {
[[noreturn]] void ggml_abort(const char *, int, const char *, ...) { std::abort(); }
int64_t ggml_time_us() { return 0; }
const llama_model * llama_get_model(const llama_context *) { return model; }
const llama_vocab * llama_model_get_vocab(const llama_model *) { return vocab; }
int32_t llama_vocab_n_tokens(const llama_vocab *) { return 1; }
llama_token llama_get_sampled_token_ith(llama_context *, int32_t) { return LLAMA_TOKEN_NULL; }
float * llama_get_sampled_probs_ith(llama_context *, int32_t) { return nullptr; }
float * llama_get_sampled_logits_ith(llama_context *, int32_t) { return nullptr; }
llama_token * llama_get_sampled_candidates_ith(llama_context *, int32_t) { return nullptr; }
float * llama_get_logits_ith(llama_context *, int32_t) { maybe_throw(); static float logits[] = {0}; return logits; }
llama_sampler_chain_params llama_sampler_chain_default_params() { return {true}; }
llama_model * llama_model_load_from_file(const char *, llama_model_params) { maybe_throw(); return model; }
llama_context * llama_init_from_model(llama_model *, llama_context_params) { maybe_throw(); return context; }
int32_t llama_tokenize(const llama_vocab *, const char *, int32_t, llama_token * tokens, int32_t capacity, bool, bool) {
    maybe_throw(); if (!capacity) return -1; tokens[0] = 0; return 1;
}
int32_t llama_decode(llama_context *, llama_batch) { maybe_throw(); return 0; }
int32_t llama_token_to_piece(const llama_vocab *, llama_token, char * out, int32_t capacity, int32_t, bool) {
    maybe_throw(); if (!capacity) return -1; out[0] = 'a'; return 1;
}
void direct_test_duplicate_accept() {
    auto * chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    auto * grammar = llama_sampler_init_grammar(vocab, "root ::= \"a\"", "root");
    llama_sampler_chain_add(chain, grammar);
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    const auto token = llama_sampler_sample(chain, context, -1);
    // Replays the erroneous extra accept in the Dart direct runtime.
    llama_sampler_accept(chain, token);
    llama_sampler_free(chain);
}
}

extern "C" int direct_test_safe_operation(int operation, int kind, char ** error) {
    int32_t result = -999;
    llama_token token = -999;
    char text[8] = {};
    llama_token tokens[8] = {};
    llama_sampler * sampler = nullptr;
    if (operation >= 6) {
        sampler = lib_llama_cpp_sampler_create_safe(vocab, "{\"grammar\":\"root ::= \\\"a\\\"\"}", error);
        if (!sampler) return -2;
    }
    fault = kind;
    int status = -1;
    switch (operation) {
        case 0: status = lib_llama_cpp_model_load_safe("valid.gguf", {}, error) ? 0 : -1; break;
        case 1: status = lib_llama_cpp_context_create_safe(model, {}, error) ? 0 : -1; break;
        case 2: status = lib_llama_cpp_tokenize_safe(vocab, "a", 1, tokens, 8, false, false, &result, error); break;
        case 3: status = lib_llama_cpp_decode_safe(context, {}, &result, error); break;
        case 4: status = lib_llama_cpp_token_to_piece_safe(vocab, 0, text, 8, 0, false, &result, error); break;
        case 5:
            if (kind == 1) { fault = 0; allocation_fault = true; }
            sampler = lib_llama_cpp_sampler_create_safe(vocab, "{}", error);
            status = sampler ? 0 : -1;
            break;
        case 6:
            if (kind == 1) { fault = 0; allocation_fault = true; }
            status = lib_llama_cpp_sampler_sample_safe(sampler, context, -1, &token, error);
            break;
        case 7: status = lib_llama_cpp_sampler_accept_safe(sampler, 0, error); break;
    }
    fault = 0;
    lib_llama_cpp_sampler_free_safe(sampler);
    return status;
}
