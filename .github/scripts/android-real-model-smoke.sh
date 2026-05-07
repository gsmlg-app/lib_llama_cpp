#!/usr/bin/env bash
set -euo pipefail

device_id="${ANDROID_EMULATOR_ID:-emulator-5554}"
remote_dir="/data/local/tmp/lib_llama_cpp_e2e"
tokens="${SMOKE_TOKENS:-4}"

: "${MODEL_PATH:?MODEL_PATH must point to the verified GGUF model}"
: "${SMOKE_PROMPT:?SMOKE_PROMPT must be set}"

llama_cli="$(find build/android-llama-cpp -type f -name llama-cli -perm -111 2>/dev/null | head -n 1)"
if [[ -z "$llama_cli" ]]; then
  echo "Could not find Android llama-cli executable."
  find build/android-llama-cpp -maxdepth 5 -type f | sort
  exit 1
fi

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
adb -s "$device_id" push "$llama_cli" "$remote_dir/llama-cli"
adb -s "$device_id" push "$MODEL_PATH" "$remote_dir/model.gguf"
adb -s "$device_id" shell "chmod 755 '$remote_dir/llama-cli'"

remote_prompt="$(printf '%q' "$SMOKE_PROMPT")"
adb -s "$device_id" shell \
  "cd '$remote_dir' && ./llama-cli -m model.gguf -p $remote_prompt -n $tokens --temp 0 --single-turn" \
  2>&1 | tee "$RUNNER_TEMP/android-llama-output.txt"

grep -Eq 'Generation:' "$RUNNER_TEMP/android-llama-output.txt"
