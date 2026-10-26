# Desktop lifecycle and native-context acceptance

This review covers the fixes against v0.7.4 (`27e92c9b608ad64c87d758bae7d16ac5f686f6d7`).
The llama.cpp pin remains `95b8b8ec1a9e77bcc7b3fb04da82c9f35cb12a79`.
New native acceptance targets Linux and Windows. Existing media APIs and other
platform packaging gates remain in place; no new mobile or Apple hardware
acceptance is claimed here.

## Review findings

All six correctness findings were still present at the reviewed HEAD. They were
reproduced or confirmed against its actual control flow before modification.

| Finding at v0.7.4 | Change | Regression evidence |
| --- | --- | --- |
| Plain Chat/Responses bypassed the model template | All message requests use the upstream template once; raw `LlamaGenerateCommand` stays a raw completion API | Plain strings, maps, system/history fixtures and real Gemma input without caller-supplied special tokens |
| Native delta arrays vanished at the Dart boundary | Native collector flattens arrays in order; Dart accepts object/array/null and rejects unknown shapes; upstream state updated exactly once | Baseline real stream returned no events; corrected stream requires actual payload, finish reason and usage |
| Cancellation only ended the Dart subscription; cleanup could be killed | Shared atomic abort flag for direct inference; upstream CANCEL plus queue barrier for server inference; close awaits native teardown | Queued/prefill/decode cancel, no-poll cancel, immediate next request, close, repeated resource checks |
| Exceptions could escape C entry points or native threads | Owned C ABI and thread entries catch allocation, standard and unknown exceptions; request scalar types are checked before upstream coercion | Baseline wrong-type config aborted a subprocess; isolated invalid requests now recover and complete legal requests |
| Desktop server searched for upstream library names | Direct/server share loader validation and platform package names | Linux default-name CLI load/inference; Linux/Windows loader tests; plain upstream libraries rejected for missing shim symbols |
| Token pieces could split UTF-8 characters | Strict incremental byte decoder feeds complete characters to stop matching and parsing | Chinese, rare characters, emoji, split stops, incomplete final bytes |

Additional integration regressions cover delayed HTTP response bodies, DONE-only
streams, missing terminal events, queued direct cancellation behind a paused
request, and requested versus advertised accelerator support.

The final ABI audit also reproduced a direct sampling abort with a real GGUF:
upstream `llama_sampler_sample` already accepts the sampled token; the former
second `llama_sampler_accept` advanced a grammar twice and threw. Direct calls
now use thin exception-safe adapters for load/context, tokenization, piece
conversion, decode and sampler operations, and accept each sampled token once.
Sampler construction owns both the chain and each child until insertion succeeds.
Six isolated native tests include actual upstream grammar/sampler execution and
injected allocation failures, including chain insertion, followed by recovery.
These adapters do not introduce a second generation loop or modify the vendor pin.

The real Windows default-name gate also found that the CLI mistook a drive
letter for a URI scheme and rejected an existing `D:\\...` model before loading.
The local-path guard now recognizes Windows drive syntax. A subprocess regression
checks an existing native path with spaces reaches library validation, and the
desktop gate continues through actual default-name model inference.

## Ownership and execution paths

| Resource | Direct Dart API | HTTP/native server API |
| --- | --- | --- |
| Model and backend | Default `LlamaOpenAIClient` owns `ResidentLlamaEngine`, one worker and one loaded configuration | `LlcsWorkerEngine` owns an isolate, native engine, model, processing loop and one collector |
| Session | Caller supplies complete messages every request. Context is rebuilt; weights stay resident | Upstream slot owns token ledger, sequence, KV positions and checkpoints; full messages are templated/tokenized each request |
| Request | Serialized lease, sampler, incremental decoder, parser, abort flag and bounded response credits | Task ID, upstream parser state, bounded result queue and one terminal outcome |
| Cleanup | `await client.close()`; caller closes an injected engine | `await server.close()` or `await engine.close()` |

Direct and server paths remain separate because this pinned server path rejects
images/audio. Direct `mtmd` image/audio and tool entry points remain available.
The pre-existing direct `peg-gemma4` policy still omits the generated sampling
grammar. Tool templates and output parsing are active and real tool requests
are tested, but this path does not guarantee schema-constrained token generation.
The safe ABI and once-only acceptance repair do not by themselves validate all
Gemma4 lazy/non-lazy generated grammars. Server grammar handling remains upstream.
There is no automatic fallback that loads a second model or context. Opening two
engines explicitly creates two owners and requires memory for both. A shared,
reference-counted backend lease prevents one owner from freeing process-global
backend state while another remains live.

The recommended server constructor is `await LlamaHttpServer.openAsync(...)`.
Create, template/tokenization submit, poll and destroy run on its owning worker;
wrapping a synchronous FFI poll in a Future is not used as isolation. The old
synchronous `LlamaHttpServer.open` and `LlcsEngine.open` signatures remain for
compatibility and must be called on an application-owned worker if used.

### Request transitions and cancellation

Normal server transitions are queued -> prefilling -> decoding -> completed;
failed and cancelled are terminal alternatives. Streaming progress comes from
upstream begin/progress results. Nonstream metrics can distinguish active and
decoding, but cannot reliably expose the precise prefill phase; capabilities
report that limitation. Cancelled task state is removed immediately and counted
in `stats.cancelled`; the upstream cancellation barrier remains until native
work has acknowledged it. Late results are discarded by task identity.

Direct inference uses the upstream CPU abort callback where supported and checks
the same atomic flag at controllable decode/batch boundaries. GPU work already
submitted may finish its batch. Cancellation wakes a producer blocked on response
credits. Closing rejects new work, requests cancellation, waits for cleanup
acknowledgement and then frees context/model; it does not immediately kill the
worker isolate. The legacy command-stream API also closes in `finally`, even
without an explicit Dispose command.

Server cancellation reaches the upstream queue directly. It uses no temporary
response reader owning a CANCEL task and creates no per-request thread.
Cancellation acknowledgement latency measures a queue barrier after CANCEL, so
it is a conservative upper bound rather than exact GPU kernel stop time.
HTTP SSE flushes a heartbeat during long prefill to detect client disconnects;
disconnect cancels its iterator and native task. Cancellation is not a normal
`stop` completion. Each active request can have only one terminal result.

CPU responsiveness depends on the configured batch boundaries. On the tested
DGX CPU, upstream defaults (2048/512) took 20.23–21.13 seconds from cancellation
to completion of the immediately submitted legal request. The documented
interactive CPU configuration (256/128, eight threads) took 1.66–1.68 seconds;
the cancellation barrier cleared and task/buffer counters returned to zero.
Both FIN and RST disconnects were tested. This is a measured configuration, not
a universal latency guarantee. Native upstream defaults remain available;
the long-window throughput measurements explicitly use 1024/256.
The default-name consumer smoke uses 32/32 and at most eight available CPU
threads so small CI runners can meet its unchanged 15-second recovery limit.
It waits for fresh partial-prefill progress before disconnecting; receiving only
an initial heartbeat cannot satisfy this check. The tested two-core CPU recovered
in 4.462 seconds; the unrestricted host recovered in 0.795 seconds.

### Slow consumers and bounded retention

Direct streaming permits 64 outstanding response credits. Server capacity is 64
outstanding task/cancellation records; each task holds at most 1024 events and
1 MiB. Capacity exhaustion is explicit and stops native work. Completed results
expire after 30 seconds without requiring further poll calls, including retained
parser/result buffers. A bounded ring of 64 task IDs produces an explicit
`result_expired` / `consumer_timeout` on the first late poll. Applications needing
longer retention can set native `result_retention_ms` (100..86400000). It is not
an unlimited delivery guarantee for indefinitely paused streams.

`llcs_engine_stats` / `LlcsWorkerEngine.stats()` report active/retained tasks,
buffered events/bytes, pending cancellation barriers, expiry counts, collector
count, terminal counters and upstream slot/timing metrics. Request records do not
accumulate until engine destruction.

## Sessions, prefix reuse and SWA

Removing Dispose alone would append a complete prompt to stale KV state. Instead,
the direct path reuses weights and rebuilds the request context before evaluating
its complete input. This deliberately claims **no direct KV prefix reuse**. A
changed system message, tool round trip, history edit or template therefore cannot
reuse invalid state. The caller remains the owner of conversation history.

Server prefix reuse is delegated to the pinned upstream slot/checkpoint logic.
The ledger uses actual tokens and KV positions, not concatenated output strings.
Compact Gemma SWA can invalidate a rollback even when tokens have a common
prefix. Upstream restores a valid checkpoint or rebuilds/prefills the unavailable
prefix; measured cached tokens and timings reveal the outcome. The acceptance
probe includes an identical-prefix continuation and a changed system prefix.

Server defaults use unified/shared KV, compact SWA and F16 K/V. Direct uses a single sequence. Full SWA is opt-in and
uses more memory. Context shifting and automatic context fitting are disabled.
History is not silently discarded and no RoPE extrapolation is enabled. The
Gemma-4-E2B native ceiling is 131072; larger requested contexts are rejected.

## Configuration, capabilities and budget

`LlamaServerConfig`, `LlcsEngineConfig` and the CLI expose context, logical batch,
physical micro-batch, decode/prefill threads, GPU layers, slots, Flash Attention,
K/V types, SWA mode and required backend. Direct `LlamaModelConfig` /
`LlamaLoadModelCommand` expose corresponding single-sequence settings (native enum
values for FA/cache types). Values and combinations are validated before use.

Native caps and `/healthz.capabilities` distinguish `requested`, `effective`,
`unsupported`, compiled backends, enumerated devices and degradation. An explicit
CUDA/Vulkan path does not establish support: direct platform descriptors retain
requirements separately and the runtime checks registration and usable devices.
A required unavailable backend fails. Server fallback is permitted only with
`require_backend: false`, and reports a degradation string. Explicit GPU offload
on a CPU-only direct library fails before reading model weights.

The pinned upstream public API cannot expose actual FA selection, device placement
or number of offloaded layers. Those effective fields are null, not copied from
the request. Native startup logs establish offload for the measured CUDA runs.
Compiled support, available device, requested backend and proven offload are
separate observations. `--log-level` is a legacy accepted CLI option and does not
currently change upstream native logging.

Before prefill, both paths render the model template and tokenize actual input.
Media is tokenized through `mtmd`, counting actual media tokens and M-RoPE positions
before expensive evaluation. Validation includes instructions, history, template,
special tokens and output reservation. It never silently truncates the prompt.

For server mode, compare `prompt_tokens + reserved_output_tokens <= usable_context`.
`effective_context` is the **per-slot** window, not the engine's total `n_ctx`.
Upstream reserves one position, so `usable_context = slot_n_ctx - 1`. The
`llcs_engine_prepare` API returns this exact budget without running prefill. Direct
mode uses its single context and reports actual evaluated input/output tokens.
Always specify finite `max_tokens` / `maxOutputTokens` for predictable budgets.
Server requests default to 256 output tokens; direct requests without a limit use
the remaining window. Exceeding a known budget is an early `context_overflow`;
HTTP maps invalid parameters and overflow to 400. Backpressure/capacity maps to
429; backend/allocation failures remain distinct. Streaming usage comes from the
native final event; output-limit termination is `length`, not `stop`.

## Reproducible desktop acceptance

The immutable fixture remains the repository's Gemma Q4_K_M model:

- Source: `batiai/Gemma-4-E2B-it-GGUF` on Hugging Face.
- Revision: `a6807259ab0f1f77f666d635cfcc7d9d960bf39a`.
- Model: `google-gemma-4-E2B-it-Q4_K_M.gguf`.
- SHA256: `e6d47b7c6316612da747c4e471d10f5f1b87c8bf6051332d80f4810d69196c64`.
- Projector: `mmproj-BF16.gguf`;
  SHA256 `e8b6533e68c0e2b18c57e1cb570ded27a0d70f3421745125bdb210bf5cd4f1c6`.
- GGUF architecture `gemma4`, native context 131072, sliding window 512,
  35 layers with 20 shared KV layers. Exact metadata/template are saved with evidence.
- This fixture contains an older Gemma4 template; the pinned upstream detects it
  and applies its existing compatibility handling. The fixture was not silently
  replaced, nor were prompts preformatted by tests.

```sh
python3 tools/gguf_metadata.py "$MODEL" > model-metadata.json
python3 packages/lib_llama_cpp_ffi/test/native/test_direct_safe.py
python3 packages/lib_llama_cpp_ffi/test/native/test_engine.py "$LIBRARY" "$MODEL"
LIB_LLAMA_CPP_TEST_LIBRARY="$LIBRARY" \
LIB_LLAMA_CPP_TEST_CPU_LIBRARY="$CPU_LIBRARY" \
LIB_LLAMA_CPP_TEST_MODEL="$MODEL" LIB_LLAMA_CPP_TEST_MMPROJ="$MMPROJ" \
dart test --concurrency=1 packages/lib_llama_cpp/test/real_model_e2e_test.dart
LIB_LLAMA_CPP_TEST_LIBRARY="$LIBRARY" LIB_LLAMA_CPP_TEST_MODEL="$MODEL" \
dart test --concurrency=1 packages/lib_llama_cpp_server/test
python3 tools/desktop_server_smoke.py --model "$MODEL" \
  --library-directory "$LIBRARY_DIRECTORY" --log server.log --output server.json
for context in 32768 65536 131072; do
  python3 tools/desktop_context_benchmark.py --library "$LIBRARY" --model "$MODEL" \
    --backend cuda --gpu-layers 99 --context "$context" \
    --batch 1024 --ubatch 256 --threads 8 --flash-attn on \
    --output "cuda-$context.json"
done
```

Use `--backend cpu --gpu-layers 0` for CPU, or `--backend vulkan --gpu-layers 99`
for a validated Vulkan library/device. Windows uses the same Python scripts and
its DLL path; run each context command separately in PowerShell. Python 3.11+ is
required. No test downloads a model implicitly. The manual `desktop-context.yml`
workflow provides Linux/Windows CPU/CUDA/Vulkan entry points with a required
matching runner; it fails when requested GPU hardware is absent. Ordinary CI
runs fast regressions without a model download. The existing release E2E gate
also exercises Gemma direct/media/server/ABI/default-name loading on Linux and
Windows CPU.

Each long-window run constructs a real >=95% window prompt, reserves 512 output
tokens, retrieves distinct keys from the beginning/middle/end, completes a second
turn, checks cached tokens, rejects an overflow and recovers after decode/prefill
cancellation. The prefill probe changes the system prefix and asserts the native
state is actually `prefilling`; reusing a cached short decode does not qualify.
Cancellation tests do not poll after cancel. Results record load time, TTFT,
upstream prefill/decode timings, peak RSS and driver-reported per-process memory.
GB10 unified memory means RSS and GPU allocation can overlap; do not sum them.

Acceptance results and exact tested build identities are maintained in
[the validation record](../validation/gemma4-2026-10-27/README.md). Initial CPU/GPU
measurements are not a claim about unexecuted Windows/backend combinations. Q8 KV
has not replaced the measured F16 baseline.

## Deployment and release evidence

Bundled pub.dev libraries are CPU builds. Linux expects
`liblib_llama_cpp_linux.so` (x64/arm64); Windows expects
`lib_llama_cpp_windows.dll` (x64). Put the matching CPU library on the system
loader path (`LD_LIBRARY_PATH` before process launch on Linux, PATH/application
DLL directory on Windows). The default-name consumer smoke deliberately omits
`--library`. Explicit accelerator paths use the same shim-symbol validation and
must come from the matching package release. A plain upstream `libllama.so` or
`llama.dll` is not a substitute.
MSVC builds explicitly export the embedded static ggml device/registration API;
exporting only wrapper object symbols missed these functions. Desktop E2E now
checks all eight enumeration symbols before exercising direct inference.

Separate CUDA/Vulkan GitHub assets require their dependent runtime libraries.
CUDA builds link to the toolkit selected by the build workflow, plus the host
NVIDIA driver; inspect ELF/DLL imports for the **actual asset** before deploying.
For the measured CUDA 13 build, dependencies include libcudart.so.13,
libcublas.so.13, libcublasLt.so.13 and libcuda.so.1. Install matching NVIDIA
redistributable runtimes and a compatible driver; this release does not bundle a
CUDA toolkit or claim a toolkit-free CUDA deployment. Vulkan needs the system
loader and a working vendor ICD/driver. Windows CPU needs the matching Microsoft
VC++ runtime when the asset imports it. Linux needs compatible glibc/libstdc++.
Build-tool availability is not a consumer runtime requirement.

Build defaults disable host-native instruction tuning. That alone is not a
promise of every historical x64 CPU: upstream x64 CPU defaults and actual asset
instruction requirements still apply (SSE/AVX/AVX2/FMA/F16C where enabled by its
build). Linux ARM64 uses the compiled ARM ISA features. The validation record
lists concrete consumer hosts and dependencies; unsupported architectures or ISA
combinations are not inferred from a successful cross-build.

Release continues through the existing exact-SHA E2E, package, native build and
publication gates. Release notes must keep fixes verified on tested combinations
separate from remaining 128K/hardware verification. Source-built acceptance,
release archive integrity/loading, pub.dev publication and physical GPU inference
are recorded as separate evidence.
