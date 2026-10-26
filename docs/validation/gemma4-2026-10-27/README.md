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
| ms04 Linux x64 CPU | passed | passed | running/pending |
| Linux x64 CUDA release asset | not run on matching GPU | not run | not run |
| DGX Linux ARM64 Vulkan, GB10 | passed | passed | passed |
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

The Vulkan runs use the same model, one slot, F16/shared KV, compact SWA,
1024/256 batches and eight CPU threads. The loader enumerated NVIDIA GB10
(Vulkan API 1.4.312); all successful model loads logged **36/36 layers offloaded**.
The build used a temporary Ubuntu 24.04 container and the unchanged pinned
Vulkan source. [Build identity/dependencies](vulkan-build-metadata.json),
[loader probe](vulkan-loader-probe.json), [method](vulkan-validation-method.json)
and [template consistency](vulkan-template-consistency.json) are retained.

| Vulkan context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | GPU allocation bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](vulkan-32768-final.json) | 31741 | 1.307 | 19.956 | 1593.40 | 59.16 | 31790 | 0.117 | 4067627008 | 2384461824 |
| [65536](vulkan-65536-final.json) | 64509 | 1.321 | 63.944 | 1009.94 | 53.85 | 64558 | 0.152 | 4067635200 | 2602565632 |
| [131072](vulkan-131072-final.json) | 130045 | 1.370 | 234.867 | 554.03 | 39.46 | 130094 | 0.270 | 4067512320 | 3038773248 |

All Vulkan terminal/task counters cleared. Prefill cancellation barriers were
0.222–0.233 seconds; decode cancellation approximately 1.018 seconds.

CPU final acceptance uses six threads and the same 1024/256/F16/compact-SWA
baseline. Both completed tiers generated 50 tokens, acknowledged actual
partial-prefill cancellation and recovered.

| CPU context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | Prefill cancel s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](cpu-32768-final.json) | 31741 | 1.001 | 504.566 | 62.91 | 8.10 | 31790 | 0.915 | 5028495360 | 7.048 |
| [65536](cpu-65536-final.json) | 64509 | 1.078 | 1731.132 | 37.27 | 4.66 | 64558 | 1.734 | 5477138432 | 7.139 |

The earlier CPU 32K attempt retrieved all three keys (31741 input, 50 output,
504.32 s TTFT, 62.94 prompt tok/s, 8.03 decode tok/s) and reused 31790 tokens on
turn two, but its cancellation probe timed out before its first 1024-token CPU
batch completed. That attempt is **not** a completed tier. The harness now waits
up to 120 seconds for actual `processed > 0`, preserving that assertion and the
cancellation/recovery checks. The successful retry is recorded above.

## Correctness, cancellation and resources

- Native ABI: all 15 independent subprocess cases passed on DGX CPU/CUDA and
  ms04 CPU; see [native-final-cpu.log](native-final-cpu.log) and
  [native-final-cuda.log](native-final-cuda.log). They cover real illegal
  parameters followed by successful inference, exact budget boundaries, queued/
  prefill/decode cancellation, no-poll expiry, terminal uniqueness and two engines.
- The original CPU/CUDA-library native harness uses CPU model placement. CUDA
  subsequently passed all 15 cases with GPU placement required and 36/36 layers
  offloaded; [method and resource trend](native-cuda-gpu-method.json),
  [case summary](native-cuda-gpu-summary.json),
  [exact harness diff](native-cuda-gpu-wrapper.diff).
  Threads stayed at six; RSS grew only 16 KiB from cancellation 50 to 100, with
  all request/cancellation/buffer counters cleared. Vulkan also ran
  all 15 cases with GPU placement required, retaining every original assertion
  and adding caps/offload checks. [Summary](native-vulkan-summary.json) and
  [the exact harness diff](vulkan-native-wrapper.diff) distinguish those runs.
- Warmup 50 to repeat 100 cancellation requests: DGX CPU retained four threads
  and 3490408 KiB RSS; CUDA retained six threads and 3782612 KiB RSS. ms04 CPU
  retained four threads and 4383232 KiB RSS. Active/retained/pending counts returned
  to zero; one collector stayed live. This is bounded-run evidence, not an
  indefinite leak guarantee or an assumption that allocator retention is a leak.
- [baseline-native.json](baseline-native.json) records the baseline wrong-type
  configuration abort; fixed subprocess cases survived and recovered.
- The final direct ABI audit additionally reproduced a real-model grammar abort:
  accepting an already-accepted sampled token twice threw `Unexpected empty
  grammar stack` (token 236746, piece `a`, exit 134). The safe real-model probe
  samples the same token, cleans up and exits zero. Six isolated adapter tests
  passed on Linux (8.699 seconds) and macOS (7.226 seconds), covering allocation,
  standard/unknown exceptions, token-buffer counts and sampler child ownership.
  They run in fast CI without downloading a model. Final direct CPU library SHA256:
  `96466afe22916a71c3fd2e16ebe1e6e6c6a3a565d7214d4ddd797d6f22a14342`.
  This new build does not replace the earlier measured server/GPU binaries.
  The new CPU library then passed the complete 15 native cases, 11 direct/media
  cases and 35 server tests: [native result](native-safe-final.log),
  [Dart and grammar probe results](dart-safe-real-model.txt). The native repeat
  cancellation run stayed at four threads and 3490544 KiB RSS from request 50
  through 100; all task, cancellation and buffer counts cleared.
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
- The original CLI 256/128 configuration exceeded its 15-second recovery deadline
  on a two-core CPU. The final smoke uses affinity-aware threads and 32/32,
  retaining the deadline and requiring actual fresh partial prefill before
  disconnect. The [controlled comparison](default-cli-smoke-fix-validation.json)
  includes 64/32 (8.237 seconds), 32/32 (4.454 seconds), and final safe-library
  runs on [two cores](default-cli-safe-affinity2-final.json) (4.462 seconds) and
  [the unrestricted host](default-cli-safe-unrestricted-final.json) (0.795 seconds).
  All observed `cache=4 < processed=36 < total=3014` on the final configuration;
  all four checks and graceful SIGINT shutdown passed. Defaults in native code
  and the separate long-window throughput configuration are unchanged.
- Windows pre-release E2E at `b51c64c` passed all eight backend export checks,
  11 direct/media tests, four server API tests and 15 native cases. Its final
  default-name CLI gate then rejected an existing drive path as a URI scheme;
  [failure](windows-cli-path-failure.json). A subprocess regression reproduced
  the same classification failure before the drive-path guard repair and passed
  afterward. Linux's corresponding [default-name gate](ci-linux-default-cli.json)
  passed, recovering after actual partial-prefill disconnect in 1.412 seconds.
  Windows CLI acceptance must pass on the final source commit before release.
- Local fast verification: 79 Flutter tests passed, 15 model/platform tests
  skipped without local native fixtures; 44 pure Dart tests passed with five
  environment-specific skips. Analyzer over `packages example`, formatting,
  workflow actionlint and diff checks passed. Ignored `scratch/test_template.dart`
  has unrelated analyzer findings and is excluded from a clean checkout.
  Packaging rerun on the local macOS host failed because CMake was absent; the
  same five checks passed on DGX with CMake. This is an environment limitation,
  not a claimed local packaging pass.
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
system loader/vendor ICD. A physical Windows host was unavailable locally.
DGX's Vulkan GPU was confirmed through the native loader and then tested using
an isolated build container, without changing the host driver or source pin.
Accelerator compilation alone does not validate long context.
