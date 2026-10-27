# Published CPU archive consumer fixture

These three files are byte-for-byte copies from the DGX directory used for the
successful v0.7.5 public-release consumer check. The consumer does not compile
native code. See `../released-cpu-consumer.json` for the original environment,
image ID, model hash, results, and scope.

| File | SHA256 |
| --- | --- |
| `consumer.py` | `f467c1e829558e2f235392582bc06262a862c9b2e7d27ec1da7309b6219b14ce` |
| `Dockerfile` | `ce418067963db4327f155ad64f00bf98d472940f0da2538dc72363353ba1893a` |
| `run-cpu-consumer.sh` | `3cea0ef08e46a10ecd14e47df543d6795afa7b0355eef8593c313994c77a5f1b` |

On a Linux ARM64 or x64 Docker host, put the public archive and SHA256 sidecar
in one directory. Use the fixed `google-gemma-4-E2B-it-Q4_K_M.gguf` model with
SHA256 `e6d47b7c6316612da747c4e471d10f5f1b87c8bf6051332d80f4810d69196c64`.
Then run from this fixture directory:

```sh
docker build -t libllama-task-cpu-consumer:20261027-v075 .
bash run-cpu-consumer.sh 0.7.5 /absolute/path/to/assets /absolute/path/to/model.gguf
```

The runner mounts only the archive, sidecar, model, and writable results. It
disables container networking and removes the container after completion.
The consumer checks that compiler/build tools are absent, validates the archive,
loads its architecture-specific CPU library, prepares and streams a short
request, checks usage and native cleanup counters, and destroys the engine.
Results and logs are written under `results/`.

The Dockerfile retains its original mutable Ubuntu base/package inputs. A new
build may therefore have different package versions or an image ID; record its
actual environment. The recorded passing run was Linux ARM64 on DGX-Spark.
This fixture alone does not establish x64, Windows, CUDA, or Vulkan inference.
