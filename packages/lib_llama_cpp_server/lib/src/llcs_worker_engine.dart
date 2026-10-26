import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:lib_llama_cpp_ffi/lib_llama_cpp_ffi.dart';

import 'llcs_engine.dart';

/// Resident engine whose blocking FFI operations run on one owning isolate.
/// Streams pull one event at a time; a paused listener does not keep polling.
final class LlcsWorkerEngine {
  LlcsWorkerEngine._();

  final _receive = ReceivePort();
  final _ready = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  final _controllers = <StreamController<Map<String, Object?>>>{};
  late final SendPort _commands;
  Map<String, Object?> _caps = const {};
  var _nextId = 0;
  var _closed = false;
  Future<void>? _closeFuture;

  static Future<LlcsWorkerEngine> open({
    String? libraryPath,
    required LlcsEngineConfig config,
  }) async {
    final engine = LlcsWorkerEngine._();
    engine._receive.listen(engine._onMessage);
    await Isolate.spawn(
      _workerMain,
      (engine._receive.sendPort, libraryPath, config),
      onError: engine._receive.sendPort,
      onExit: engine._receive.sendPort,
    );
    await engine._ready.future;
    return engine;
  }

  Map<String, Object?> caps() => Map.unmodifiable(_caps);

  Future<Map<String, Object?>> stats() async =>
      Map<String, Object?>.from(await _call('stats') as Map);

  Stream<Map<String, Object?>> stream(Map<String, Object?> request) {
    if (_closed) throw StateError('LlcsWorkerEngine is closed.');
    late final StreamController<Map<String, Object?>> controller;
    int? taskId;
    var cancelled = false;
    var finished = false;
    Completer<void>? resumed;
    final submitted = Completer<void>();
    Future<void>? cancellation;

    Future<void> cancelSubmitted() async {
      await submitted.future;
      final id = taskId;
      if (id != null && !finished && !_closed) await _call('cancel', id);
      _controllers.remove(controller);
    }

    Future<void> cancel() {
      cancelled = true;
      if (resumed != null && !resumed!.isCompleted) resumed!.complete();
      return cancellation ??= cancelSubmitted();
    }

    Future<void> pump() async {
      try {
        try {
          taskId = await _call('submit', request) as int;
        } finally {
          submitted.complete();
        }
        if (cancelled) {
          await cancel();
          return;
        }
        while (!cancelled && !_closed) {
          if (controller.isPaused) {
            resumed ??= Completer<void>();
            await resumed!.future;
            resumed = null;
            if (cancelled || _closed) break;
          }
          final event = await _call('next', taskId);
          if (cancelled || _closed) break;
          if (event == null) {
            finished = true;
            break;
          }
          controller.add(Map<String, Object?>.from(event as Map));
        }
      } catch (error, stack) {
        if (!cancelled && !_closed) controller.addError(error, stack);
        await cancel();
      } finally {
        _controllers.remove(controller);
        unawaited(controller.close());
      }
    }

    controller = StreamController<Map<String, Object?>>(
      onListen: () {
        _controllers.add(controller);
        unawaited(pump());
      },
      onResume: () {
        if (resumed != null && !resumed!.isCompleted) resumed!.complete();
      },
      onCancel: cancel,
    );
    return controller.stream;
  }

  /// Resolves only after native terminate/join/free has finished.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _call('close');
    } finally {
      for (final controller in _controllers.toList()) {
        unawaited(controller.close());
      }
      _controllers.clear();
      _receive.close();
      _failPending(StateError('LlcsWorkerEngine is closed.'));
    }
  }

  Future<Object?> _call(String operation, [Object? argument]) {
    if (_closed && operation != 'close') {
      return Future.error(StateError('LlcsWorkerEngine is closed.'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send((id, operation, argument));
    return completer.future;
  }

  void _onMessage(Object? message) {
    if (message == null || message is List) {
      final error = StateError(
        'Native engine worker exited${message is List ? ': ${message.first}' : ''}.',
      );
      if (!_ready.isCompleted) _ready.completeError(error);
      _failPending(error);
      _receive.close();
      return;
    }
    final data = message as Map;
    if (data.containsKey('ready')) {
      if (data['error'] != null) {
        _ready.completeError(
          LlcsEngineException.fromJson(
            Map<String, Object?>.from(data['error'] as Map),
          ),
        );
        return;
      }
      _commands = data['ready'] as SendPort;
      _caps = Map<String, Object?>.from(data['caps'] as Map);
      _ready.complete();
      return;
    }
    final completer = _pending.remove(data['id']);
    if (completer == null) return;
    if (data['error'] != null) {
      completer.completeError(
        LlcsEngineException.fromJson(
          Map<String, Object?>.from(data['error'] as Map),
        ),
      );
    } else {
      completer.complete(data['result']);
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }
}

Map<String, Object?> _workerError(Object error) => error is LlcsEngineException
    ? {
        'message': error.message,
        'code': error.code,
        'type': error.type,
        'param': error.param,
      }
    : {
        'message': error.toString(),
        'code': 'native_error',
        'type': 'server_error',
      };

void _workerMain((SendPort, String?, LlcsEngineConfig) arguments) {
  final (reply, libraryPath, config) = arguments;
  final commands = ReceivePort();
  late final LlcsEngine engine;
  late final DynamicLibrary library;
  try {
    library = LlamaCppDynamicLibraryLoader().open(libraryPath);
    engine = LlcsEngine.open(library: library, config: config);
    reply.send({'ready': commands.sendPort, 'caps': engine.caps()});
  } catch (error) {
    reply.send({'ready': null, 'error': _workerError(error)});
    commands.close();
    return;
  }
  var closing = false;
  final active = <int>{};
  final inFlight = <Future<void>>{};

  Future<void> handle((int, String, Object?) message) async {
    final (id, operation, argument) = message;
    try {
      Object? result;
      if (closing && operation != 'close') {
        reply.send({'id': id, 'result': null});
        return;
      }
      switch (operation) {
        case 'submit':
          final task = engine.submit(
            Map<String, Object?>.from(argument as Map),
          );
          active.add(task);
          result = task;
        case 'next':
          final task = argument as int;
          while (!closing && active.contains(task)) {
            final event = engine.poll(task, timeout: Duration.zero);
            if (event == null) {
              active.remove(task);
              break;
            }
            if (event.isNotEmpty) {
              result = event;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        case 'cancel':
          final task = argument as int;
          active.remove(task);
          engine.cancel(task);
        case 'stats':
          final stats = library
              .lookupFunction<
                Pointer<Char> Function(Pointer<llcs_engine>),
                Pointer<Char> Function(Pointer<llcs_engine>)
              >('llcs_engine_stats');
          // stats is exposed through the synchronous owner's ABI below.
          result = engine.readStats(stats);
        case 'close':
          closing = true;
          for (final task in active) {
            engine.cancel(task);
          }
          active.clear();
          engine.close();
          // Pending polling continuations see closing before touching FFI.
          await Future.wait(inFlight.toList());
          commands.close();
        default:
          throw StateError('Unknown worker operation: $operation');
      }
      reply.send({'id': id, 'result': result});
    } catch (error) {
      reply.send({'id': id, 'error': _workerError(error)});
    }
  }

  commands.listen((message) {
    final operation = (message as (int, String, Object?)).$2;
    final future = handle(message);
    if (operation != 'close') {
      inFlight.add(future);
      unawaited(future.whenComplete(() => inFlight.remove(future)));
    }
  });
}
