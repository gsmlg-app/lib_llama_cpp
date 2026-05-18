#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: build-native-prebuilt.sh <linux|android|macos|ios> <output-dir>

Builds native lib_llama_cpp binaries from the checked-out third_party/llama.cpp
source tree into a release artifact layout. Set LIB_LLAMA_CPP_ENABLE_CUDA=ON,
LIB_LLAMA_CPP_ENABLE_VULKAN=ON, or LIB_LLAMA_CPP_CMAKE_ARGS for GPU variants.
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 64
fi

platform="$1"
out_dir="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${LIB_LLAMA_CPP_PREBUILD_BUILD_DIR:-${repo_root}/build/prebuilt}"

cmake_parallel="${LIB_LLAMA_CPP_CMAKE_PARALLEL:-2}"
cmake_generator="${LIB_LLAMA_CPP_CMAKE_GENERATOR:-Ninja}"
cmake_backend_args=()

append_cmake_bool_arg() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    cmake_backend_args+=("-D${name}=${value}")
  fi
}

append_cmake_bool_arg LIB_LLAMA_CPP_ENABLE_METAL
append_cmake_bool_arg LIB_LLAMA_CPP_ENABLE_CUDA
append_cmake_bool_arg LIB_LLAMA_CPP_ENABLE_VULKAN

if [[ -n "${LIB_LLAMA_CPP_CMAKE_ARGS:-}" ]]; then
  read -r -a _lib_llama_cpp_extra_cmake_args <<< "$LIB_LLAMA_CPP_CMAKE_ARGS"
  cmake_backend_args+=("${_lib_llama_cpp_extra_cmake_args[@]}")
fi

run_cmake() {
  local cmake_args=("$@")
  if (( ${#cmake_backend_args[@]} > 0 )); then
    cmake_args+=("${cmake_backend_args[@]}")
  fi
  cmake "${cmake_args[@]}"
}

mkdir -p "$out_dir" "$build_root"

find_built_file() {
  local build_dir="$1"
  local name="$2"
  local found

  found="$(find "$build_dir" -type f -name "$name" | head -n 1)"
  if [[ -z "$found" ]]; then
    echo "Could not find $name under $build_dir" >&2
    find "$build_dir" -maxdepth 5 -type f | sort >&2
    exit 1
  fi
  printf '%s\n' "$found"
}

strip_elf() {
  local file="$1"
  if command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$file" 2>/dev/null || strip "$file" || true
  fi
}

strip_macho() {
  local file="$1"
  if command -v strip >/dev/null 2>&1; then
    strip -x "$file" || true
  fi
}

build_linux() {
  local build_dir="${build_root}/linux-x64"
  local dst="${out_dir}/linux/x64"

  run_cmake -S "${repo_root}/packages/lib_llama_cpp_linux/src" \
    -B "$build_dir" \
    -G "$cmake_generator" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$build_dir" --target lib_llama_cpp_linux --parallel "$cmake_parallel"

  mkdir -p "$dst"
  cp "$(find_built_file "$build_dir" "liblib_llama_cpp_linux.so")" \
    "${dst}/liblib_llama_cpp_linux.so"
  strip_elf "${dst}/liblib_llama_cpp_linux.so"
}

android_ndk_dir() {
  local ndk_dir="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [[ -z "$ndk_dir" || ! -f "${ndk_dir}/build/cmake/android.toolchain.cmake" ]]; then
    echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point at an installed Android NDK." >&2
    exit 1
  fi
  printf '%s\n' "$ndk_dir"
}

android_strip() {
  local ndk_dir="$1"
  local file="$2"
  local strip_bin

  strip_bin="$(find "${ndk_dir}/toolchains/llvm/prebuilt" \
    \( -type f -o -type l \) -name llvm-strip | head -n 1)"
  if [[ -z "$strip_bin" ]]; then
    echo "Could not find llvm-strip under ${ndk_dir}/toolchains/llvm/prebuilt" >&2
    exit 1
  fi

  "$strip_bin" --strip-unneeded "$file"
}

build_android() {
  local ndk_dir
  ndk_dir="$(android_ndk_dir)"

  local abis="${ANDROID_ABIS:-armeabi-v7a arm64-v8a x86_64}"
  local default_android_platform="android-24"
  if [[ "${LIB_LLAMA_CPP_ENABLE_VULKAN:-OFF}" == "ON" ]]; then
    default_android_platform="android-28"
  fi
  local android_platform="${ANDROID_PLATFORM:-$default_android_platform}"
  local android_api_level="${android_platform#android-}"
  for abi in $abis; do
    local build_dir="${build_root}/android-${abi}"
    local dst="${out_dir}/android/${abi}"

    local vulkan_sdk="${VULKAN_SDK:-}"
    local vulkan_args=()
    if [[ -n "$vulkan_sdk" ]]; then
      local vulkan_include_dir="${vulkan_sdk}/include"
      if [[ "$vulkan_include_dir" == "/usr/include" ]]; then
        local vulkan_overlay_dir="${build_dir}/vulkan-host-headers"
        mkdir -p "${vulkan_overlay_dir}/include"
        for include_name in vulkan spirv; do
          if [[ -d "${vulkan_include_dir}/${include_name}" ]]; then
            ln -sfn "${vulkan_include_dir}/${include_name}" "${vulkan_overlay_dir}/include/${include_name}"
          fi
        done
        vulkan_include_dir="${vulkan_overlay_dir}/include"
      fi
      # The NDK doesn't ship the C++ vulkan.hpp wrapper, so we point
      # FindVulkan at the host Vulkan headers. We must also relax the
      # toolchain's find-root-path restrictions to allow discovery of
      # host include/lib paths alongside the NDK sysroot.
      vulkan_args+=(
        "-DVulkan_INCLUDE_DIR=${vulkan_include_dir}"
        "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS:-} -I${vulkan_include_dir}"
        "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
        "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
      )
      # Use the NDK's libvulkan.so for the target ABI
      local ndk_sysroot
      ndk_sysroot="$(find "${ndk_dir}/toolchains/llvm/prebuilt" \
        -type d -path '*/sysroot' | head -n 1)"
      local vulkan_triple=""
      case "$abi" in
        arm64-v8a)   vulkan_triple="aarch64-linux-android" ;;
        armeabi-v7a) vulkan_triple="arm-linux-androideabi" ;;
        x86_64)      vulkan_triple="x86_64-linux-android" ;;
        x86)         vulkan_triple="i686-linux-android" ;;
      esac
      if [[ -n "$ndk_sysroot" && -n "$vulkan_triple" ]]; then
        local vulkan_lib="${ndk_sysroot}/usr/lib/${vulkan_triple}/${android_api_level}/libvulkan.so"
        if [[ -f "$vulkan_lib" ]]; then
          vulkan_args+=("-DVulkan_LIBRARY=${vulkan_lib}")
        fi
      fi
    fi

    run_cmake -S "${repo_root}/packages/lib_llama_cpp_android/src" \
      -B "$build_dir" \
      -G "$cmake_generator" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="${ndk_dir}/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$abi" \
      -DANDROID_PLATFORM="$android_platform" \
      "${vulkan_args[@]}"
    cmake --build "$build_dir" --target lib_llama_cpp_android --parallel "$cmake_parallel"

    mkdir -p "$dst"
    cp "$(find_built_file "$build_dir" "liblib_llama_cpp_android.so")" \
      "${dst}/liblib_llama_cpp_android.so"
    android_strip "$ndk_dir" "${dst}/liblib_llama_cpp_android.so"
  done
}

write_framework_plist() {
  local plist="$1"
  local executable="$2"
  local identifier="$3"
  local minimum_key="$4"
  local minimum_value="$5"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${executable}</string>
  <key>CFBundleIdentifier</key>
  <string>${identifier}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${executable}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>${minimum_key}</key>
  <string>${minimum_value}</string>
</dict>
</plist>
EOF
}

create_shallow_framework() {
  local dylib="$1"
  local framework_dir="$2"
  local executable="$3"
  local identifier="$4"
  local minimum_key="$5"
  local minimum_value="$6"

  rm -rf "$framework_dir"
  mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"
  cp "$dylib" "${framework_dir}/${executable}"
  strip_macho "${framework_dir}/${executable}"
  install_name_tool -id "@rpath/${executable}.framework/${executable}" \
    "${framework_dir}/${executable}" || true
  write_framework_plist "${framework_dir}/Info.plist" \
    "$executable" "$identifier" "$minimum_key" "$minimum_value"
  cat > "${framework_dir}/Modules/module.modulemap" <<EOF
framework module ${executable} {
  umbrella header "${executable}.h"
  export *
  module * { export * }
}
EOF
  cat > "${framework_dir}/Headers/${executable}.h" <<EOF
#pragma once
int lib_llama_cpp_stub_abi_version(void);
EOF
  codesign --force --sign - "${framework_dir}/${executable}" >/dev/null 2>&1 || true
}

create_macos_framework() {
  local dylib="$1"
  local framework_dir="$2"
  local executable="$3"
  local identifier="$4"
  local minimum_key="$5"
  local minimum_value="$6"
  local version_dir="${framework_dir}/Versions/A"

  rm -rf "$framework_dir"
  mkdir -p "${version_dir}/Headers" "${version_dir}/Modules" \
    "${version_dir}/Resources"
  cp "$dylib" "${version_dir}/${executable}"
  strip_macho "${version_dir}/${executable}"
  install_name_tool -id "@rpath/${executable}.framework/Versions/A/${executable}" \
    "${version_dir}/${executable}" || true
  write_framework_plist "${version_dir}/Resources/Info.plist" \
    "$executable" "$identifier" "$minimum_key" "$minimum_value"
  cat > "${version_dir}/Modules/module.modulemap" <<EOF
framework module ${executable} {
  umbrella header "${executable}.h"
  export *
  module * { export * }
}
EOF
  cat > "${version_dir}/Headers/${executable}.h" <<EOF
#pragma once
int lib_llama_cpp_stub_abi_version(void);
EOF
  ln -s A "${framework_dir}/Versions/Current"
  ln -s Versions/Current/${executable} "${framework_dir}/${executable}"
  ln -s Versions/Current/Headers "${framework_dir}/Headers"
  ln -s Versions/Current/Modules "${framework_dir}/Modules"
  ln -s Versions/Current/Resources "${framework_dir}/Resources"
  codesign --force --sign - "${version_dir}/${executable}" >/dev/null 2>&1 || true
}

build_macos() {
  local build_dir="${build_root}/macos-universal"
  local framework_dir="${build_dir}/framework/lib_llama_cpp_macos.framework"
  local dst="${out_dir}/macos"

  run_cmake -S "${repo_root}/packages/lib_llama_cpp_macos/src" \
    -B "$build_dir" \
    -G "$cmake_generator" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
  cmake --build "$build_dir" --target lib_llama_cpp_macos --parallel "$cmake_parallel"

  create_macos_framework \
    "$(find_built_file "$build_dir" "liblib_llama_cpp_macos.dylib")" \
    "$framework_dir" \
    "lib_llama_cpp_macos" \
    "com.gsmlg.libllamacpp.macos" \
    "LSMinimumSystemVersion" \
    "10.15"

  mkdir -p "$dst"
  rm -rf "${dst}/lib_llama_cpp_macos.xcframework"
  xcodebuild -create-xcframework \
    -framework "$framework_dir" \
    -output "${dst}/lib_llama_cpp_macos.xcframework"
}

build_ios_slice() {
  local sdk="$1"
  local archs="$2"
  local build_dir="$3"
  local framework_dir="$4"

  run_cmake -S "${repo_root}/packages/lib_llama_cpp_ios/src" \
    -B "$build_dir" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  cmake --build "$build_dir" --config Release --target lib_llama_cpp_ios --parallel "$cmake_parallel"

  create_shallow_framework \
    "$(find_built_file "$build_dir" "liblib_llama_cpp_ios.dylib")" \
    "$framework_dir" \
    "lib_llama_cpp_ios" \
    "com.gsmlg.libllamacpp.ios" \
    "MinimumOSVersion" \
    "13.0"
}

build_ios() {
  local device_build="${build_root}/ios-device"
  local simulator_build="${build_root}/ios-simulator"
  local device_framework="${device_build}/framework/lib_llama_cpp_ios.framework"
  local simulator_framework="${simulator_build}/framework/lib_llama_cpp_ios.framework"
  local dst="${out_dir}/ios"

  build_ios_slice iphoneos arm64 "$device_build" "$device_framework"
  build_ios_slice iphonesimulator "arm64;x86_64" "$simulator_build" "$simulator_framework"

  mkdir -p "$dst"
  rm -rf "${dst}/lib_llama_cpp_ios.xcframework"
  xcodebuild -create-xcframework \
    -framework "$device_framework" \
    -framework "$simulator_framework" \
    -output "${dst}/lib_llama_cpp_ios.xcframework"
}

case "$platform" in
  linux)
    build_linux
    ;;
  android)
    build_android
    ;;
  macos)
    build_macos
    ;;
  ios)
    build_ios
    ;;
  *)
    usage
    exit 64
    ;;
esac
