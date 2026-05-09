# lib_llama_cpp

App-facing Flutter plugin facade for direct llama.cpp inference.

This package exposes a command stream API that resolves the platform native
library and runs inference lifecycle work through a dedicated isolate. It is the
package Flutter applications should depend on directly.

```dart
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

final client = const LibLlamaCpp();
final commands = Stream<LlamaCommand>.fromIterable([
  const LlamaLoadModelCommand(modelPath: '/path/to/model.gguf'),
  const LlamaGenerateCommand(prompt: 'Write one sentence.', maxTokens: 16),
  const LlamaDisposeCommand(),
]);

await for (final response in client.transform(commands)) {
  print(response);
}
```

The native generation path is still under active development. The current API
stabilizes package structure, federated platform resolution, command/response
types, and isolate lifecycle behavior.
