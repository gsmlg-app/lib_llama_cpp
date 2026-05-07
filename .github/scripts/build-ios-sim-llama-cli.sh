#!/usr/bin/env bash
set -euo pipefail

ios_arch="${IOS_SIMULATOR_ARCH:-$(uname -m)}"
ios_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
build_dir="${IOS_LLAMA_BUILD_DIR:-build/ios-sim-llama-cpp}"

cmake -S third_party/llama.cpp -B "$build_dir" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$ios_sdk" \
  -DCMAKE_OSX_ARCHITECTURES="$ios_arch" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_METAL=OFF \
  -DGGML_OPENMP=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF

if ! cmake --build "$build_dir" --target llama-cli --parallel "${BUILD_PARALLELISM:-2}"; then
  cmake --build "$build_dir" --target llama-simple --parallel "${BUILD_PARALLELISM:-2}"
fi

find "$build_dir" -type f \( -name llama-cli -o -name llama-simple \) -perm -111 -print
