import 'dart:io';
import 'package:lib_llama_cpp/src/llama_command.dart';
import 'package:lib_llama_cpp/src/native_runtime.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  test('descriptor equality distinguishes unverified requirements', () {
    const cuda = LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: '/test/library',
      capabilities: {LlamaCppLibraryCapability.cpu},
      requestedCapabilities: {LlamaCppLibraryCapability.cuda},
    );
    const vulkan = LlamaCppLibraryDescriptor(
      resolution: LlamaCppLibraryResolution.path,
      path: '/test/library',
      capabilities: {LlamaCppLibraryCapability.cpu},
      requestedCapabilities: {LlamaCppLibraryCapability.vulkan},
    );
    expect(cuda, isNot(vulkan));
    expect(cuda.hashCode, isNot(vulkan.hashCode));
    expect(cuda.capabilities, {LlamaCppLibraryCapability.cpu});
    expect(cuda.requestedCapabilities, {LlamaCppLibraryCapability.cuda});
  });
  final cpuLibrary =
      Platform.environment['LIB_LLAMA_CPP_TEST_CPU_LIBRARY'] ?? '';
  group('actual CPU-only library', () {
    for (final backend in [
      LlamaCppLibraryCapability.cuda,
      LlamaCppLibraryCapability.vulkan,
    ]) {
      test('rejects required ${backend.name} before loading weights', () {
        expect(
          () => NativeLlamaRuntime(
            library: LlamaCppLibraryDescriptor(
              resolution: LlamaCppLibraryResolution.path,
              path: cpuLibrary,
              capabilities: const {LlamaCppLibraryCapability.cpu},
              requestedCapabilities: {backend},
            ),
          ),
          throwsA(
            isA<NativeLlamaException>().having(
              (error) => error.message,
              'message',
              contains('Required backend ${backend.name} is unavailable'),
            ),
          ),
        );
      });
    }
    test('rejects GPU offload before reading a model file', () {
      final runtime = NativeLlamaRuntime(
        library: LlamaCppLibraryDescriptor(
          resolution: LlamaCppLibraryResolution.path,
          path: cpuLibrary,
        ),
      );
      addTearDown(runtime.close);
      expect(
        () => runtime.loadModel(
          const LlamaLoadModelCommand(
            modelPath: '/model-not-present.gguf',
            gpuLayerCount: 1,
          ),
        ),
        throwsA(
          isA<NativeLlamaException>().having(
            (error) => error.message,
            'message',
            contains('no usable GPU device'),
          ),
        ),
      );
    });
  }, skip: cpuLibrary.isEmpty || !(Platform.isLinux || Platform.isWindows));
}
