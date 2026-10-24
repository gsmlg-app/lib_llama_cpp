#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: test-linux-prebuilt-package.sh <linux-package-dir>" >&2
  exit 64
fi

package_dir="$(cd "$1" && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Copy only the publish package, so a monorepo source fallback cannot hide a
# missing prebuilt. Linking and running also verifies the host architecture.
cp -R "$package_dir" "$tmp_dir/plugin"
cat > "$tmp_dir/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.14)
project(native_package_consumer LANGUAGES CXX)
add_subdirectory(plugin/linux plugin-build)
add_executable(consumer main.cc)
target_link_libraries(consumer PRIVATE ${lib_llama_cpp_linux_bundled_libraries})
EOF
cat > "$tmp_dir/main.cc" <<'EOF'
extern "C" int lib_llama_cpp_stub_abi_version();
extern "C" void llama_backend_init();
extern "C" void llama_backend_free();
int main() {
  if (lib_llama_cpp_stub_abi_version() != 1) return 1;
  llama_backend_init();
  llama_backend_free();
  return 0;
}
EOF

cmake -S "$tmp_dir" -B "$tmp_dir/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$tmp_dir/build" --parallel 2
"$tmp_dir/build/consumer"
echo "Passed standalone Linux package consumer: $(uname -m)"
