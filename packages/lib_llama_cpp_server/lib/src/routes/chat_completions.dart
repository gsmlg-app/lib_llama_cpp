import '../server.dart';

RouteResult normalizeChatCompletionRequest(
  Map<String, Object?> body, {
  required String alias,
  required String modelPath,
}) {
  final messages = body['messages'];
  if (messages is! List) {
    return RouteResult.error(
      openAIErrorResponse(
        statusCode: 400,
        message: '`messages` is required.',
        code: 'invalid_request_error',
        param: 'messages',
      ),
    );
  }

  final model = body['model'];
  if (model != null && model != alias && model != modelPath) {
    return RouteResult.error(
      openAIErrorResponse(
        statusCode: 404,
        message: 'Model `$model` is not loaded.',
        code: 'model_not_found',
        param: 'model',
      ),
    );
  }

  return RouteResult.value({
    ...body,
    'model': alias,
    'stream': body['stream'] == true,
  });
}
