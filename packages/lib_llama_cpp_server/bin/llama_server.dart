import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> arguments) async {
  final parser = buildLlamaServerArgParser();
  late final LlamaServerConfig config;
  try {
    config = LlamaServerConfig.fromArgResults(parser.parse(arguments));
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (!File(config.libraryPath).existsSync()) {
    stderr.writeln('Library does not exist: ${config.libraryPath}');
    exitCode = 66;
    return;
  }
  if (!File(config.modelPath).existsSync()) {
    stderr.writeln('Model does not exist: ${config.modelPath}');
    exitCode = 66;
    return;
  }
  if (config.host == '0.0.0.0' && !config.noAuth && !config.apiKeyWasParsed) {
    stderr.writeln(
      'Warning: binding to 0.0.0.0 with the default API key. '
      'Pass --api-key for non-local use.',
    );
  }

  final llamaServer = LlamaServer(
    config: config,
    engine: UnavailableLlcsEngine(),
  );
  final server = await shelf_io.serve(
    llamaServer.handler,
    config.host,
    config.port,
  );

  stdout.writeln(
    'lib_llama_cpp_server listening on '
    'http://${server.address.host}:${server.port}',
  );
  stdout.writeln('model: ${config.alias}');
  stdout.writeln('model_path: ${config.modelPath}');
  stdout.writeln('caps: ${jsonEncode(await llamaServer.caps())}');

  final shutdown = Completer<void>();
  late final StreamSubscription<ProcessSignal> sigint;
  late final StreamSubscription<ProcessSignal> sigterm;
  Future<void> stop() async {
    if (shutdown.isCompleted) {
      return;
    }
    shutdown.complete();
    await server.close();
    await llamaServer.close();
    await sigint.cancel();
    await sigterm.cancel();
  }

  sigint = ProcessSignal.sigint.watch().listen((_) {
    unawaited(stop());
  });
  sigterm = ProcessSignal.sigterm.watch().listen((_) {
    unawaited(stop());
  });

  await shutdown.future;
}
