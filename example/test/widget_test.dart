import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_example/main.dart';

void main() {
  testWidgets('renders the e2e harness shell', (tester) async {
    await tester.pumpWidget(
      const InferenceDemoApp(
        config: LlamaE2eHarnessConfig(
          modelPath: '',
          modelAsset: '',
          mmprojPath: '',
          mmprojAsset: '',
          prompt: 'Say hello in one short sentence.',
          maxOutputTokens: 4,
          backend: '',
          gpuLayerCount: null,
        ),
      ),
    );

    expect(find.text('lib_llama_cpp E2E'), findsOneWidget);
    expect(find.text('Run harness smoke'), findsOneWidget);
    expect(find.text('No events yet'), findsOneWidget);
  });
}
