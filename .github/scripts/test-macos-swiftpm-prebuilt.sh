#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: test-macos-swiftpm-prebuilt.sh <macos-package-dir>" >&2
  exit 64
fi

package_dir="$(cd "$1" && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lib-llama-cpp-swiftpm.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

# Model pub's directory-symlink expansion, while preserving archive bytes.
cp -RL "$package_dir" "${tmp_dir}/lib_llama_cpp_macos"
macos_dir="${tmp_dir}/lib_llama_cpp_macos/macos"
archive="${macos_dir}/lib_llama_cpp_macos/Frameworks/lib_llama_cpp_macos.xcframework.zip"
python3 - "$archive" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    path = (
        'lib_llama_cpp_macos.xcframework/macos-arm64_x86_64/'
        'lib_llama_cpp_macos.framework/Versions/Current'
    )
    entry = archive.getinfo(path)
    assert stat.S_ISLNK(entry.external_attr >> 16), 'Current must remain a symlink in the archive'
    assert archive.read(path) == b'A', 'Current must resolve to Versions/A'
PY

for layout in nested legacy; do
  consumer="${tmp_dir}/consumer-${layout}"
  mkdir -p "${consumer}/Sources/Consumer"
  if [[ "$layout" == nested ]]; then
    dependency_path="${macos_dir}/lib_llama_cpp_macos"
    identity="lib_llama_cpp_macos"
    product="lib-llama-cpp-macos"
  else
    dependency_path="$macos_dir"
    identity="macos"
    product="lib_llama_cpp_macos"
  fi
  cat > "${consumer}/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.macOS("10.15")],
    dependencies: [.package(path: "${dependency_path}")],
    targets: [.executableTarget(
        name: "Consumer",
        dependencies: [.product(name: "${product}", package: "${identity}")]
    )]
)
EOF
  printf '%s\n' 'import lib_llama_cpp_macos' \
    'precondition(lib_llama_cpp_stub_abi_version() == 1)' \
    'print("macOS SwiftPM binary archive consumer")' \
    > "${consumer}/Sources/Consumer/main.swift"
  swift build --package-path "$consumer" > "${consumer}/build.log" 2>&1 || {
    cat "${consumer}/build.log" >&2
    exit 1
  }
  cat "${consumer}/build.log"
  if grep -q "Couldn't resolve framework symlink" "${consumer}/build.log"; then
    echo "SwiftPM reported a malformed framework symlink ($layout)." >&2
    exit 1
  fi
  current="$(find "${consumer}/.build/artifacts" -path '*/Versions/Current' -print -quit)"
  if [[ ! -L "$current" || "$(readlink "$current")" != A ]]; then
    echo "SwiftPM did not restore the framework Current symlink ($layout)." >&2
    exit 1
  fi
  # SwiftPM command-line executables do not embed dynamic frameworks as apps do.
  binary_dir="$(swift build --package-path "$consumer" --show-bin-path)"
  framework_search_dir="$(dirname "$(dirname "$(dirname "$current")")")"
  DYLD_FRAMEWORK_PATH="$framework_search_dir" "${binary_dir}/Consumer"
  echo "Passed macOS SwiftPM archive consumer: $layout"
done
