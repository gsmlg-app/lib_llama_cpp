import 'package:lib_llama_cpp/src/llama_command.dart';
import 'package:lib_llama_cpp/src/llama_response.dart';
import 'package:lib_llama_cpp/src/llama_tool.dart';
import 'package:lib_llama_cpp/src/tool_aware_streaming.dart';
import 'package:test/test.dart';

void main() {
  test('streams parsed plain text deltas while tools are available', () {
    final parseCalls = <({String text, bool isPartial})>[];

    final responses = streamToolAwareMessageResponses(
      sampled: const [
        LlamaTokenResponse(text: 'Hello', index: 0),
        LlamaTokenResponse(text: ' world', index: 1),
      ],
      command: const LlamaGenerateMessagesCommand(
        messages: [LlamaMessage(role: 'user', content: 'Write a greeting.')],
        tools: [
          LlamaTool(name: 'lookup', parameters: {'type': 'object'}),
        ],
      ),
      parseChatOutput: (text, {required isPartial}) {
        parseCalls.add((text: text, isPartial: isPartial));
        return {
          'message': {'content': text},
        };
      },
    ).toList();

    expect(responses, const [
      LlamaTokenResponse(text: 'Hello', index: 0),
      LlamaTokenResponse(text: ' world', index: 1),
    ]);
    expect(parseCalls, const [
      (text: 'Hello', isPartial: true),
      (text: 'Hello world', isPartial: true),
      (text: 'Hello world', isPartial: false),
    ]);
  });

  test('emits parsed tool calls without streaming raw tool text', () {
    final responses = streamToolAwareMessageResponses(
      sampled: const [
        LlamaTokenResponse(text: '{"name":"lookup"', index: 0),
        LlamaTokenResponse(text: ',"arguments":{}}', index: 1),
      ],
      command: const LlamaGenerateMessagesCommand(
        messages: [LlamaMessage(role: 'user', content: 'Use lookup.')],
        tools: [
          LlamaTool(name: 'lookup', parameters: {'type': 'object'}),
        ],
      ),
      parseChatOutput: (text, {required isPartial}) {
        if (isPartial) {
          return {
            'message': {'content': ''},
          };
        }
        return {
          'message': {
            'tool_calls': [
              {
                'id': 'call_0',
                'function': {'name': 'lookup', 'arguments': '{}'},
              },
            ],
          },
        };
      },
    ).toList();

    expect(responses, const [
      LlamaToolCallResponse(
        toolCall: LlamaToolCall(
          id: 'call_0',
          index: 0,
          name: 'lookup',
          arguments: '{}',
        ),
      ),
    ]);
  });
}
