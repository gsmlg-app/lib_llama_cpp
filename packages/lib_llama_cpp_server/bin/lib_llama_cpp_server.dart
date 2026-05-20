import 'dart:async';
import 'dart:io';

import 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';

Future<void> main(List<String> arguments) async {
  late final LlamaServerConfig config;
  try {
    config = LlamaServerConfig.fromArgs(arguments);
  } on LlamaServerConfigHelp catch (help) {
    stdout.write(help.message);
    return;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.write(LlamaServerConfig.usage);
    exitCode = 64;
    return;
  }

  if (!_isLocalPath(config.modelPath) || !File(config.modelPath).existsSync()) {
    stderr.writeln('Model file does not exist: ${config.modelPath}');
    exitCode = 66;
    return;
  }
  if (config.libraryPath != null && !File(config.libraryPath!).existsSync()) {
    stderr.writeln('Library file does not exist: ${config.libraryPath}');
    exitCode = 66;
    return;
  }

  late final LlamaHttpServer llamaServer;
  try {
    llamaServer = LlamaHttpServer.open(config: config);
  } on Object catch (error) {
    stderr.writeln('Failed to start llcs engine: $error');
    exitCode = 70;
    return;
  }

  final address = await llamaServer.start();
  stdout.writeln(
    'lib_llama_cpp_server listening on http://${address.host}:${address.port}',
  );
  stdout.writeln('model: ${config.model}');
  stdout.writeln('model_path: ${config.modelPath}');

  final shutdown = Completer<void>();
  late final StreamSubscription<ProcessSignal> sigint;
  late final StreamSubscription<ProcessSignal> sigterm;

  Future<void> stop() async {
    if (shutdown.isCompleted) {
      return;
    }
    shutdown.complete();
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

bool _isLocalPath(String path) {
  final uri = Uri.tryParse(path);
  return uri == null || !uri.hasScheme || uri.scheme == 'file';
}
