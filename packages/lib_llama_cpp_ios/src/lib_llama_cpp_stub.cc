#if defined(_WIN32)
#define LIB_LLAMA_CPP_EXPORT __declspec(dllexport)
#else
#define LIB_LLAMA_CPP_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

extern "C" LIB_LLAMA_CPP_EXPORT int lib_llama_cpp_stub_abi_version(void) {
  return 1;
}
