## 0.7.5

- Apply model templates to every Chat/Responses request; preserve raw completions.
- Keep direct model weights resident, serialize requests, safely rebuild direct
  contexts and retain the media-capable execution path.
- Fix native streaming delta arrays, cancellation/teardown, bounded retention,
  exception isolation, structured errors and desktop library resolution.
- Add strict incremental UTF-8, actual token budgets/usage, native context limits,
  requested/effective capabilities and worker-isolated HTTP/native operations.
- Add Linux/Windows regression and opt-in 32K/64K/128K acceptance commands. CUDA
  Gemma long-window results are recorded per tested host; unexecuted hardware
  combinations and direct KV-prefix reuse are explicitly not claimed.

## 0.1.0-dev

- Initial federated Flutter FFI plugin workspace scaffold.
