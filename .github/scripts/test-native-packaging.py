#!/usr/bin/env python3
"""Exercise native package installation without a monorepo source fallback."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[2]


class NativePackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / ".github/scripts"
        scripts.mkdir(parents=True)
        for name in ("build-native-prebuilt.sh", "install-prebuilt-packages.sh"):
            shutil.copy2(REPO_ROOT / ".github/scripts" / name, scripts / name)
        self.prebuilt = self.root / "prebuilt"
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            self.write(f"android/{abi}/liblib_llama_cpp_android.so")
        for arch in ("x64", "arm64"):
            self.write(f"linux/{arch}/liblib_llama_cpp_linux.so")
        self.write("windows/x64/lib_llama_cpp_windows.dll")
        self.write("ios/lib_llama_cpp_ios.xcframework/Info.plist")
        framework = (
            "macos/lib_llama_cpp_macos.xcframework/macos-arm64_x86_64/"
            "lib_llama_cpp_macos.framework"
        )
        self.write(f"{framework}/Versions/A/Resources/Info.plist")
        self.write(f"{framework}/Versions/A/lib_llama_cpp_macos")
        for name in ("Headers", "Modules"):
            (self.prebuilt / framework / "Versions/A" / name).mkdir()
        (self.prebuilt / framework / "Versions/Current").symlink_to("A")
        for name in ("Headers", "Modules", "Resources", "lib_llama_cpp_macos"):
            (self.prebuilt / framework / name).symlink_to(f"Versions/Current/{name}")

    def write(self, name):
        path = self.prebuilt / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")

    def install(self):
        return subprocess.run(
            ["bash", str(self.root / ".github/scripts/install-prebuilt-packages.sh"),
             str(self.prebuilt)],
            text=True, capture_output=True,
        )

    def test_linux_build_uses_host_architecture(self):
        tools = self.root / "bin"
        tools.mkdir()
        commands = {
            "uname": '#!/bin/sh\nprintf "%s\\n" "$TEST_MACHINE"\n',
            "strip": "#!/bin/sh\nexit 0\n",
            "cmake": """#!/bin/sh
if [ "$1" = --build ]; then
  mkdir -p "$2"
  touch "$2/liblib_llama_cpp_linux.so"
fi
""",
        }
        for name, contents in commands.items():
            command = tools / name
            command.write_text(contents)
            command.chmod(0o755)
        for machine, arch in (("x86_64", "x64"), ("aarch64", "arm64")):
            with self.subTest(machine=machine):
                output = self.root / f"output-{machine}"
                result = subprocess.run(
                    ["bash", str(self.root / ".github/scripts/build-native-prebuilt.sh"),
                     "linux", str(output)],
                    env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                         "TEST_MACHINE": machine},
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((output / f"linux/{arch}/liblib_llama_cpp_linux.so").is_file())

    def test_install_rejects_missing_linux_arm64(self):
        (self.prebuilt / "linux/arm64/liblib_llama_cpp_linux.so").unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linux/arm64/liblib_llama_cpp_linux.so", result.stderr)

    def test_install_preserves_macos_symlinks_in_swiftpm_archive(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = (
            self.root / "packages/lib_llama_cpp_macos/macos/lib_llama_cpp_macos/"
            "Frameworks/lib_llama_cpp_macos.xcframework.zip"
        )
        with zipfile.ZipFile(archive) as package:
            prefix = (
                "lib_llama_cpp_macos.xcframework/macos-arm64_x86_64/"
                "lib_llama_cpp_macos.framework/"
            )
            for name, target in (
                ("Versions/Current", "A"),
                ("lib_llama_cpp_macos", "Versions/Current/lib_llama_cpp_macos"),
            ):
                entry = package.getinfo(prefix + name)
                self.assertTrue(stat.S_ISLNK(entry.external_attr >> 16))
                self.assertEqual(package.read(entry).decode(), target)

    def test_install_rejects_flattened_macos_framework(self):
        current = (
            self.prebuilt / "macos/lib_llama_cpp_macos.xcframework/"
            "macos-arm64_x86_64/lib_llama_cpp_macos.framework/Versions/Current"
        )
        current.unlink()
        shutil.copytree(current.parent / "A", current)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected framework symlink:", result.stderr)

    def test_standalone_linux_consumers_select_both_prebuilts(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        plugin = self.root / "packages/lib_llama_cpp_linux/linux"
        shutil.copy2(REPO_ROOT / "packages/lib_llama_cpp_linux/linux/CMakeLists.txt", plugin)
        consumer = self.root / "consumer"
        consumer.mkdir()
        (consumer / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.14)\nproject(consumer LANGUAGES CXX)\n"
            f'add_subdirectory("{plugin}" plugin)\n'
            'file(WRITE "${CMAKE_BINARY_DIR}/bundled.txt" "${lib_llama_cpp_linux_bundled_libraries}")\n'
        )
        for processor, arch in (("x86_64", "x64"), ("aarch64", "arm64")):
            with self.subTest(processor=processor):
                build = self.root / f"consumer-{arch}"
                result = subprocess.run(
                    ["cmake", "-S", str(consumer), "-B", str(build),
                     "-DCMAKE_SYSTEM_NAME=Linux", f"-DCMAKE_SYSTEM_PROCESSOR={processor}",
                     "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"],
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    (build / "bundled.txt").read_text(),
                    str((plugin / f"prebuilt/{arch}/liblib_llama_cpp_linux.so").resolve()),
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
