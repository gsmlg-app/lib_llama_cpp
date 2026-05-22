#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: download-release-prebuilts.sh <version-or-tag> <output-dir> [cpu|metal|vulkan-linux|vulkan-android|vulkan-windows|cuda-linux|cuda-windows]" >&2
  exit 64
fi

version="${1#v}"
tag="v${version}"
out_dir="$2"
variant="${3:-cpu}"

case "$variant" in
  cpu|metal|vulkan-linux|vulkan-android|vulkan-windows|cuda-linux|cuda-windows)
    ;;
  *)
    echo "Unsupported prebuilt variant: $variant" >&2
    exit 64
    ;;
esac

if [[ "$variant" == "cpu" ]]; then
  archive="lib_llama_cpp-prebuilt-${version}.tar.gz"
else
  archive="lib_llama_cpp-prebuilt-${variant}-${version}.tar.gz"
fi
checksum="${archive}.sha256"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

for attempt in $(seq 1 80); do
  if gh release download "$tag" \
    --pattern "$archive" \
    --pattern "$checksum" \
    --dir "$tmp_dir" \
    --clobber; then
    break
  fi

  if [[ "$attempt" == "80" ]]; then
    echo "Timed out waiting for $archive on GitHub release $tag." >&2
    exit 1
  fi

  echo "Waiting for GitHub release prebuilts for $tag (attempt $attempt/80)."
  sleep 15
done

(
  cd "$tmp_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$checksum"
  else
    shasum -a 256 -c "$checksum"
  fi
)

rm -rf "$out_dir"
mkdir -p "$out_dir"
tar -xzf "${tmp_dir}/${archive}" -C "$out_dir"
