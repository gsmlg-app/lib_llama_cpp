# GPU Backend Support

## Status

Proposed. This note defines the accelerator backend release direction for
`lib_llama_cpp`. Pub.dev platform packages carry CPU prebuilts only; Metal,
Vulkan, and CUDA binaries are produced as separate GitHub release assets.

## Problem

GPU behavior has three separate failure modes:

- Build flags can omit the backend entirely.
- Link-time dead stripping can remove compiled backends before runtime.
- The Dart facade can load a model with zero GPU layers even when a GPU backend
  is present.

Fixing only one of those layers produces confusing CPU fallback. The supported
GPU path needs coherent native build defaults, backend preservation, and Dart
configuration plumbing.

## Supported Backend Matrix

The pub.dev package matrix is CPU-only. Optional accelerated release assets use
this matrix:

| Release asset | Platforms | Backend |
| --- | --- |
| `lib_llama_cpp-prebuilt-metal-<version>.tar.gz` | macOS, iOS | Metal |
| `lib_llama_cpp-prebuilt-vulkan-android-<version>.tar.gz` | Android | Vulkan |
| `lib_llama_cpp-prebuilt-vulkan-linux-<version>.tar.gz` | Linux | Vulkan |
| `lib_llama_cpp-prebuilt-vulkan-windows-<version>.tar.gz` | Windows | Vulkan |
| `lib_llama_cpp-prebuilt-cuda-linux-<version>.tar.gz` | Linux | CUDA |
| `lib_llama_cpp-prebuilt-cuda-windows-<version>.tar.gz` | Windows | CUDA |

CPU remains available on every platform and is the only backend bundled into
published platform packages. Accelerated binaries are opt-in release artifacts;
callers load them with `LlamaCppLibraryRequest.preferredPath` or
`LlamaServerConfig.libraryPath`.

## Backend Details

### Metal

Apple builds use:

```text
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
```

Embedding the Metal library is required for Flutter package distribution because
runtime file-path discovery for `default.metallib` is fragile inside framework
bundles. Successful initialization should surface llama.cpp log output similar
to `using embedded metal library`.

### Vulkan

Android, Linux, and Windows builds use:

```text
GGML_VULKAN=ON
```

SPIR-V shaders are compiled at build time. Android can use the NDK-provided
tooling; Linux and Windows builders need Vulkan SDK tooling, including `glslc`.
If the target host lacks a working Vulkan loader or device, initialization must
fall back to CPU without crossing the FFI boundary as an uncaught exception.

### CUDA

Linux and Windows CUDA release assets use:

```text
GGML_CUDA=ON
```

CUDA assets are not bundled into pub.dev packages because toolkit and
redistributable runtime requirements are platform-specific and substantially
increase package size.

## Backend Registration

Compiled backends must be preserved through link time. Static constructors in
backend translation units are easy to dead-strip when the wrapper library does
not reference a symbol directly.

The native build should preserve backend libraries using the platform-specific
pattern expected by llama.cpp:

| Platform | Preservation pattern |
| --- | --- |
| macOS / iOS | `-Wl,-force_load,<backend.a>` or an equivalent all-load setting |
| Android / Linux | `-Wl,--whole-archive <backend.a> -Wl,--no-whole-archive` |
| Windows | `/WHOLEARCHIVE:<backend.lib>` |

This is a packaging rule, not an app-facing API concern. If a backend is
compiled but not preserved, the runtime may silently report CPU behavior.

## Dart Facade

`LlamaModelConfig` and `LlamaLoadModelCommand` need a direct path to
`llama_model_params.n_gpu_layers`. The current `gpuLayerCount` field is the
right low-level knob:

- `0` means CPU-only loading.
- A positive value offloads that many layers.
- A future sentinel, such as `-1`, can mean "offload all available layers" if
  the facade adopts that convention explicitly.

The facade should also expose observable engine information so apps can tell the
difference between "requested GPU" and "actually using GPU". Useful fields are:

- backend used: `metal`, `vulkan`, or `cpu`,
- GPU device name when llama.cpp exposes one,
- initialization log snippets useful for diagnostics,
- fallback reason when GPU initialization fails.

## Testing

Tests should skip unavailable hardware, but they should not silently pass when
a required backend was expected on a given runner.

Required checks:

- macOS CI verifies Metal initialization and CPU fallback.
- Android smoke tests verify Vulkan on a known-capable device or emulator path.
- Linux CI can use SwiftShader to exercise the Vulkan code path without a
  physical GPU.
- Windows CI verifies CPU and treats Vulkan as best effort unless the runner is
  explicitly provisioned with a loader.

Each backend test should assert both the active backend and a coarse
tokens-per-second floor for a small canonical GGUF model. The goal is to catch
accidental flag removal, backend dead stripping, and zero-layer configuration.

## Migration

No public breaking change is required. Existing callers continue to load models
through `LlamaModelConfig.modelPath`. Apps that want GPU offload set
`gpuLayerCount` explicitly until a higher-level backend preference API exists.

Suggested rollout:

- Published platform packages include CPU prebuilts only.
- Metal, Vulkan, and CUDA are built by the accelerated-prebuilts workflow and
  attached to the GitHub release.
- Apps that need acceleration download the matching release archive and pass the
  downloaded library path explicitly.

## Acceptance Criteria

- Root documentation links to this note and states that pub.dev packages include
  CPU prebuilts only.
- Apple packages document Metal as a separate GitHub release asset.
- Android, Linux, and Windows packages document Vulkan as a separate GitHub
  release asset.
- Linux and Windows packages document CUDA as a separate GitHub release asset.
- Runtime loading has a path from Dart `gpuLayerCount` to
  `llama_model_params.n_gpu_layers`.
- Backend tests verify observed GPU initialization, not just build flags.
