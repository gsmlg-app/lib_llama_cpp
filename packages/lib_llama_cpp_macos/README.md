# lib_llama_cpp_macos

[![pub package](https://img.shields.io/pub/v/lib_llama_cpp_macos.svg)](https://pub.dev/packages/lib_llama_cpp_macos)

macOS implementation package for the `lib_llama_cpp` federated Flutter plugin.

This package registers the macOS platform implementation and CocoaPods metadata
used by the app-facing `lib_llama_cpp` package. It is usually consumed as a
transitive dependency through `lib_llama_cpp`.

Published pub.dev releases include a prebuilt CPU xcframework. Metal prebuilts
are published as separate GitHub release assets and are not bundled into the
pub.dev package. Monorepo development builds compile from the pinned
`third_party/llama.cpp` checkout when the prebuilt framework is absent.
