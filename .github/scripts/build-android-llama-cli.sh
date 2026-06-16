#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME must be set}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
llama_cpp_dir="${repo_root}/third_party/llama.cpp"
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

apply_llama_cpp_ci_patches() {
  local patch_file="${repo_root}/.github/patches/llama-vulkan-core-16bit-storage.patch"
  if [[ ! -f "$patch_file" ]]; then
    return
  fi
  if git -C "$llama_cpp_dir" apply --unidiff-zero --reverse --check "$patch_file" >/dev/null 2>&1; then
    return
  fi
  git -C "$llama_cpp_dir" apply --unidiff-zero "$patch_file"
}

if [[ "$enable_vulkan" == "ON" && -n "${VULKAN_SDK:-}" ]]; then
  apply_llama_cpp_ci_patches

  vulkan_include_dir="${VULKAN_SDK}/include"
  spirv_headers_dir="${VULKAN_SDK}/share/cmake/SPIRV-Headers"
  if [[ "$vulkan_include_dir" == "/usr/include" ]]; then
    vulkan_overlay_dir="${build_dir}/vulkan-host-headers"
    mkdir -p "${vulkan_overlay_dir}/include"
    for include_name in vulkan spirv vk_video; do
      if [[ -d "${vulkan_include_dir}/${include_name}" ]]; then
        ln -sfn "${vulkan_include_dir}/${include_name}" "${vulkan_overlay_dir}/include/${include_name}"
      fi
    done
    vulkan_include_dir="${vulkan_overlay_dir}/include"
  fi
  if [[ ! -d "$spirv_headers_dir" ]]; then
    spirv_headers_dir="$(find /usr -path '*/SPIRV-HeadersConfig.cmake' -exec dirname {} \; -quit 2>/dev/null || true)"
  fi
  cxx_flags="${CMAKE_CXX_FLAGS:-} -I${vulkan_include_dir} -DVULKAN_HPP_TYPESAFE_CONVERSION=1"
  vulkan_args+=(
    "-DVulkan_INCLUDE_DIR=${vulkan_include_dir}"
    "-DCMAKE_CXX_FLAGS=${cxx_flags}"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
  )
  if [[ -n "$spirv_headers_dir" ]]; then
    vulkan_args+=("-DSPIRV-Headers_DIR=${spirv_headers_dir}")
  fi

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

cmake -S "$llama_cpp_dir" -B "$build_dir" \
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
