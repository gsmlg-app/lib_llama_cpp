import 'package:args/args.dart';

ArgParser buildLlamaServerArgParser() {
  return ArgParser()
    ..addOption('library', help: 'Path to the lib_llama_cpp dynamic library.')
    ..addOption('model', help: 'Path to the GGUF model.')
    ..addOption('alias', defaultsTo: 'local', help: 'Served model id.')
    ..addOption('host', defaultsTo: '127.0.0.1', help: 'Bind host.')
    ..addOption('port', defaultsTo: '8080', help: 'Bind port.')
    ..addOption('ctx-size', help: 'Context size.')
    ..addOption('gpu-layers', defaultsTo: '0', help: 'Number of GPU layers.')
    ..addOption('parallel', defaultsTo: '1', help: 'Parallel slot count.')
    ..addOption('chat-template', help: 'Optional llama.cpp chat template.')
    ..addOption('reasoning-format', help: 'Optional reasoning format.')
    ..addOption('api-key', defaultsTo: 'no-key', help: 'Bearer API key.')
    ..addFlag(
      'no-auth',
      defaultsTo: false,
      negatable: false,
      help: 'Disable bearer authentication for inference routes.',
    )
    ..addFlag(
      'cors',
      defaultsTo: false,
      negatable: false,
      help: 'Enable permissive CORS headers.',
    )
    ..addOption(
      'poll-timeout-ms',
      defaultsTo: '100',
      help: 'llcs poll timeout in milliseconds.',
    );
}

final class LlamaServerConfig {
  const LlamaServerConfig({
    required this.libraryPath,
    required this.modelPath,
    this.alias = 'local',
    this.host = '127.0.0.1',
    this.port = 8080,
    this.contextSize,
    this.gpuLayerCount = 0,
    this.parallelCount = 1,
    this.chatTemplate,
    this.reasoningFormat,
    this.apiKey = 'no-key',
    this.noAuth = false,
    this.cors = false,
    this.pollTimeout = const Duration(milliseconds: 100),
    this.apiKeyWasParsed = false,
  });

  factory LlamaServerConfig.fromArgResults(ArgResults args) {
    return LlamaServerConfig(
      libraryPath: _requiredString(args, 'library'),
      modelPath: _requiredString(args, 'model'),
      alias: _string(args, 'alias') ?? 'local',
      host: _string(args, 'host') ?? '127.0.0.1',
      port: _int(args, 'port') ?? 8080,
      contextSize: _int(args, 'ctx-size'),
      gpuLayerCount: _int(args, 'gpu-layers') ?? 0,
      parallelCount: _int(args, 'parallel') ?? 1,
      chatTemplate: _string(args, 'chat-template'),
      reasoningFormat: _string(args, 'reasoning-format'),
      apiKey: _string(args, 'api-key') ?? 'no-key',
      noAuth: args['no-auth'] as bool? ?? false,
      cors: args['cors'] as bool? ?? false,
      pollTimeout: Duration(milliseconds: _int(args, 'poll-timeout-ms') ?? 100),
      apiKeyWasParsed: args.wasParsed('api-key'),
    );
  }

  final String libraryPath;
  final String modelPath;
  final String alias;
  final String host;
  final int port;
  final int? contextSize;
  final int? gpuLayerCount;
  final int parallelCount;
  final String? chatTemplate;
  final String? reasoningFormat;
  final String apiKey;
  final bool noAuth;
  final bool cors;
  final Duration pollTimeout;
  final bool apiKeyWasParsed;
}

String _requiredString(ArgResults args, String name) {
  final value = _string(args, name);
  if (value == null || value.isEmpty) {
    throw FormatException('Missing required --$name option.');
  }
  return value;
}

String? _string(ArgResults args, String name) {
  final value = args[name] as String?;
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}

int? _int(ArgResults args, String name) {
  final value = _string(args, name);
  if (value == null) {
    return null;
  }
  final parsed = int.tryParse(value);
  if (parsed == null) {
    throw FormatException('--$name must be an integer.');
  }
  return parsed;
}
