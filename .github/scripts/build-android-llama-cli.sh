#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME must be set}"

android_ndk_home="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.0.12077973}"
android_abi="${ANDROID_ABI:-x86_64}"
build_dir="${ANDROID_LLAMA_BUILD_DIR:-build/android-llama-cpp}"
enable_vulkan="${LIB_LLAMA_CPP_ENABLE_VULKAN:-OFF}"
default_android_platform="android-24"
if [[ "$enable_vulkan" == "ON" ]]; then
  default_android_platform="android-28"
fi
android_platform="${ANDROID_PLATFORM:-$default_android_platform}"
android_api_level="${android_platform#android-}"
vulkan_args=("-DGGML_VULKAN=$enable_vulkan")

if [[ "$enable_vulkan" == "ON" && -n "${VULKAN_SDK:-}" ]]; then
  vulkan_include_dir="${VULKAN_SDK}/include"
  vulkan_args+=(
    "-DVulkan_INCLUDE_DIR=${vulkan_include_dir}"
    "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS:-} -I${vulkan_include_dir}"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
  )

  ndk_sysroot="$(find "$android_ndk_home/toolchains/llvm/prebuilt" \
    -type d -path '*/sysroot' | head -n 1)"
  case "$android_abi" in
    arm64-v8a)   vulkan_triple="aarch64-linux-android" ;;
    armeabi-v7a) vulkan_triple="arm-linux-androideabi" ;;
    x86_64)      vulkan_triple="x86_64-linux-android" ;;
    x86)         vulkan_triple="i686-linux-android" ;;
    *)           vulkan_triple="" ;;
  esac

  if [[ -n "$ndk_sysroot" && -n "$vulkan_triple" ]]; then
    vulkan_library="${ndk_sysroot}/usr/lib/${vulkan_triple}/${android_api_level}/libvulkan.so"
    if [[ -f "$vulkan_library" ]]; then
      vulkan_args+=("-DVulkan_LIBRARY=${vulkan_library}")
    fi
  fi
fi

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
  "${vulkan_args[@]}" \
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
