import 'dart:ffi';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaModelHandle', () {
    test('compares by native pointer address', () {
      final pointer = Pointer<LlamaModel>.fromAddress(0x1234);
      final samePointer = Pointer<LlamaModel>.fromAddress(0x1234);
      final otherPointer = Pointer<LlamaModel>.fromAddress(0x5678);

      final handle = LlamaModelHandle.unowned(pointer);

      expect(handle.pointer, pointer);
      expect(handle, LlamaModelHandle.unowned(samePointer));
      expect(handle.hashCode, LlamaModelHandle.unowned(samePointer).hashCode);
      expect(handle, isNot(LlamaModelHandle.unowned(otherPointer)));
    });

    test('rejects null pointers', () {
      expect(
        () => LlamaModelHandle.unowned(nullptr.cast<LlamaModel>()),
        throwsArgumentError,
      );
    });
  });

  group('LlamaContextHandle', () {
    test('compares by native pointer address', () {
      final pointer = Pointer<LlamaContext>.fromAddress(0x1234);
      final samePointer = Pointer<LlamaContext>.fromAddress(0x1234);
      final otherPointer = Pointer<LlamaContext>.fromAddress(0x5678);

      final handle = LlamaContextHandle.unowned(pointer);

      expect(handle.pointer, pointer);
      expect(handle, LlamaContextHandle.unowned(samePointer));
      expect(handle.hashCode, LlamaContextHandle.unowned(samePointer).hashCode);
      expect(handle, isNot(LlamaContextHandle.unowned(otherPointer)));
    });

    test('rejects null pointers', () {
      expect(
        () => LlamaContextHandle.unowned(nullptr.cast<LlamaContext>()),
        throwsArgumentError,
      );
    });
  });

  test(
    'native library construction does not eagerly look up release symbols',
    () {
      expect(
        () => LlamaCppNativeLibrary(DynamicLibrary.process()),
        returnsNormally,
      );
    },
  );
}
