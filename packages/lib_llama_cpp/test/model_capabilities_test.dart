import 'package:lib_llama_cpp/src/llama_state.dart';
import 'package:test/test.dart';

void main() {
  test('template presence alone never advertises tools or reasoning', () {
    final capabilities = LlamaModelCapabilities.fromTemplateCapabilities(
      const {},
      hasChatTemplate: true,
    );
    expect(capabilities.chatTemplate, isTrue);
    expect(capabilities.tools, isFalse);
    expect(capabilities.reasoning, isNull);
  });
  test('uses exact upstream tool and reasoning capabilities', () {
    final capabilities = LlamaModelCapabilities.fromTemplateCapabilities(const {
      'supports_tools': true,
      'supports_tool_calls': true,
      'supports_reasoning': true,
    }, hasChatTemplate: true);
    expect(capabilities.tools, isTrue);
    expect(capabilities.reasoning, isTrue);
    expect(
      LlamaModelCapabilities.fromTemplateCapabilities(const {
        'supports_tools': true,
        'supports_tool_calls': false,
        'supports_reasoning': false,
      }).tools,
      isFalse,
    );
  });
}
