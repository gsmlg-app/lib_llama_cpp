import 'dart:async';
import 'dart:isolate';

import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'llama_command.dart';
import 'llama_response.dart';
import 'llama_state.dart';
import 'native_runtime.dart';
import 'native_cancellation.dart';

final class InferenceIsolate {
  InferenceIsolate._({
    required SendPort commandPort,
    required StreamSubscription<Object?> subscription,
    required NativeCancellation? cancellation,
  }) : _commandPort = commandPort,
       _subscription = subscription,
       _cancellation = cancellation;

  final SendPort _commandPort;
  final StreamSubscription<Object?> _subscription;
  final NativeCancellation? _cancellation;
  final Map<int, StreamController<LlamaResponse>> _pending = {};
  final Map<int, Completer<void>> _finished = {};
  final _shutdown = Completer<void>();
  var _nextRequestId = 0;
  var _isClosed = false;
  Future<void>? _closeFuture;

  static Future<InferenceIsolate> spawn({
    required LlamaCppLibraryDescriptor library,
    required LlamaState initialState,
  }) async {
    final ready = Completer<_WorkerReady>();
    final receivePort = ReceivePort();
    late final InferenceIsolate actor;
    final subscription = receivePort.listen((message) {
      if (message is _WorkerReady) {
        ready.complete(message);
        return;
      }
      if (message is _ShutdownComplete) {
        actor._shutdown.complete();
        receivePort.close();
        return;
      }
      if (message is _ResponseEnvelope) {
        final controller = actor._pending[message.requestId];
        if (controller == null) return;
        if (message.response != null &&
            !controller.isClosed &&
            !actor._isClosed) {
          controller.add(message.response!);
        }
        if (message.isDone) {
          actor._pending.remove(message.requestId);
          actor._finished.remove(message.requestId)?.complete();
          unawaited(controller.close());
        }
      }
    });
    await Isolate.spawn(
      _runInferenceWorker,
      _StartMessage(
        replyPort: receivePort.sendPort,
        library: library,
        initialState: initialState,
      ),
      debugName: 'lib_llama_cpp_inference',
    );
    final worker = await ready.future;
    actor = InferenceIsolate._(
      commandPort: worker.port,
      subscription: subscription,
      cancellation: worker.cancelAddress == 0
          ? null
          : NativeCancellation(openLlamaLibrary(library), worker.cancelAddress),
    );
    return actor;
  }

  Stream<LlamaResponse> dispatch(LlamaCommand command) async* {
    if (_isClosed) {
      yield const LlamaErrorResponse(message: 'Inference isolate is closed.');
      return;
    }
    if (_pending.isNotEmpty) {
      yield const LlamaErrorResponse(
        message: 'An inference command is already active.',
      );
      return;
    }
    final requestId = _nextRequestId++;
    final finished = Completer<void>();
    late final StreamController<LlamaResponse> controller;
    controller = StreamController<LlamaResponse>(
      onCancel: () async {
        if (_pending.containsKey(requestId)) {
          if (!_isClosed) _cancellation?.request();
          await finished.future;
        }
      },
    );
    _pending[requestId] = controller;
    _finished[requestId] = finished;
    _cancellation?.reset();
    _commandPort.send(_CommandEnvelope(requestId: requestId, command: command));
    await for (final response in controller.stream) {
      if (_isClosed) return;
      yield response;
      // async* resumes here only when downstream is ready for another event.
      if (!_isClosed && _pending.containsKey(requestId)) {
        _cancellation?.releaseCredit();
      }
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _isClosed = true;
    _cancellation?.request();
    _commandPort.send(const _ShutdownMessage());
    await _shutdown.future;
    for (final entry in _pending.entries) {
      _finished.remove(entry.key)?.complete();
      unawaited(entry.value.close());
    }
    _pending.clear();
    await _subscription.cancel();
  }
}

final class _WorkerReady {
  const _WorkerReady(this.port, this.cancelAddress);
  final SendPort port;
  final int cancelAddress;
}

final class _ShutdownComplete {
  const _ShutdownComplete();
}

final class _StartMessage {
  const _StartMessage({
    required this.replyPort,
    required this.library,
    required this.initialState,
  });

  final SendPort replyPort;
  final LlamaCppLibraryDescriptor library;
  final LlamaState initialState;
}

final class _CommandEnvelope {
  const _CommandEnvelope({required this.requestId, required this.command});

  final int requestId;
  final LlamaCommand command;
}

final class _ResponseEnvelope {
  const _ResponseEnvelope({
    required this.requestId,
    this.response,
    this.isDone = false,
  });

  final int requestId;
  final LlamaResponse? response;
  final bool isDone;
}

final class _ShutdownMessage {
  const _ShutdownMessage();
}

void _runInferenceWorker(_StartMessage start) {
  // An initial Dart state does not transfer native pointer ownership.
  var state = const LlamaState.empty();
  NativeLlamaRuntime? runtime;
  LlamaErrorResponse? startupError;
  try {
    runtime = NativeLlamaRuntime(library: start.library);
  } on NativeLlamaException catch (error) {
    startupError = LlamaErrorResponse(
      message: error.message,
      code: error.code,
      details: error.details,
    );
  } on Object catch (error) {
    startupError = LlamaErrorResponse(
      message: 'Failed to initialize llama.cpp runtime: $error',
    );
  }

  final receivePort = ReceivePort();
  start.replyPort.send(
    _WorkerReady(
      receivePort.sendPort,
      runtime?.cancellation.pointer.address ?? 0,
    ),
  );

  void send(int requestId, LlamaResponse response) {
    if (runtime != null && !runtime.cancellation.waitCredit()) return;
    start.replyPort.send(
      _ResponseEnvelope(requestId: requestId, response: response),
    );
  }

  void done(int requestId) {
    start.replyPort.send(_ResponseEnvelope(requestId: requestId, isDone: true));
  }

  receivePort.listen((message) {
    if (message is _ShutdownMessage) {
      try {
        runtime?.close();
      } finally {
        start.replyPort.send(const _ShutdownComplete());
        receivePort.close();
      }
      return;
    }

    if (message is! _CommandEnvelope) {
      return;
    }

    final command = message.command;
    switch (command) {
      case LlamaLoadModelCommand():
        if (startupError != null || runtime == null) {
          send(message.requestId, startupError!);
        } else {
          try {
            state = runtime.loadModel(command);
            send(message.requestId, LlamaStateChangedResponse(state: state));
          } on NativeLlamaException catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(
                message: error.message,
                code: error.code,
                details: error.details,
              ),
            );
          } on Object catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(message: 'Failed to load model: $error'),
            );
          }
        }
      case LlamaGenerateCommand():
        if (!state.isModelLoaded || runtime == null) {
          send(
            message.requestId,
            const LlamaErrorResponse(
              message: 'Cannot generate before a model is loaded.',
            ),
          );
        } else {
          try {
            for (final response in runtime.generate(command)) {
              send(message.requestId, response);
            }
          } on NativeLlamaException catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(
                message: error.message,
                code: error.code,
                details: error.details,
              ),
            );
          } on Object catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(message: 'Generation failed: $error'),
            );
          }
        }
      case LlamaGenerateMessagesCommand():
        if (!state.isModelLoaded || runtime == null) {
          send(
            message.requestId,
            const LlamaErrorResponse(
              message: 'Cannot generate before a model is loaded.',
            ),
          );
        } else {
          try {
            for (final response in runtime.generateMessages(command)) {
              send(message.requestId, response);
            }
          } on NativeLlamaException catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(
                message: error.message,
                code: error.code,
                details: error.details,
              ),
            );
          } on Object catch (error) {
            send(
              message.requestId,
              LlamaErrorResponse(message: 'Generation failed: $error'),
            );
          }
        }
      case LlamaDisposeCommand():
        runtime?.disposeModel();
        state = const LlamaState.empty();
        send(message.requestId, LlamaStateChangedResponse(state: state));
        send(message.requestId, const LlamaDoneResponse());
    }

    done(message.requestId);
  });
}

void unawaited(Future<void> future) {}
