## 0.7.5

- Fix pinned upstream streaming array/state contracts and guard owned C ABI/thread
  exception boundaries. Validate JSON types before upstream coercion.
- Cancel native queued/in-flight work, bound task/event/retention resources and
  share process backend ownership. Add exact budget preparation and resource stats.
- Preflight actual media tokens/positions plus output budget before evaluation.
- Resolve platform package library names and validate matching shim symbols.

## 0.4.0

- Regenerated llama.cpp bindings with `mtmd` multimodal APIs and the
  `lib_llama_cpp` chat/template wrapper ABI.

## 0.1.0

- Initial release of generated llama.cpp FFI bindings.
- Added native library loader helpers and model/context handle wrappers.
