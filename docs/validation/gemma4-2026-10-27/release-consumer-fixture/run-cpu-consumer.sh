#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: run-cpu-consumer.sh VERSION ASSET_DIRECTORY MODEL_GGUF' >&2; exit 64; }
version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
asset_dir="$(realpath "$2")"
model="$(realpath "$3")"
task_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
archive="lib_llama_cpp-prebuilt-${version}.tar.gz"
case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) exit 64 ;; esac
[[ -f "$asset_dir/$archive" && -f "$asset_dir/$archive.sha256" && -f "$model" ]]
mkdir -p "$task_dir/results"
legacy=()
if [[ "$version" == 0.7.4 ]]; then legacy=(--legacy-v074); fi
docker run --rm --name "libllama-20261027-consumer-cpu-${version//./-}" --network none \
  --mount "type=bind,src=$asset_dir/$archive,dst=/input/$archive,readonly" \
  --mount "type=bind,src=$asset_dir/$archive.sha256,dst=/input/$archive.sha256,readonly" \
  --mount "type=bind,src=$model,dst=/input/model.gguf,readonly" \
  --mount "type=bind,src=$task_dir/results,dst=/results" \
  libllama-task-cpu-consumer:20261027-v075 consume \
  --archive "/input/$archive" --checksum-file "/input/$archive.sha256" \
  --member "linux/$arch/liblib_llama_cpp_linux.so" --model /input/model.gguf \
  --version "$version" --backend cpu --gpu-layers 0 "${legacy[@]}" \
  --output "/results/cpu-${arch}-${version}.json" \
  2>&1 | tee "$task_dir/results/cpu-${arch}-${version}.log"
