# lib_llama_cpp

Federated Flutter FFI plugin workspace for direct llama.cpp inference from
Dart and Flutter.

The repository is intentionally split into narrow packages:

- `packages/lib_llama_cpp` is the app-facing facade and isolate scheduler.
- `packages/lib_llama_cpp_platform_interface` defines the federated contract.
- `packages/lib_llama_cpp_ffi` owns generated Dart FFI bindings and opaque
  native handle wrappers.
- `packages/lib_llama_cpp_android`, `packages/lib_llama_cpp_ios`,
  `packages/lib_llama_cpp_macos`, `packages/lib_llama_cpp_linux`, and
  `packages/lib_llama_cpp_windows` isolate native build integration.
- `third_party/llama.cpp` is a pinned git submodule.
- `example` is the Flutter integration app.

## Development

On macOS, use the system Flutter/Dart toolchain and system packages. On NixOS,
enter the project shell with `devenv shell`; `.envrc` only enables devenv on
NixOS.

```sh
dart pub get
melos bootstrap
melos run analyze
melos run test
```

Regenerate FFI bindings after changing the pinned llama.cpp header:

```sh
melos run ffigen
```

## Design Constraints

- Flutter UI isolates must not call blocking llama.cpp APIs directly.
- Native state is represented as opaque Dart references.
- Cross-language native allocations must be tied to `NativeFinalizer`.
- Platform packages own native build side effects; pure Dart packages do not.
