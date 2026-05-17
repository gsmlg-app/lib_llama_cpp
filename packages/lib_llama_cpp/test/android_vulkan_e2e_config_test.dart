import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('Android Vulkan e2e configuration', () {
    test('workflow provisions Vulkan tooling and enables Android Vulkan e2e', () {
      final root = _repoRoot();
      final workflow = (root / '.github/workflows/e2e.yml').readAsStringSync();
      final androidJob = _workflowJob(workflow, 'android-real-model-smoke');

      expect(androidJob, contains('runs-on: macos-14'));
      expect(androidJob, contains('ANDROID_ABI: arm64-v8a'));
      expect(androidJob, contains('ANDROID_PLATFORM: android-28'));
      expect(androidJob, contains('LIB_LLAMA_CPP_ENABLE_VULKAN: ON'));
      expect(androidJob, contains("LIB_LLAMA_CPP_TEST_GPU_LAYERS: '1'"));
      expect(
        androidJob,
        contains(
          'brew install cmake ninja shaderc spirv-headers vulkan-headers',
        ),
      );
      expect(
        androidJob,
        contains(
          'echo "VULKAN_SDK=\$(brew --prefix vulkan-headers)" >> "\$GITHUB_ENV"',
        ),
      );
      expect(androidJob, contains('arch: arm64-v8a'));
      expect(androidJob, isNot(contains('Enable Linux KVM')));
      expect(
        androidJob,
        contains(
          '--dart-define=LIB_LLAMA_CPP_TEST_GPU_LAYERS="\$LIB_LLAMA_CPP_TEST_GPU_LAYERS"',
        ),
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

    test('Android native smoke build can compile llama.cpp with Vulkan', () {
      final root = _repoRoot();
      final script = (root / '.github/scripts/build-android-llama-cli.sh')
          .readAsStringSync();

      expect(script, contains('LIB_LLAMA_CPP_ENABLE_VULKAN'));
      expect(script, contains('-DGGML_VULKAN=\$enable_vulkan'));
      expect(script, contains('default_android_platform="android-28"'));
      expect(script, contains('-DVulkan_INCLUDE_DIR='));
      expect(script, contains('-DVulkan_LIBRARY='));
      expect(script, contains('android_api_level'));
      expect(script, contains('/\${android_api_level}/libvulkan.so'));
    });

    test('Android prebuilt build resolves versioned NDK Vulkan library', () {
      final root = _repoRoot();
      final script = (root / '.github/scripts/build-native-prebuilt.sh')
          .readAsStringSync();

      expect(script, contains('android_api_level'));
      expect(script, contains('/\${android_api_level}/libvulkan.so'));
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
