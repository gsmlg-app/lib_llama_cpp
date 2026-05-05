import 'dart:ffi';

import 'native_types.dart';

abstract base class _LlamaNativeHandle<T extends NativeType>
    implements Finalizable {
  _LlamaNativeHandle(
    this.pointer, {
    NativeFinalizer? finalizer,
    void Function(Pointer<T> pointer)? release,
  }) : _finalizer = finalizer,
       _release = release {
    if (pointer.address == 0) {
      throw ArgumentError.value(pointer, 'pointer', 'Must not be null');
    }

    _finalizer?.attach(this, pointer.cast<Void>(), detach: this);
  }

  final Pointer<T> pointer;
  final NativeFinalizer? _finalizer;
  final void Function(Pointer<T> pointer)? _release;
  bool _isClosed = false;

  bool get isClosed => _isClosed;

  void close() {
    if (_isClosed) {
      return;
    }

    _finalizer?.detach(this);
    _release?.call(pointer);
    _isClosed = true;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other.runtimeType == runtimeType &&
            other is _LlamaNativeHandle<T> &&
            other.pointer.address == pointer.address;
  }

  @override
  int get hashCode => Object.hash(runtimeType, pointer.address);
}

final class LlamaModelHandle extends _LlamaNativeHandle<LlamaModel> {
  LlamaModelHandle._(super.pointer, {super.finalizer, super.release}) : super();

  factory LlamaModelHandle.owned(
    Pointer<LlamaModel> pointer, {
    NativeFinalizer? finalizer,
    void Function(Pointer<LlamaModel> pointer)? release,
  }) {
    return LlamaModelHandle._(pointer, finalizer: finalizer, release: release);
  }

  factory LlamaModelHandle.unowned(Pointer<LlamaModel> pointer) {
    return LlamaModelHandle._(pointer);
  }
}

final class LlamaContextHandle extends _LlamaNativeHandle<LlamaContext> {
  LlamaContextHandle._(super.pointer, {super.finalizer, super.release})
    : super();

  factory LlamaContextHandle.owned(
    Pointer<LlamaContext> pointer, {
    NativeFinalizer? finalizer,
    void Function(Pointer<LlamaContext> pointer)? release,
  }) {
    return LlamaContextHandle._(
      pointer,
      finalizer: finalizer,
      release: release,
    );
  }

  factory LlamaContextHandle.unowned(Pointer<LlamaContext> pointer) {
    return LlamaContextHandle._(pointer);
  }
}
