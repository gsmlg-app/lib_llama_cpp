import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('Android Vulkan e2e configuration', () {
    test('workflow provisions Vulkan tooling and enables Android Vulkan e2e', () {
      final root = _repoRoot();
      final workflow = (root / '.github/workflows/e2e.yml').readAsStringSync();
      final androidJob = _workflowJob(workflow, 'android-real-model-smoke');

      expect(androidJob, contains('runs-on: ubuntu-latest'));
      expect(androidJob, contains('ANDROID_ABI: x86_64'));
      expect(androidJob, contains('ANDROID_PLATFORM: android-28'));
      expect(androidJob, contains('LIB_LLAMA_CPP_ENABLE_VULKAN: ON'));
      expect(androidJob, contains("LIB_LLAMA_CPP_TEST_GPU_LAYERS: '1'"));
      expect(androidJob, contains("GGML_VK_VISIBLE_DEVICES: '0'"));
      expect(
        androidJob,
        contains(
          'sudo apt-get install -y clang cmake glslc libvulkan-dev mesa-vulkan-drivers ninja-build spirv-headers vulkan-tools',
        ),
      );
      expect(androidJob, contains('echo "VULKAN_SDK=/usr"'));
      expect(androidJob, contains('echo "LIBGL_ALWAYS_SOFTWARE=1"'));
      expect(androidJob, contains('VK_ICD_FILENAMES='));
      expect(androidJob, contains('storageBuffer16BitAccess'));
      expect(androidJob, contains('vulkaninfo --summary || true'));
      expect(androidJob, contains('api-level: 35'));
      expect(androidJob, contains('target: default'));
      expect(androidJob, contains('arch: x86_64'));
      expect(
        androidJob,
        contains(
          'pre-emulator-launch-script: mkdir -p "\$HOME/.android" && printf "Vulkan = on\\nGLDirectMem = on\\n" > "\$HOME/.android/advancedFeatures.ini"',
        ),
      );
      expect(
        androidJob,
        contains(
          'emulator-options: -no-window -gpu lavapipe -no-snapshot -noaudio -no-boot-anim -no-metrics -feature Vulkan,GLDirectMem',
        ),
      );
      expect(androidJob, contains('Enable Linux KVM'));
      expect(androidJob, contains('disable-linux-hw-accel: false'));
      expect(
        androidJob,
        contains('script: bash .github/scripts/android-real-model-smoke.sh'),
      );
      expect(
        androidJob,
        isNot(contains('integration_test/mobile_smoke_test.dart')),
      );
    });

    test('release workflow builds Android prebuilts with Vulkan', () {
      final root = _repoRoot();
      final workflow = (root / '.github/workflows/release.yml')
          .readAsStringSync();

      expect(workflow, contains('echo "VULKAN_SDK=/usr" >> "\$GITHUB_ENV"'));
      expect(workflow, contains('ANDROID_PLATFORM: android-28'));
      expect(workflow, contains('LIB_LLAMA_CPP_ENABLE_VULKAN: ON'));
      expect(
        workflow,
        contains('.github/scripts/build-native-prebuilt.sh android'),
      );
    });

    test('Android Flutter platform build compiles plugin with Vulkan', () {
      final root = _repoRoot();
      final workflow = (root / '.github/workflows/e2e.yml').readAsStringSync();
      final platformJob = _workflowJob(workflow, 'flutter-platform-builds');

      expect(platformJob, contains('flutter build apk --debug'));
      expect(
        platformJob,
        contains('Install Android Vulkan plugin build dependencies'),
      );
      expect(
        platformJob,
        contains(
          'sudo apt-get install -y cmake glslc libvulkan-dev ninja-build spirv-headers',
        ),
      );
      expect(platformJob, contains('vulkan-host-headers'));
      expect(platformJob, contains('echo "VULKAN_SDK='));
      expect(platformJob, contains('echo "LIB_LLAMA_CPP_ENABLE_VULKAN=ON"'));
      expect(platformJob, contains('echo "ANDROID_PLATFORM=android-28"'));
      expect(platformJob, contains('echo "ANDROID_ABIS=x86_64"'));
      expect(platformJob, contains('Setup Android SDK'));
      expect(platformJob, contains('sdkmanager "platform-tools"'));
      expect(platformJob, contains('platforms;android-36'));
      expect(platformJob, contains('ndk;27.0.12077973'));
      expect(platformJob, contains('ANDROID_NDK_HOME='));
    });

    test('Android native smoke build can compile llama.cpp with Vulkan', () {
      final root = _repoRoot();
      final script = (root / '.github/scripts/build-android-llama-cli.sh')
          .readAsStringSync();

      expect(script, contains('LIB_LLAMA_CPP_ENABLE_VULKAN'));
      expect(script, contains('-DGGML_VULKAN=\$enable_vulkan'));
      expect(script, contains('default_android_platform="android-28"'));
      expect(script, contains('-DVulkan_INCLUDE_DIR='));
      expect(script, contains('-DCMAKE_CXX_FLAGS='));
      expect(script, contains('vulkan-host-headers'));
      expect(script, contains('apply_llama_cpp_ci_patches'));
      expect(script, contains('llama-vulkan-core-16bit-storage.patch'));
      expect(script, contains('--unidiff-zero'));
      expect(script, contains('for include_name in vulkan spirv'));
      expect(script, contains('VULKAN_HPP_TYPESAFE_CONVERSION=1'));
      expect(script, contains('-DVulkan_LIBRARY='));
      expect(script, contains('android_api_level'));
      expect(script, contains('/\${android_api_level}/libvulkan.so'));
    });

    test('Android native smoke requires real Vulkan layer offload', () {
      final root = _repoRoot();
      final script = (root / '.github/scripts/android-real-model-smoke.sh')
          .readAsStringSync();

      expect(script, isNot(contains('adb kill-server')));
      expect(script, contains('adb devices -l'));
      expect(script, contains('sys.boot_completed'));
      expect(script, contains('guest_env_prefix='));
      expect(script, contains(r'GGML_VK_VISIBLE_DEVICES=$(printf'));
      expect(
        script,
        contains(
          "grep -Eq 'assigned to device Vulkan|offloaded [1-9][0-9]*/[0-9]+ layers to GPU'",
        ),
      );
      expect(script, isNot(contains("grep -Eq 'ggml_vulkan")));
    });

    test('Android prebuilt build resolves versioned NDK Vulkan library', () {
      final root = _repoRoot();
      final script = (root / '.github/scripts/build-native-prebuilt.sh')
          .readAsStringSync();

      expect(script, contains('android_api_level'));
      expect(script, contains('/\${android_api_level}/libvulkan.so'));
      expect(script, contains('-DCMAKE_CXX_FLAGS='));
      expect(script, contains('vulkan-host-headers'));
      expect(script, contains('apply_llama_cpp_ci_patches'));
      expect(script, contains('llama-vulkan-core-16bit-storage.patch'));
      expect(script, contains('--unidiff-zero'));
      expect(script, contains('VULKAN_HPP_TYPESAFE_CONVERSION=1'));
    });

    test('Android Gradle build resolves versioned NDK Vulkan library', () {
      final root = _repoRoot();
      final gradle =
          (root / 'packages/lib_llama_cpp_android/android/build.gradle')
              .readAsStringSync();

      expect(gradle, contains('androidApiLevel'));
      expect(gradle, contains('sourceVulkanEnabled || hasPrebuiltJniLibs'));
      expect(gradle, contains('minSdkVersion = vulkanEnabled ? 28 : 24'));
      expect(gradle, contains('minSdk = minSdkVersion'));
      expect(gradle, contains('/\${androidApiLevel}/libvulkan.so'));
    });

    test('example Android app raises minSdk for Vulkan e2e', () {
      final root = _repoRoot();
      final gradle = (root / 'example/android/app/build.gradle.kts')
          .readAsStringSync();

      expect(gradle, contains('LIB_LLAMA_CPP_ENABLE_VULKAN'));
      expect(
        gradle,
        contains(
          'minSdk = if (libLlamaCppVulkanEnabled) 28 else flutter.minSdkVersion',
        ),
      );
    });

    test('mobile integration smoke requests GPU layers when configured', () {
      final root = _repoRoot();
      final testSource =
          (root / 'example/integration_test/mobile_smoke_test.dart')
              .readAsStringSync();

      expect(testSource, contains('LIB_LLAMA_CPP_TEST_GPU_LAYERS'));
      expect(testSource, contains('gpuLayerCount: _testGpuLayerCount'));
      expect(
        testSource.indexOf('await _expectRequiredBackendSupport();'),
        lessThan(testSource.indexOf('if (modelPath.isEmpty)')),
      );
    });
  });
}

Directory _repoRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/melos.yaml').existsSync() &&
        Directory('${current.path}/packages/lib_llama_cpp').existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'Could not find repository root from ${Directory.current.path}',
      );
    }
    current = parent;
  }
}

extension on Directory {
  File operator /(String child) => File('$path/$child');
}

String _workflowJob(String workflow, String jobName) {
  final marker = '\n  $jobName:\n';
  final start = workflow.indexOf(marker);
  if (start == -1) {
    throw StateError('Could not find workflow job $jobName.');
  }

  final bodyStart = start + marker.length;
  final nextJob = RegExp(
    r'\n  [A-Za-z0-9_-]+:\n',
  ).firstMatch(workflow.substring(bodyStart));
  final end = nextJob == null ? workflow.length : bodyStart + nextJob.start;
  return workflow.substring(start, end);
}
