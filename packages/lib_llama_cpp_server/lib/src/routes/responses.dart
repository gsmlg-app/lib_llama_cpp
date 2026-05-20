import '../server.dart';

RouteResult convertResponsesRequest(
  Map<String, Object?> body, {
  required String alias,
  required String modelPath,
}) {
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

  final input = body['input'];
  if (input is! String || input.isEmpty) {
    return RouteResult.error(
      openAIErrorResponse(
        statusCode: 400,
        message: '`input` must be a non-empty string.',
        code: 'invalid_request_error',
        param: 'input',
      ),
    );
  }

  final messages = <Map<String, Object?>>[];
  final instructions = body['instructions'];
  if (instructions is String && instructions.isNotEmpty) {
    messages.add({'role': 'system', 'content': instructions});
  }
  messages.add({'role': 'user', 'content': input});

  final chatRequest = <String, Object?>{
    'model': alias,
    'messages': messages,
    if (body['max_output_tokens'] != null)
      'max_tokens': body['max_output_tokens'],
    if (body['temperature'] != null) 'temperature': body['temperature'],
    'stream': body['stream'] == true,
  };

  return RouteResult.value(chatRequest);
}

Map<String, Object?> responseBodyFromChatCompletion(
  Map<String, Object?> chatBody,
  String alias,
) {
  return {
    'id': 'resp_0',
    'object': 'response',
    'created_at': 0,
    'model': alias,
    'status': 'completed',
    'output_text': _extractOutputText(chatBody),
    'output': <Object?>[],
  };
}

String _extractOutputText(Map<String, Object?> chatBody) {
  final choices = chatBody['choices'];
  if (choices is! List || choices.isEmpty) {
    return '';
  }

  final first = choices.first;
  if (first is! Map) {
    return '';
  }

  final message = first['message'];
  if (message is Map) {
    return _contentToText(message['content']);
  }

  final delta = first['delta'];
  if (delta is Map) {
    return _contentToText(delta['content']);
  }

  return '';
}

String _contentToText(Object? content) {
  if (content is String) {
    return content;
  }
  if (content is List) {
    return content.map(_contentPartToText).join();
  }
  return '';
}

String _contentPartToText(Object? part) {
  if (part is String) {
    return part;
  }
  if (part is Map && part['text'] is String) {
    return part['text'] as String;
  }
  return '';
}
