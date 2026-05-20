import 'llcs_engine.dart';

final class LlamaServerConfig {
  const LlamaServerConfig({
    required this.model,
    required this.modelPath,
    this.libraryPath,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.ctxSize,
    this.gpuLayers,
    this.parallel = 1,
    this.chatTemplate,
    this.reasoningFormat,
    this.logLevel,
    this.pollTimeout = const Duration(milliseconds: 100),
    this.maxRequestBytes = 1024 * 1024,
  });

  factory LlamaServerConfig.fromArgs(List<String> arguments) {
    final parsed = _FlagParser.parse(arguments);
    if (parsed.help) {
      throw const LlamaServerConfigHelp();
    }

    final modelPath = parsed.option('model-path');
    if (modelPath == null || modelPath.isEmpty) {
      throw const FormatException('Missing required --model-path option.');
    }

    return LlamaServerConfig(
      libraryPath: parsed.option('library'),
      model: parsed.option('model') ?? 'local',
      modelPath: modelPath,
      host: parsed.option('host') ?? '127.0.0.1',
      port: _parseInt(parsed.option('port'), 'port') ?? 8080,
      ctxSize: _parseInt(parsed.option('ctx-size'), 'ctx-size'),
      gpuLayers: _parseInt(parsed.option('gpu-layers'), 'gpu-layers'),
      parallel: _parseInt(parsed.option('parallel'), 'parallel') ?? 1,
      chatTemplate: parsed.option('chat-template'),
      reasoningFormat: parsed.option('reasoning-format'),
      logLevel: parsed.option('log-level'),
    );
  }

  final String model;
  final String modelPath;
  final String? libraryPath;
  final String host;
  final int port;
  final int? ctxSize;
  final int? gpuLayers;
  final int parallel;
  final String? chatTemplate;
  final String? reasoningFormat;
  final String? logLevel;
  final Duration pollTimeout;
  final int maxRequestBytes;

  LlcsEngineConfig toLlcsEngineConfig() {
    return LlcsEngineConfig(
      modelPath: modelPath,
      nCtx: ctxSize,
      nGpuLayers: gpuLayers,
      nParallel: parallel,
      chatTemplate: chatTemplate,
      reasoningFormat: reasoningFormat,
    );
  }

  static const usage = '''
Usage:
  dart run lib_llama_cpp_server --model-path /models/model.gguf [options]

Options:
  --host <host>                 Bind host. Default: 127.0.0.1
  --port <port>                 Bind port. Default: 8080
  --library <path>              Dynamic library path. Uses platform lookup when omitted.
  --model <alias>               Served model alias. Default: local
  --model-path <path>           Required local GGUF model path.
  --ctx-size <tokens>           Optional context size.
  --gpu-layers <count>          Optional GPU layer count.
  --parallel <count>            Parallel slot count. Default: 1
  --chat-template <template>    Optional chat template.
  --reasoning-format <format>   Optional reasoning format.
  --log-level <level>           Optional CLI log level.
  --help                        Print this help.
''';
}

final class LlamaServerConfigHelp implements FormatException {
  const LlamaServerConfigHelp();

  @override
  String get message => LlamaServerConfig.usage;

  @override
  int? get offset => null;

  @override
  dynamic get source => null;
}

int? _parseInt(String? value, String name) {
  if (value == null || value.isEmpty) {
    return null;
  }
  final parsed = int.tryParse(value);
  if (parsed == null) {
    throw FormatException('--$name must be an integer.');
  }
  return parsed;
}

final class _FlagParser {
  const _FlagParser(this._options, {required this.help});

  factory _FlagParser.parse(List<String> arguments) {
    final options = <String, String>{};
    var help = false;

    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        help = true;
        continue;
      }
      if (!argument.startsWith('--')) {
        throw FormatException('Unexpected argument: $argument');
      }

      final withoutPrefix = argument.substring(2);
      final equalsIndex = withoutPrefix.indexOf('=');
      if (equalsIndex >= 0) {
        options[withoutPrefix.substring(0, equalsIndex)] = withoutPrefix
            .substring(equalsIndex + 1);
        continue;
      }

      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('--')) {
        throw FormatException('Missing value for $argument.');
      }
      options[withoutPrefix] = arguments[index + 1];
      index += 1;
    }

    return _FlagParser(options, help: help);
  }

  final Map<String, String> _options;
  final bool help;

  String? option(String name) => _options[name];
}
