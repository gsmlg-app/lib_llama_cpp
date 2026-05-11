import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp_example/main.dart';

void main() {
  testWidgets('renders the isolate stream demo shell', (tester) async {
    await tester.pumpWidget(const InferenceDemoApp());

    expect(find.text('lib_llama_cpp'), findsOneWidget);
    expect(find.text('Run OpenAI stream'), findsOneWidget);
    expect(find.text('No events yet'), findsOneWidget);
  });
}
