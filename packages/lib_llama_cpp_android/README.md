# lib_llama_cpp_android

Android implementation package for the `lib_llama_cpp` federated Flutter plugin.

This package registers the Android platform implementation and native build
hooks used by the app-facing `lib_llama_cpp` package. It is usually consumed as
a transitive dependency through `lib_llama_cpp`.

Published pub.dev releases include prebuilt CPU and Vulkan `jniLibs` for
`arm64-v8a`. The GitHub release prebuilt archive also carries the full Android
ABI build output, including `armeabi-v7a` and `x86_64`, for consumers that need
to install prebuilts manually. Monorepo development builds compile from the
pinned `third_party/llama.cpp` checkout when prebuilts are absent, and can opt
into Vulkan with `LIB_LLAMA_CPP_ENABLE_VULKAN=ON` when the Android build
environment provides the required Vulkan shader tools.
