# lib_llama_cpp_platform_interface

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp_platform_interface.svg)](https://pub.dev/packages/lib_llama_cpp_platform_interface)

Platform interface for the `lib_llama_cpp` federated Flutter plugin.

This package defines the native library resolution contract shared by the
app-facing package and platform implementations. Platform packages implement
`LibLlamaCppPlatform` and return a `LlamaCppLibraryDescriptor` describing how
Dart FFI should locate the compiled llama.cpp library.

Most Flutter applications should depend on `lib_llama_cpp` instead of importing
this package directly.
