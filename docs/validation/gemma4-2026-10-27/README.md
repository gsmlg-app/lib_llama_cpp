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
| ms04 Linux x64 CPU | passed | passed | passed |
| Published Linux x64 CUDA, RTX 3050 | passed | passed | passed |
| DGX Linux ARM64 Vulkan, GB10 | passed | passed | passed |
| Published Linux x64 Vulkan, RTX 3050 | passed | passed | passed |
| Windows x64 CPU | passed | passed | running |
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
SHA verification reads the model before loading it. These load times therefore
reflect a warm file cache; they do not measure a cold disk/application start.

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

The **published Linux x64 Vulkan archive** is a separate artifact from the DGX
source build above. On ms04's RTX 3050, it uses the same F16/shared-KV/compact-SWA
1024/256 baseline and eight threads. Each passing run independently logged
36/36 layers offloaded and `flash_attn = enabled`. Those startup observations
are independent of the API's unavailable effective-FA/offload introspection fields.
The container uses the host PID namespace so the benchmark
can match its actual process to `nvidia-smi`; RSS is host memory, distinct from
the discrete GPU allocation. No native source/build tree is mounted.

| Published Vulkan context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | Peak VRAM bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](released-vulkan-32768-final.json) | 31741 | 3.842 | 37.237 | 853.17 | 47.45 | 31790 | 0.449 | 4093517824 | 1978662912 |
| [65536](released-vulkan-65536-final.json) | 64509 | 3.771 | 154.150 | 418.67 | 28.88 | 64558 | 0.683 | 4094357504 | 2179989504 |
| [131072](released-vulkan-131072-final.json) | 130045 | 3.889 | 687.234 | 189.27 | 18.10 | 130094 | 0.728 | 4089606144 | 2582642688 |

All three tiers generated 50 tokens per turn and passed retrieval, overflow,
cache reuse and recovery. Prefill cancellation barriers were 0.573 / 2.350 /
1.054 seconds; decode barriers were 1.025 / 0.061 /
1.028 seconds. [Artifact and run provenance](released-vulkan-method.json) records
image/harness hashes and raw-log digests. An existing user embedding process
retained approximately 1248 MiB of GPU memory during these measurements; the GPU
was shared and the service was preserved. These are per-process measurements in
a real desktop environment, not an isolated performance claim.

The **published Linux x64 CUDA archive**, using CUDA 12.5 runtime libraries in
the same offline Ubuntu 24.04.5 container and shared RTX 3050, also passed all
three tiers. Its F16/shared-KV/compact-SWA configuration is 1024/256, eight
threads, one slot. All three startup logs prove 36/36 layers offloaded and
`flash_attn = enabled`; API introspection remains null where unsupported.

| Published CUDA context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | Peak VRAM bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](released-cuda-32768-final.json) | 31741 | 0.952 | 16.809 | 1891.75 | 61.61 | 31790 | 0.082 | 3807764480 | 2122317824 |
| [65536](released-cuda-65536-final.json) | 64509 | 0.912 | 53.670 | 1203.31 | 21.16 | 64558 | 0.226 | 3572154368 | 2340421632 |
| [131072](released-cuda-131072-final.json) | 130045 | 0.920 | 215.551 | 603.65 | 22.66 | 130094 | 0.218 | 3994820608 | 2776629248 |

Every tier generated two correct 50-token responses and passed overflow and
recovery. Prefill cancellation acknowledged in 0.364 / 0.963 / 0.495 seconds;
decode cancellation barriers were 1.015 / 0.021 / 1.035 seconds. No further
task poll followed cancellation. [Artifact/run provenance](released-cuda-method.json)
records the actual published member and raw evidence digests. Model-file cache
was warm; this shared GPU run is not an isolated or cold-start benchmark.

CPU final acceptance uses six threads and the same 1024/256/F16/compact-SWA
baseline. All three tiers generated 50 tokens, acknowledged actual
partial-prefill cancellation and recovered.

| CPU context | Prompt tokens | Load s | TTFT s | Prefill tok/s | Decode tok/s | Cached tokens, second turn | Second TTFT s | Peak RSS bytes | Prefill cancel s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [32768](cpu-32768-final.json) | 31741 | 1.001 | 504.566 | 62.91 | 8.10 | 31790 | 0.915 | 5028495360 | 7.048 |
| [65536](cpu-65536-final.json) | 64509 | 1.078 | 1731.132 | 37.27 | 4.66 | 64558 | 1.734 | 5477138432 | 7.139 |
| [131072](cpu-131072-final.json) | 130045 | 1.244 | 6513.236 | 19.97 | 2.54 | 130094 | 3.270 | 6319157248 | 6.938 |

The 128K [SWA log evidence](cpu-131072-swa-evidence.json) records actual checkpoint
creation, invalidation and forced full reprocessing after the changed system
prefix, followed by a valid checkpoint restore for a later short request.
Token-prefix similarity alone was not used as a safe rewind condition.

The earlier CPU 32K attempt retrieved all three keys (31741 input, 50 output,
504.32 s TTFT, 62.94 prompt tok/s, 8.03 decode tok/s) and reused 31790 tokens on
turn two, but its cancellation probe timed out before its first 1024-token CPU
batch completed. That attempt is **not** a completed tier. The harness now waits
up to 120 seconds for actual `processed > 0`, preserving that assertion and the
cancellation/recovery checks. The successful retry is recorded above.

Windows x64 CPU 32K [actual result](windows-cpu-32768-final.json), run
[40425573853](https://github.com/gsmlg-app/lib_llama_cpp/actions/runs/40425573853),
passed with 31741 prompt tokens and 50 output tokens: load 2.969 seconds,
TTFT 1257.703 seconds, prefill 25.24 tok/s, decode 6.87 tok/s and peak RSS
2779369472 bytes. Its second turn reused 31790 tokens with 1.969-second TTFT.
The four-thread 256/128/F16/compact-SWA configuration acknowledged prefill
cancellation in 5.453 seconds and decode cancellation in 0.062 seconds, then
completed both recovery requests. The exact source/build identities, original
failed attempts and rerun method are recorded in
[windows-context-rerun-method.json](windows-context-rerun-method.json).
The CPU brand was not recorded and is not inferred from the hosted-runner label.

Windows x64 CPU 64K [actual result](windows-cpu-65536-final.json), run
[40425602744](https://github.com/gsmlg-app/lib_llama_cpp/actions/runs/40425602744),
also passed: 64509 prompt tokens, two correct 50-token responses, load
2.953 seconds, TTFT 3728.906 seconds and peak RSS 2997501952 bytes.
Native prefill/decode rates were 17.30 / 4.07 tok/s. The second turn reused
64558 tokens with 3.750-second TTFT. It used four
threads and the same 256/128/F16/compact-SWA baseline, observed real partial
prefill, acknowledged cancellation in 5.484 seconds (decode 0.094 seconds) and
completed both recovery requests. Its prefill/decode rates and complete original
artifact bytes are retained in JSON. Windows CPU 128K remains in progress.

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
  The actual released Linux x64 Vulkan asset separately passed all 15 strict
  GPU cases on RTX 3050 in 74.148 seconds. Its 50-to-100 cancellation trend
  retained eight threads and grew only 4 KiB RSS, with task/cancellation counts
  zero; [summary](released-vulkan-native-summary.json),
  [strict-backend harness diff](released-vulkan-native-wrapper.diff).
  The published Linux x64 CUDA asset then passed the same 15 independent cases
  with required GPU placement in 24.196 seconds. Cancellation 50 to 100 retained
  eight threads and exactly 2944556 KiB RSS; all task/cancellation counts cleared.
  [Summary](released-cuda-native-summary.json) and
  [exact configuration/assertion diff](released-cuda-native-wrapper.diff) retain
  the test identities and evidence digests. Successful subprocess stderr is
  suppressed by the original aggregator; the independent consumer/long runs
  establish 36/36 model offload for this exact artifact and configuration.
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
  The final [Windows gate](windows-cpu-e2e-final.json) at `54df901` then passed:
  11 direct tests (10 real-model, one scripted), four server API tests, all 15
  native cases, and default-name CLI. The latter observed fresh partial prefill
  and recovered after disconnect in 1.485 seconds. Its SIGTERM process termination
  is distinct from native close/cleanup verification.
- Three Windows near-window jobs failed before inference because MSVC's `Platform`
  environment key shadowed Bash's `$PLATFORM`. The workflow now uses
  `TARGET_PLATFORM`; original failures are retained in
  [windows-context-method.json](windows-context-method.json). No long-window pass
  is inferred from their successful DLL builds or model downloads.
- Acceptance tooling now requires positive cached tokens on turn two, propagates
  memory-sampler failures to the caller and types Win64 handles explicitly.
  Native resource regression measures Windows process threads and working set;
  Linux observability tests passed. The Windows 32K/64K reruns each passed all 15 native cases;
  cancellation 50 to 100 retained seven threads and grew only 36 / 24 KiB RSS, with
  all task/cancellation counts zero; see
  [Windows resource results](windows-native-resources-final.json).
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

The [v0.7.5 release](https://github.com/gsmlg-app/lib_llama_cpp/releases/tag/v0.7.5)
is tagged at `7ba54673295800b245960001e4128ebe141fd66a`, after exact-source E2E
(`54df901`, all 13 jobs), all platform CPU builds and package checks.
[Publication audit](publication-audit.json) confirms all nine exact/latest pub.dev
versions are 0.7.5. Each downloaded archive matches its published checksum;
39 public source files and every pubspec match the tag. Packaged Linux x64/ARM64
and Windows CPU libraries match the GitHub archive byte for byte.

The actual CPU archive SHA256 is
`8278ccbcaf4f79389131f90f246e4d7c51bf4f8b3570c02cc591daced99d684f`.
Its [Linux ARM64 consumer](released-cpu-consumer.json) ran on Ubuntu 24.04.5 in
an offline container without native build tools or a mounted source/build tree.
It produced `ready`, `stop`, usage 15 input/2 output tokens, zero active/retained/
pending/buffered work and a successful destroy. The container was removed.
This is short-context published-artifact acceptance, separate from the long tiers.

The released Linux CPU libraries require GLIBC >=2.38 and GLIBCXX >=3.4.32;
Ubuntu 24.04 is the tested clean runtime. An older glibc/libstdc++ installation
does not satisfy these assets merely because the CPU architecture matches.
The [Linux x64 consumer](released-linux-x64-cpu-consumer.json) also passed in an
offline Ubuntu 24.04.5 container without native build tools. Its response took
0.356 seconds, with `ready`, `stop`, usage 15+2=17 and zero own-task/buffer counts.
The container was removed. Upstream slot metrics are advisory sampled snapshots;
their fields are not asserted to become atomically idle with the shim counters.

The [Windows x64 consumer](released-windows-cpu-consumer.json), CI run
[40427512054](https://github.com/gsmlg-app/lib_llama_cpp/actions/runs/40427512054),
passed in an offline Windows Server Core/Python container with no C++ build tools.
The actual release DLL produced `ready`, `stop`, four events and usage 15+2=17;
load was 3.515 seconds, TTFT 0.594 seconds and response duration 0.672 seconds.
Task/buffer/cancellation counts were zero and native destroy returned.
The Microsoft VC++ x64 redistributable was 14.44.35211.0 with a verified Microsoft
signature. Loaded runtime module paths/hashes are recorded: MSVCP140 from System32,
VCRUNTIME140/140_1 from Python and UCRT from System32. The container used `--rm`;
workflow cleanup succeeded. These consumer checks are separate from long-window tests.

The exact successful Linux consumer files are retained in
[release-consumer-fixture](release-consumer-fixture/README.md). Reproduce from the
repository without compiling native code:

```sh
cd docs/validation/gemma4-2026-10-27/release-consumer-fixture
docker build -t libllama-task-cpu-consumer:20261027-v075 .
bash run-cpu-consumer.sh 0.7.5 "$RELEASE_ASSET_DIRECTORY" "$MODEL"
gh workflow run desktop-release-consumer.yml --repo gsmlg-app/lib_llama_cpp \
  --ref main -f version=0.7.5
```

The actual [Linux x64 Vulkan consumer](released-linux-vulkan-consumer.json) also
passed on ms04's discrete RTX 3050 (6 GiB), driver 595.71.05. It used an offline
Ubuntu 24.04.5 runtime with no native build tools, generated `ready`, emitted
`stop` and usage 15+2=17, and cleared task/buffer/cancellation counts before
destroy. Native logs prove **36/36 layers offloaded**, independently of the
requested/compiled backend diagnostics. The NVIDIA container runtime required
X11/Xext/EGL/GLVND runtime libraries and both Vulkan ICD and EGL vendor metadata;
missing metadata caused an explicit required-backend error, never CPU fallback.
Long-window runs of that release asset are recorded separately.

The actual [Linux x64 CUDA consumer](released-linux-cuda-consumer.json) passed
in two offline runtime-only containers: Ubuntu 22.04.4/Python 3.10.12 and
Ubuntu 24.04.5/Python 3.12.3. Both used installed CUDA 12.5 redistributables,
driver 595.71.05 and the same RTX 3050, with no native compilation. Both emitted
`ready`, `stop`, four events and usage 15+2=17, cleared own task/buffer/cancellation
counts, returned from destroy and logged **36/36 layers offloaded**.
The published CUDA library imports libcudart.so.12, libcublas.so.12 and
libcuda.so.1; cuBLAS resolves libcublasLt.so.12 transitively. Its symbol floors
are GLIBC 2.34, GLIBCXX 3.4.30 and CXXABI 1.3.13, unlike the CPU/Vulkan floors.
Runtime module paths, image IDs, archive/library hashes and original log digests
are recorded in that evidence file. The two short consumer runs do not
establish long-window performance.

With matching CUDA runtime/cuBLAS and the driver already installed, reproduce
the published-archive inference without a native compiler using the frozen helper:

```sh
python3 docs/validation/gemma4-2026-10-27/release-consumer-fixture/consumer.py consume \
  --archive "$RELEASE_ASSET_DIRECTORY/lib_llama_cpp-prebuilt-cuda-linux-0.7.5.tar.gz" \
  --checksum-file "$RELEASE_ASSET_DIRECTORY/lib_llama_cpp-prebuilt-cuda-linux-0.7.5.tar.gz.sha256" \
  --member linux/x64/liblib_llama_cpp_linux.so --model "$MODEL" \
  --version 0.7.5 --backend cuda --gpu-layers 99 --output cuda-consumer.json
```

The helper deliberately rejects installed compilers/build tools. Use a runtime
container or clean consumer environment, expose the GPU/driver, and make the
matching runtime libraries visible to the dynamic loader. The recorded runs
disabled container networking and mounted only archive/sidecar, model, helper
and results. No source-built library was substituted.

CUDA runtime distribution uses matching installed NVIDIA redistributables plus
driver; Vulkan uses the system loader/vendor ICD. Accelerated asset builds and
their independent dependency/consumer checks are tracked separately.
All six accelerated build jobs in
[40425353453](https://github.com/gsmlg-app/lib_llama_cpp/actions/runs/40425353453)
completed successfully. The [final public-asset audit](released-native-assets.json)
verified archive/sidecar hashes and static imports for all five Linux/Windows
CPU/CUDA/Vulkan archives (seven native members), independently of inference.
Windows CUDA directly imports `cublas64_12.dll`, `cudart64_12.dll` and
`nvcuda.dll`, plus the Microsoft C++/UCRT runtimes; it has no delay imports.
Install matching NVIDIA runtime/cuBLAS dependencies and the vendor driver,
and make the runtime directories available to DLL loading. Static import
inspection does not verify their resolution or execution on a Windows GPU.
A physical Windows GPU host was unavailable locally.
DGX's Vulkan GPU was confirmed through the native loader and then tested using
an isolated build container, without changing the host driver or source pin.
Accelerator compilation alone does not validate long context.
