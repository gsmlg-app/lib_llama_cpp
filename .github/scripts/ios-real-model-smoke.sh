#!/usr/bin/env bash
set -euo pipefail

device_id="${IOS_SIMULATOR_ID:-booted}"
tokens="${SMOKE_TOKENS:-4}"

: "${MODEL_PATH:?MODEL_PATH must point to the verified GGUF model}"
: "${SMOKE_PROMPT:?SMOKE_PROMPT must be set}"

llama_bin="$(find build/ios-sim-llama-cpp -type f \( -name llama-cli -o -name llama-simple \) -perm -111 2>/dev/null | sort | head -n 1)"
if [[ -z "$llama_bin" ]]; then
  echo "Could not find iOS simulator llama.cpp smoke executable."
  find build/ios-sim-llama-cpp -maxdepth 5 -type f | sort
  exit 1
fi
llama_tool="$(basename "$llama_bin")"

chmod 755 "$llama_bin"

if [[ "$llama_tool" == "llama-cli" ]]; then
  xcrun simctl spawn "$device_id" "$PWD/$llama_bin" \
    -m "$MODEL_PATH" \
    -p "$SMOKE_PROMPT" \
    -n "$tokens" \
    --temp 0 \
    --single-turn \
    2>&1 | tee "$RUNNER_TEMP/ios-llama-output.txt"
  grep -Eq 'Generation:' "$RUNNER_TEMP/ios-llama-output.txt"
else
  xcrun simctl spawn "$device_id" "$PWD/$llama_bin" \
    -m "$MODEL_PATH" \
    -p "$SMOKE_PROMPT" \
    2>&1 | tee "$RUNNER_TEMP/ios-llama-output.txt"
  test -s "$RUNNER_TEMP/ios-llama-output.txt"
fi
