# lib_llama_cpp_linux

Linux implementation package for the `lib_llama_cpp` federated Flutter plugin.

This package registers the Linux platform implementation and CMake metadata used
by the app-facing `lib_llama_cpp` package. It is usually consumed as a
transitive dependency through `lib_llama_cpp`.

Published releases include a prebuilt CPU-only shared library. Monorepo
development builds compile from the pinned `third_party/llama.cpp` checkout
when the prebuilt library is absent.
