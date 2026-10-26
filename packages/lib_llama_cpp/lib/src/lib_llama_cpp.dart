import 'dart:async';

import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'inference_isolate.dart';
import 'llama_command.dart';
import 'llama_response.dart';
import 'llama_state.dart';

abstract interface class LlamaEngine {
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  });
}

final class LibLlamaCpp implements LlamaEngine {
  const LibLlamaCpp({LibLlamaCppPlatform? platform}) : _platform = platform;

  final LibLlamaCppPlatform? _platform;

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    final platform = _platform ?? LibLlamaCppPlatform.instance;
    late final LlamaCppLibraryDescriptor library;
    try {
      library = await platform.resolveLibrary(request: libraryRequest);
    } on Object catch (error) {
      yield LlamaErrorResponse(
        message: 'Failed to resolve llama.cpp library: $error',
      );
      return;
    }

    late final InferenceIsolate actor;
    try {
      actor = await InferenceIsolate.spawn(
        library: library,
        initialState: initialState,
      );
    } on Object catch (error) {
      yield LlamaErrorResponse(
        message: 'Failed to start llama.cpp inference isolate: $error',
      );
      return;
    }

    yield LlamaReadyResponse(library: library);

    try {
      await for (final command in commands) {
        yield* actor.dispatch(command);
        if (command is LlamaDisposeCommand) {
          break;
        }
      }
    } finally {
      await actor.close();
    }
  }
}

/// Owns one resident model worker. Requests are serialized and each generation
/// rebuilds its context from complete messages, including compact SWA models.
final class ResidentLlamaEngine implements LlamaEngine {
  ResidentLlamaEngine({LibLlamaCppPlatform? platform}) : _platform = platform;
  final LibLlamaCppPlatform? _platform;
  InferenceIsolate? _actor;
  LlamaCppLibraryDescriptor? _library;
  Future<void> _tail = Future.value();
  bool _closed = false;
  Future<void>? _closeFuture;
  Future<InferenceIsolate>? _opening;
  final _closeSignal = Completer<void>();
  bool get isClosed => _closed;

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) {
    final complete = Completer<void>();
    StreamSubscription<LlamaResponse>? subscription;
    var canceled = false;
    late final StreamController<LlamaResponse> controller;
    void finish() {
      if (!complete.isCompleted) complete.complete();
      unawaited(controller.close());
    }

    Future<void> start(Future<void> previous) async {
      await Future.any([previous, _closeSignal.future]);
      if (canceled) return;
      subscription = _runRequest(
        commands,
        libraryRequest,
      ).listen(controller.add, onError: controller.addError, onDone: finish);
      if (controller.isPaused) subscription!.pause();
    }

    controller = StreamController<LlamaResponse>(
      onListen: () {
        final previous = _tail;
        // A canceled queued request may finish early, but its successor still
        // waits for the same active predecessor before taking native ownership.
        _tail = previous.then((_) => complete.future);
        unawaited(start(previous));
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        canceled = true;
        await subscription?.cancel();
        finish();
      },
    );
    return controller.stream;
  }

  Stream<LlamaResponse> _runRequest(
    Stream<LlamaCommand> commands,
    LlamaCppLibraryRequest libraryRequest,
  ) async* {
    try {
      if (_closed) {
        yield const LlamaErrorResponse(message: 'Resident engine is closed.');
        return;
      }
      final library = await (_platform ?? LibLlamaCppPlatform.instance)
          .resolveLibrary(request: libraryRequest);
      if (_closed) return;
      if (_actor == null || library != _library) {
        await _actor?.close();
        if (_closed) return;
        _opening = InferenceIsolate.spawn(
          library: library,
          initialState: const LlamaState.empty(),
        );
        try {
          _actor = await _opening!;
        } finally {
          _opening = null;
        }
        _library = library;
      }
      if (_closed) return;
      yield LlamaReadyResponse(library: library);
      await for (final command in commands) {
        // Per-request disposal releases the request lease. Native weights are
        // owned by this session and released by close or configuration change.
        if (_closed || command is LlamaDisposeCommand) return;
        yield* _actor!.dispatch(command);
      }
    } on Object catch (error) {
      if (!_closed) {
        yield LlamaErrorResponse(message: 'Resident inference failed: $error');
      }
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    _closeSignal.complete();
    final actor = _actor;
    if (actor != null) await actor.close();
    final opening = _opening;
    if (opening != null) {
      await (await opening).close();
    }
    await _actor?.close();
    _actor = null;
  }
}
