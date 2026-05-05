import 'dart:ffi';

import 'handles.dart';
import 'native_types.dart';

typedef _LlamaModelFreeNative = Void Function(Pointer<LlamaModel>);
typedef _LlamaModelFreeDart = void Function(Pointer<LlamaModel>);
typedef _LlamaContextFreeNative = Void Function(Pointer<LlamaContext>);
typedef _LlamaContextFreeDart = void Function(Pointer<LlamaContext>);

final class LlamaCppNativeLibrary {
  LlamaCppNativeLibrary(this.dynamicLibrary);

  final DynamicLibrary dynamicLibrary;

  LlamaModelHandle modelHandle(Pointer<LlamaModel> pointer) {
    return LlamaModelHandle.owned(
      pointer,
      finalizer: _modelFinalizer,
      release: _llamaModelFree,
    );
  }

  LlamaContextHandle contextHandle(Pointer<LlamaContext> pointer) {
    return LlamaContextHandle.owned(
      pointer,
      finalizer: _contextFinalizer,
      release: _llamaFree,
    );
  }

  late final NativeFinalizer _modelFinalizer = NativeFinalizer(
    dynamicLibrary.lookup<NativeFinalizerFunction>('llama_model_free'),
  );

  late final NativeFinalizer _contextFinalizer = NativeFinalizer(
    dynamicLibrary.lookup<NativeFinalizerFunction>('llama_free'),
  );

  late final _LlamaModelFreeDart _llamaModelFree = dynamicLibrary
      .lookupFunction<_LlamaModelFreeNative, _LlamaModelFreeDart>(
        'llama_model_free',
      );

  late final _LlamaContextFreeDart _llamaFree = dynamicLibrary
      .lookupFunction<_LlamaContextFreeNative, _LlamaContextFreeDart>(
        'llama_free',
      );
}
