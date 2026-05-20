import 'package:shelf/shelf.dart';

import '../config.dart';
import '../server.dart';

Response modelsResponse({
  required LlamaServerConfig config,
  required Map<String, Object?> caps,
}) {
  return jsonResponse({
    'object': 'list',
    'data': [
      {
        'id': config.alias,
        'object': 'model',
        'created': 0,
        'owned_by': 'llamacpp',
        'meta': {'model_path': config.modelPath, 'caps': caps},
      },
    ],
  });
}
