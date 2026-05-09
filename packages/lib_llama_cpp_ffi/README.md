# lib_llama_cpp_ffi

Low-level Dart FFI bridge for llama.cpp.

This package contains generated Dart bindings for the llama.cpp C ABI, native
library loading helpers, opaque handle wrappers, and `NativeFinalizer` bindings
for model/context ownership. It is infrastructure for `lib_llama_cpp` and
advanced integrations that need direct access to llama.cpp symbols.

Most applications should prefer `package:lib_llama_cpp/lib_llama_cpp.dart`.
