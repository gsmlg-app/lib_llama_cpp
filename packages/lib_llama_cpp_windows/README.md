# lib_llama_cpp_windows

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp_windows.svg)](https://pub.dev/packages/lib_llama_cpp_windows)

Windows implementation package for the `lib_llama_cpp` federated Flutter plugin.

This package registers the Windows platform implementation and CMake metadata
used by the app-facing `lib_llama_cpp` package. It is usually consumed as a
transitive dependency through `lib_llama_cpp`.

Published pub.dev releases include a prebuilt CPU DLL. Vulkan and CUDA
prebuilts are published as separate GitHub release assets and are not bundled
into the pub.dev package. Monorepo development builds compile from the pinned
`third_party/llama.cpp` checkout when the prebuilt DLL is absent, and can opt
into Vulkan with `LIB_LLAMA_CPP_ENABLE_VULKAN=ON` or CUDA with
`LIB_LLAMA_CPP_ENABLE_CUDA=ON` when the runner has the required SDKs.
