#!/usr/bin/env bash
set -euo pipefail

device_id="${IOS_SIMULATOR_ID:-booted}"
tokens="${SMOKE_TOKENS:-4}"

: "${MODEL_PATH:?MODEL_PATH must point to the verified GGUF model}"
: "${SMOKE_PROMPT:?SMOKE_PROMPT must be set}"

llama_cli="$(find build/ios-sim-llama-cpp -type f -name llama-cli -perm -111 2>/dev/null | head -n 1)"
if [[ -z "$llama_cli" ]]; then
  echo "Could not find iOS simulator llama-cli executable."
  find build/ios-sim-llama-cpp -maxdepth 5 -type f | sort
  exit 1
fi

chmod 755 "$llama_cli"

xcrun simctl spawn "$device_id" "$PWD/$llama_cli" \
  -m "$MODEL_PATH" \
  -p "$SMOKE_PROMPT" \
  -n "$tokens" \
  --temp 0 \
  --single-turn \
  2>&1 | tee "$RUNNER_TEMP/ios-llama-output.txt"

grep -Eq 'Generation:' "$RUNNER_TEMP/ios-llama-output.txt"
