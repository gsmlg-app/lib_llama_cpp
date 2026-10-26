import 'dart:ffi';

/// A process-wide atomic flag. The inference worker owns allocation and release;
/// its client may request cancellation until shutdown has been acknowledged.
final class NativeCancellation {
  NativeCancellation(DynamicLibrary library, int address)
    : pointer = Pointer<Void>.fromAddress(address),
      _request = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('llcs_cancel_request'),
      _reset = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('llcs_cancel_reset'),
      _requested = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('llcs_cancel_is_requested'),
      _waitCredit = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('llcs_cancel_wait_credit'),
      _releaseCredit = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('llcs_cancel_release_credit');
  final Pointer<Void> pointer;
  final void Function(Pointer<Void>) _request;
  final void Function(Pointer<Void>) _reset;
  final int Function(Pointer<Void>) _requested;
  final int Function(Pointer<Void>) _waitCredit;
  final void Function(Pointer<Void>) _releaseCredit;
  bool waitCredit() => _waitCredit(pointer) != 0;
  void releaseCredit() => _releaseCredit(pointer);
  void request() => _request(pointer);
  void reset() => _reset(pointer);
  bool get isRequested => _requested(pointer) != 0;
}
