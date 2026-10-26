// Real-model subprocess diagnostic; --duplicate replays the former Dart bug.
#include "lib_llama_cpp_wrapper.h"
#include <cstdio>
#include <cstring>
#include <vector>
extern "C" int llcs_backend_acquire(char **);
extern "C" void llcs_backend_release();
int main(int argc, char ** argv) {
    if (argc < 2) return 2;
    const bool safe = argc > 2 && std::strcmp(argv[2], "--safe") == 0;
    char * error = nullptr;
    if (llcs_backend_acquire(&error) != 0) return 3;
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    auto * model = safe ? lib_llama_cpp_model_load_safe(argv[1], mp, &error) : llama_model_load_from_file(argv[1], mp);
    if (!model) return 4;
    auto cp = llama_context_default_params();
    cp.n_ctx = 512; cp.n_batch = 32; cp.n_ubatch = 32;
    cp.n_threads = 2; cp.n_threads_batch = 2;
    auto * context = safe ? lib_llama_cpp_context_create_safe(model, cp, &error) : llama_init_from_model(model, cp);
    if (!context) return 5;
    const auto * vocab = llama_model_get_vocab(model);
    std::vector<llama_token> prompt(16);
    int count = 0;
    if (safe) {
        if (lib_llama_cpp_tokenize_safe(vocab, "Hello", 5, prompt.data(), prompt.size(), true, true, &count, &error) != 0) return 6;
    } else {
        count = llama_tokenize(vocab, "Hello", 5, prompt.data(), prompt.size(), true, true);
    }
    if (count <= 0) return 6;
    const auto batch = llama_batch_get_one(prompt.data(), count);
    int decoded = 0;
    if (safe) {
        if (lib_llama_cpp_decode_safe(context, batch, &decoded, &error) != 0) return 7;
    } else {
        decoded = llama_decode(context, batch);
    }
    if (decoded != 0) return 7;
    llama_sampler * sampler = nullptr;
    llama_token token = LLAMA_TOKEN_NULL;
    if (safe) {
        sampler = lib_llama_cpp_sampler_create_safe(vocab, R"({"grammar":"root ::= \"a\""})", &error);
        if (!sampler || lib_llama_cpp_sampler_sample_safe(sampler, context, -1, &token, &error) != 0) return 8;
    } else {
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, "root ::= \"a\"", "root"));
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
        token = llama_sampler_sample(sampler, context, -1);
    }
    std::fprintf(stderr, "sample accepted token=%d; now %s\n", token, !safe && argc > 2 ? "duplicate accept" : "cleanup");
    if (!safe && argc > 2) llama_sampler_accept(sampler, token);
    if (safe) lib_llama_cpp_sampler_free_safe(sampler);
    else llama_sampler_free(sampler);
    llama_free(context);
    llama_model_free(model);
    llcs_backend_release();
    return 0;
}
