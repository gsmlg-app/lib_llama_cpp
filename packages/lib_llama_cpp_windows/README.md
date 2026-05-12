# lib_llama_cpp_windows

Windows implementation package for the `lib_llama_cpp` federated Flutter plugin.

This package registers the Windows platform implementation and CMake metadata
used by the app-facing `lib_llama_cpp` package. It is usually consumed as a
transitive dependency through `lib_llama_cpp`.

Published releases include a prebuilt CPU DLL. Monorepo development builds
compile from the pinned `third_party/llama.cpp` checkout when the prebuilt DLL
is absent, and can opt into CUDA or Vulkan with `LIB_LLAMA_CPP_ENABLE_CUDA=ON`
or `LIB_LLAMA_CPP_ENABLE_VULKAN=ON` when the runner has the required SDKs.
