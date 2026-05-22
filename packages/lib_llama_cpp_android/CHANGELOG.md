## Unreleased

- Report bundled Android release libraries as CPU-only and document separate
  Vulkan GitHub release assets.
- Added unsupported-capability errors for bundled Android libraries and
  custom-path capability reporting for caller-provided backend builds.

## 0.4.0

- Linked native builds with llama.cpp common chat utilities and `mtmd`
  multimodal support.
- Prefer packaged prebuilt CPU-only Android libraries when present, with
  source-build fallback for monorepo development.

## 0.1.0

- Initial Android federated plugin implementation.
- Added native library descriptor registration and Android FFI plugin metadata.
