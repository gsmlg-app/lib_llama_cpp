import 'package:shelf/shelf.dart';

import '../config.dart';
import '../server.dart';

Response healthResponse({
  required LlamaServerConfig config,
  required Map<String, Object?> caps,
  required int activeRequests,
}) {
  return jsonResponse({
    'status': 'ok',
    'model': config.alias,
    'model_path': config.modelPath,
    'engine': 'llcs',
    'caps': caps,
    'active_requests': activeRequests,
  });
}
