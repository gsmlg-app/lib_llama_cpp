#!/usr/bin/env bash
set -euo pipefail

device_id="${ANDROID_EMULATOR_ID:-emulator-5554}"
remote_model_path="${LIB_LLAMA_CPP_TEST_MODEL:-/data/local/tmp/lib_llama_cpp_e2e/model.gguf}"
remote_dir="$(dirname "$remote_model_path")"
tokens="${SMOKE_TOKENS:-4}"
gpu_layers="${LIB_LLAMA_CPP_TEST_GPU_LAYERS:-0}"

: "${MODEL_PATH:?MODEL_PATH must point to the verified GGUF model}"
: "${SMOKE_PROMPT:?SMOKE_PROMPT must be set}"

llama_bin="$(find build/android-llama-cpp -type f \( -name llama-cli -o -name llama-simple \) -perm -111 2>/dev/null | sort | head -n 1)"
if [[ -z "$llama_bin" ]]; then
  echo "Could not find Android llama.cpp smoke executable."
  find build/android-llama-cpp -maxdepth 5 -type f | sort
  exit 1
fi
llama_tool="$(basename "$llama_bin")"

adb kill-server || true
adb start-server
adb -s "$device_id" wait-for-device

wait_for_service() {
  local service="$1"
  local attempts=0

  until adb -s "$device_id" shell service check "$service" 2>/dev/null | grep -q found; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 90 ]]; then
      adb -s "$device_id" shell service check "$service" || true
      return 1
    fi
    sleep 2
  done
}

wait_for_service package
wait_for_service activity

adb -s "$device_id" shell "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
adb -s "$device_id" push "$llama_bin" "$remote_dir/$llama_tool"
adb -s "$device_id" push "$MODEL_PATH" "$remote_model_path"
adb -s "$device_id" shell "chmod 755 '$remote_dir/$llama_tool'"

remote_prompt="$(printf '%q' "$SMOKE_PROMPT")"
if [[ "$llama_tool" == "llama-cli" ]]; then
  adb -s "$device_id" shell \
    "cd '$remote_dir' && ./llama-cli -m '$remote_model_path' -p $remote_prompt -n $tokens --temp 0 --gpu-layers $gpu_layers --single-turn" \
    2>&1 | tee "$RUNNER_TEMP/android-llama-output.txt"
  grep -Eq 'Generation:' "$RUNNER_TEMP/android-llama-output.txt"
else
  adb -s "$device_id" shell \
    "cd '$remote_dir' && ./llama-simple -m '$remote_model_path' -n $tokens -ngl $gpu_layers $remote_prompt" \
    2>&1 | tee "$RUNNER_TEMP/android-llama-output.txt"
  test -s "$RUNNER_TEMP/android-llama-output.txt"
fi

if [[ "$gpu_layers" != "0" ]]; then
  grep -Eq 'ggml_vulkan|Vulkan[0-9]|assigned to device Vulkan|offloaded [0-9]+/[0-9]+ layers to GPU' \
    "$RUNNER_TEMP/android-llama-output.txt"
fi
