#!/usr/bin/env bash
set -euo pipefail

device_id="${ANDROID_EMULATOR_ID:-emulator-5554}"

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

cd example
flutter drive \
  --no-pub \
  --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/mobile_smoke_test.dart \
  -d "$device_id"
