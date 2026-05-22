## Unreleased

- Added unsupported-capability errors for bundled CPU-only Windows libraries and
  custom-path capability reporting for caller-provided CUDA or Vulkan builds.
- Documented separate Vulkan and CUDA GitHub release assets.

## 0.4.0

- Linked native builds with llama.cpp common chat utilities and `mtmd`
  multimodal support.
- Prefer packaged prebuilt CPU-only Windows DLLs when present, with source-build
  fallback for monorepo development.

## 0.1.0

- Initial Windows federated plugin implementation.
- Added native library descriptor registration and Windows FFI plugin metadata.
