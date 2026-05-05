import 'dart:async';

import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'inference_isolate.dart';
import 'llama_command.dart';
import 'llama_response.dart';
import 'llama_state.dart';

final class LibLlamaCpp {
  const LibLlamaCpp({LibLlamaCppPlatform? platform}) : _platform = platform;

  final LibLlamaCppPlatform? _platform;

  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    final platform = _platform ?? LibLlamaCppPlatform.instance;
    final library = await platform.resolveLibrary(request: libraryRequest);
    final actor = await InferenceIsolate.spawn(
      library: library,
      initialState: initialState,
    );

    yield LlamaReadyResponse(library: library);

    try {
      await for (final command in commands) {
        yield* actor.dispatch(command);
        if (command is LlamaDisposeCommand) {
          break;
        }
      }
    } finally {
      actor.close();
    }
  }
}
