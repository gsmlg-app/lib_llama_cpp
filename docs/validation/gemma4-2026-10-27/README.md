# Gemma-4-E2B desktop validation — 2026-10-27

Implementation/ownership details and reproduction commands are in
[desktop-lifecycle-context.md](../../design/desktop-lifecycle-context.md).
This directory records measured source builds separately from published assets.
`passed` means actual near-window input, generated content and terminal usage,
beginning/middle/end retrieval, a second turn with prefix reuse, early overflow,
observed partial prefill cancellation without further polling, decode cancellation,
and a successful request after each cancellation.

## Model and build identity

The fixture is `batiai/Gemma-4-E2B-it-GGUF`, revision
`a6807259ab0f1f77f666d635cfcc7d9d960bf39a`, Q4_K_M:

- `google-gemma-4-E2B-it-Q4_K_M.gguf` SHA256
  `e6d47b7c6316612da747c4e471d10f5f1b87c8bf6051332d80f4810d69196c64`.
- `mmproj-BF16.gguf` SHA256
  `e8b6533e68c0e2b18c57e1cb570ded27a0d70f3421745125bdb210bf5cd4f1c6`.
- Unchanged llama.cpp pin `95b8b8ec1a9e77bcc7b3fb04da82c9f35cb12a79`.
- Exact embedded metadata/template: [gguf-metadata.json](gguf-metadata.json).
  The older embedded Gemma4 template uses the pinned upstream's existing
  compatibility handling; callers supply ordinary messages, not special tokens.
- Native implementation: commit `f0f9cd9`; shim SHA256
  `4a63588fe15e63ab866b3413fffada3383cc232b5417858be0b1e2bc38b885da`.

DGX: Ubuntu 24.04.5 ARM64, 20 CPU cores, 121 GiB RAM, NVIDIA GB10 unified memory,
driver 580.178.04, CUDA toolkit 13.0.88, GCC 13.3. CPU and CUDA library hashes and
ELF dependencies are in [dgx-environment.txt](dgx-environment.txt).
CUDA build architecture is SM 121. This is a source build; the release workflow's
CUDA 12.5 artifacts have different runtime dependencies and require separate checks.

CPU long-window host: NixOS 26.05 Linux x64, i5-12600KF, 62 GiB RAM, GCC 15.2,
glibc 2.42; [ms04-environment.txt](ms04-environment.txt). Its RTX 3050 is not used.
The library's Nix store dependencies make it a host build, not a portable artifact.

## Actual context matrix

| Host/backend | 32K | 64K | 128K |
| --- | --- | --- | --- |
| DGX Linux ARM64 CUDA | passed | passed | passed |
| ms04 Linux x64 CPU | running final acceptance | running/pending | running/pending |
| Linux x64 CUDA release asset | not run on matching GPU | not run | not run |
| Linux Vulkan physical GPU | not run | not run | not run |
| Windows CPU | entry point provided; CI short-context gate separate | not run | not run |
| Windows CUDA/Vulkan physical GPU | not run | not run | not run |

CUDA measurements use one slot, F16 K/V, shared/unified KV, compact SWA,
FA requested on, batch 1024, microbatch 256, eight CPU threads, GPU layers 99.
The actual effective configuration and unsupported diagnostic fields are in each
JSON; startup logs established model offload. Public upstream introspection cannot
report actual FA selection/offloaded layer counts, so those fields remain null.

| Context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | GPU allocation bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](cuda-32768-final.json) | 31741 | 1.784 | 5.695 | 5608.66 | 90.26 | 31790 | 0.069 | 3853082624 | 2215641088 |
| [65536](cuda-65536-final.json) | 64509 | 1.771 | 14.600 | 4440.08 | 75.46 | 64558 | 0.113 | 3853086720 | 2433744896 |
| [131072](cuda-131072-final.json) | 130045 | 1.768 | 42.805 | 3050.41 | 56.05 | 130094 | 0.210 | 4039843840 | 2869952512 |

Every first response generated 50 tokens and finished with `stop`, with a 512-token
reservation. Prefill cancellation observed 1024 processed tokens, then acknowledged
in 0.135–0.138 seconds; decode cancellation barrier was approximately 1.018 seconds.
Barrier latency is an upper bound including the queue acknowledgement. RSS and
GPU allocation overlap on unified memory and must not be added together. Speeds
in the table are native timings; wall-clock throughput excluding TTFT is also
saved independently in JSON.

The first CPU 32K attempt retrieved all three keys (31741 input, 50 output,
504.32 s TTFT, 62.94 prompt tok/s, 8.03 decode tok/s) and reused 31790 tokens on
turn two, but its cancellation probe timed out before its first 1024-token CPU
batch completed. That attempt is **not** a completed tier. The harness now waits
up to 120 seconds for actual `processed > 0`, preserving that assertion and the
cancellation/recovery checks. Final CPU tier results will be recorded separately.

## Correctness, cancellation and resources

- Native ABI: all 15 independent subprocess cases passed on DGX CPU/CUDA and
  ms04 CPU; see [native-final-cpu.log](native-final-cpu.log) and
  [native-final-cuda.log](native-final-cuda.log). They cover real illegal
  parameters followed by successful inference, exact budget boundaries, queued/
  prefill/decode cancellation, no-poll expiry, terminal uniqueness and two engines.
- Warmup 50 to repeat 100 cancellation requests: DGX CPU retained four threads
  and 3490408 KiB RSS; CUDA retained six threads and 3782612 KiB RSS. ms04 CPU
  retained four threads and 4383232 KiB RSS. Active/retained/pending counts returned
  to zero; one collector stayed live. This is bounded-run evidence, not an
  indefinite leak guarantee or an assumption that allocator retention is a leak.
- [baseline-native.json](baseline-native.json) records the baseline wrong-type
  configuration abort; fixed subprocess cases survived and recovered.
- Actual FIN/RST disconnect and immediate next-request measurements are in
  [2048/512](disconnect-probe-b2048.summary.json) and
  [256/128](disconnect-probe-b256.summary.json). Cancellation reaches native;
  the upstream loop services it after the current batch. 2048/512 took
  20.23–21.13 seconds; the documented interactive CPU setting 256/128 took
  1.66–1.68 seconds. No task polling followed cancellation; all counters cleared.
- Real direct API: 11 tests passed with the CPU model/projector, including
  image/audio, media overflow recovery, tool calls and both native-owner close
  orders. Final server suite: 35 passed, including actual model streaming.
  [dart-real-model.txt](dart-real-model.txt) records test identities/results.
  The [default-name CLI smoke](default-cli-verified.json) loaded the platform
  library without `--library`, received content/finish/DONE, mapped errors to
  HTTP 400, recovered from prefill disconnect in 1.793 seconds and closed cleanly.
- Local fast verification: 79 Flutter tests passed, 15 model/platform tests
  skipped without local native fixtures; 43 pure Dart tests passed with five
  environment-specific skips. Analyzer over `packages example`, formatting,
  workflow actionlint and diff checks passed. Ignored `scratch/test_template.dart`
  has unrelated analyzer findings and is excluded from a clean checkout.
- Graphify update completed. GitNexus impact checks were performed; its
  `detect_changes` incorrectly returned no changes for staged diffs, so it is not
  used as evidence of zero blast radius. Staged/integrated diffs were reviewed.

## Deployment evidence and remaining checks

[packaging-final.log](packaging-final.log) records all five packaging checks on
DGX. The published **v0.7.4** CPU archive's checksum was independently verified
(`edc185bf174deb5c1f4a71404895738de8d391f7a36b948b81d1717319227818`),
and its ARM64 library produced `ready` with 15 input/2 output tokens. That confirms
the prior artifact's layout/loadability, not these fixes in a new release.

The new release still requires exact-SHA E2E, all existing platform/package gates,
publication, and consumption of its actual archive. CUDA runtime distribution
uses matching installed NVIDIA redistributables plus driver; Vulkan uses the
system loader/vendor ICD. No physical Windows or Vulkan GPU host was available
for this local run. Accelerator compilation alone does not validate long context.
