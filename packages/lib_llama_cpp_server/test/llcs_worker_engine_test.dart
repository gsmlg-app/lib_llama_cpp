import 'dart:async';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'immediate cancellation waits for submit and native cancel acknowledgment',
    () async {
      final directory = await Directory.systemTemp.createTemp('llcs_cancel_');
      addTearDown(() => directory.delete(recursive: true));
      final library = '${directory.path}/worker.so';
      final compile = await Process.run('cc', [
        '-shared',
        '-fPIC',
        File(
          'packages/lib_llama_cpp_server/test/fixtures/worker_engine.c',
        ).absolute.path,
        '-o',
        library,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final engine = await LlcsWorkerEngine.open(
        libraryPath: library,
        config: const LlcsEngineConfig(modelPath: '/fixture.gguf'),
      );
      addTearDown(engine.close);
      final subscription = engine
          .stream({
            'messages': [
              {'role': 'user', 'content': 'long'},
            ],
          })
          .listen((_) => fail('Cancelled prefill emitted an event.'));

      await subscription.cancel().timeout(const Duration(seconds: 2));

      expect((await engine.stats())['cancelled'], 1);
    },
    skip: !(Platform.isLinux || Platform.isMacOS)
        ? 'Native fixture requires a POSIX C compiler.'
        : false,
  );

  test(
    'blocking native lifecycle stays off event loop; prefill cancellation recovers',
    () async {
      final directory = await Directory.systemTemp.createTemp('llcs_worker_');
      addTearDown(() => directory.delete(recursive: true));
      final library = '${directory.path}/worker.so';
      final fixture = File(
        'packages/lib_llama_cpp_server/test/fixtures/worker_engine.c',
      ).absolute.path;
      final compile = await Process.run('cc', [
        '-shared',
        '-fPIC',
        fixture,
        '-o',
        library,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final engine = await LlcsWorkerEngine.open(
        libraryPath: library,
        config: const LlcsEngineConfig(modelPath: '/fixture.gguf'),
      );
      addTearDown(engine.close);
      expect(
        ticks,
        greaterThan(5),
        reason: 'Native create must not block the event loop.',
      );
      final first = engine
          .stream({
            'messages': [
              {'role': 'user', 'content': 'long'},
            ],
          })
          .listen((_) {
            fail('Cancelled prefill emitted a late event.');
          });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await first.cancel().timeout(const Duration(seconds: 2));
      expect((await engine.stats())['cancelled'], 1);
      final next = await engine.stream({
        'messages': [
          {'role': 'user', 'content': 'valid'},
        ],
      }).toList();
      expect(
        (next.first['choices'] as List).first['delta']['content'],
        'hello',
      );
      expect((next.last['choices'] as List).first['finish_reason'], 'stop');
      final beforeClose = ticks;
      await engine.close();
      expect(ticks - beforeClose, greaterThan(5));
      await engine.close();
    },
    skip: !Platform.isLinux
        ? 'Native lifecycle fixture targets Linux; real Windows model test is separate.'
        : false,
  );
}
