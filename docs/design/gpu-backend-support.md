# GPU Backend Support

## Status

Proposed. This note defines the supported GPU backend direction for
`lib_llama_cpp`. CUDA is intentionally outside this support track; Metal and
Vulkan cover the platform set targeted by the federated Flutter packages.

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

The supported matrix is:

| Package | Supported GPU backend |
| --- | --- |
| `lib_llama_cpp_macos` | Metal |
| `lib_llama_cpp_ios` | Metal |
| `lib_llama_cpp_android` | Vulkan |
| `lib_llama_cpp_linux` | Vulkan |
| `lib_llama_cpp_windows` | Vulkan |

CPU remains available on every platform and is always the fallback path when a
requested GPU backend cannot initialize.

CUDA is not part of this matrix. Supporting CUDA well requires per-architecture
toolkit builds, redistributable runtime handling, NVIDIA-specific runner
provisioning, and a separate packaging story. If CUDA becomes necessary, it
should land as a separate flavor such as `lib_llama_cpp_cuda`, not as an
implicit default in the cross-platform packages.

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

- Metal remains enabled for Apple platform packages.
- Vulkan becomes the supported non-Apple GPU backend once CI and release runners
  are provisioned with shader tooling.
- CUDA remains out of scope for the federated default packages.

## Acceptance Criteria

- Root documentation links to this note and states that CUDA is out of scope for
  the supported backend matrix.
- Apple packages document Metal as the supported GPU backend.
- Android, Linux, and Windows packages document Vulkan as the supported GPU
  backend.
- Runtime loading has a path from Dart `gpuLayerCount` to
  `llama_model_params.n_gpu_layers`.
- Backend tests verify observed GPU initialization, not just build flags.
