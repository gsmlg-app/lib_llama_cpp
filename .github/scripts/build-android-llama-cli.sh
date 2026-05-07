#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME must be set}"

android_ndk_home="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.0.12077973}"
android_abi="${ANDROID_ABI:-x86_64}"
android_platform="${ANDROID_PLATFORM:-android-24}"
build_dir="${ANDROID_LLAMA_BUILD_DIR:-build/android-llama-cpp}"

cmake -S third_party/llama.cpp -B "$build_dir" \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$android_ndk_home/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$android_abi" \
  -DANDROID_PLATFORM="$android_platform" \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_METAL=OFF \
  -DGGML_OPENMP=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF

cmake --build "$build_dir" --target llama-cli --parallel "${BUILD_PARALLELISM:-2}"

find "$build_dir" -type f -name llama-cli -perm -111 -print
