#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: install-prebuilt-packages.sh <prebuilt-dir>" >&2
  exit 64
fi

prebuilt_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

require_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required prebuilt artifact: $path" >&2
    exit 1
  fi
}

require_path "${prebuilt_dir}/android/armeabi-v7a/liblib_llama_cpp_android.so"
require_path "${prebuilt_dir}/android/arm64-v8a/liblib_llama_cpp_android.so"
require_path "${prebuilt_dir}/android/x86_64/liblib_llama_cpp_android.so"
require_path "${prebuilt_dir}/ios/lib_llama_cpp_ios.xcframework"
require_path "${prebuilt_dir}/linux/x64/liblib_llama_cpp_linux.so"
require_path "${prebuilt_dir}/macos/lib_llama_cpp_macos.xcframework"
require_path "${prebuilt_dir}/windows/x64/lib_llama_cpp_windows.dll"

rm -rf "${repo_root}/packages/lib_llama_cpp_android/android/src/main/jniLibs"
mkdir -p "${repo_root}/packages/lib_llama_cpp_android/android/src/main"
cp -R "${prebuilt_dir}/android" \
  "${repo_root}/packages/lib_llama_cpp_android/android/src/main/jniLibs"

rm -rf "${repo_root}/packages/lib_llama_cpp_ios/ios/Frameworks"
mkdir -p "${repo_root}/packages/lib_llama_cpp_ios/ios/Frameworks"
cp -R "${prebuilt_dir}/ios/lib_llama_cpp_ios.xcframework" \
  "${repo_root}/packages/lib_llama_cpp_ios/ios/Frameworks/"

rm -rf "${repo_root}/packages/lib_llama_cpp_linux/linux/prebuilt"
mkdir -p "${repo_root}/packages/lib_llama_cpp_linux/linux/prebuilt"
cp -R "${prebuilt_dir}/linux/." \
  "${repo_root}/packages/lib_llama_cpp_linux/linux/prebuilt/"

rm -rf "${repo_root}/packages/lib_llama_cpp_macos/macos/Frameworks"
mkdir -p "${repo_root}/packages/lib_llama_cpp_macos/macos/Frameworks"
cp -R "${prebuilt_dir}/macos/lib_llama_cpp_macos.xcframework" \
  "${repo_root}/packages/lib_llama_cpp_macos/macos/Frameworks/"

rm -rf "${repo_root}/packages/lib_llama_cpp_windows/windows/prebuilt"
mkdir -p "${repo_root}/packages/lib_llama_cpp_windows/windows/prebuilt"
cp -R "${prebuilt_dir}/windows/." \
  "${repo_root}/packages/lib_llama_cpp_windows/windows/prebuilt/"

echo "Installed native prebuilts into platform packages."
