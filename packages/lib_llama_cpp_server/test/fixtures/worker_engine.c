// Native timing fixture: validates real isolate/FFI ownership without a model.
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct engine { int next; int stage; int cancelled; };
static char * copy(const char * value) { return strdup(value); }
int lib_llama_cpp_abi_version(void) { return 1; }
void lib_llama_cpp_chat_templates_apply_json(void) {}
void lib_llama_cpp_chat_templates_caps_json(void) {}
void lib_llama_cpp_media_eval_prompt_with_budget(void) {}
void lib_llama_cpp_media_last_prompt_tokens(void) {}
void llcs_backend_acquire(void) {}
void llcs_backend_release(void) {}
void llcs_cancel_create(void) {}
void llcs_cancel_free(void) {}
void llcs_cancel_request(void) {}
void llcs_cancel_reset(void) {}
void llcs_cancel_is_requested(void) {}
void llcs_cancel_install(void) {}
void llcs_cancel_wait_credit(void) {}
void llcs_cancel_release_credit(void) {}
void llcs_engine_prepare(void) {}
void * llcs_engine_create(const char * params, char ** error) {
    (void)params; (void)error;
    usleep(200000);
    return calloc(1, sizeof(struct engine));
}
void llcs_engine_destroy(void * engine) { usleep(200000); free(engine); }
char * llcs_engine_caps(void * ptr) { (void)ptr; return copy("{\"test_fixture\":true}"); }
char * llcs_engine_stats(void * ptr) {
    struct engine * e = ptr;
    return copy(e->cancelled ? "{\"cancelled\":1}" : "{\"cancelled\":0}");
}
long long llcs_engine_submit(void * ptr, const char * request, char ** error) {
    (void)request; (void)error;
    struct engine * e = ptr; e->stage = 0;
    return ++e->next;
}
char * llcs_engine_poll(void * ptr, long long task, int timeout) {
    (void)timeout;
    struct engine * e = ptr;
    if (task == 1) return copy(""); // Long prefill, cancelled without a token.
    if (e->stage++ == 0) return copy("[{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]},{\"choices\":[{\"finish_reason\":\"stop\"}]}]");
    return NULL;
}
void llcs_engine_cancel(void * ptr, long long task) { (void)task; ((struct engine *)ptr)->cancelled = 1; }
void llcs_string_free(char * ptr) { free(ptr); }
