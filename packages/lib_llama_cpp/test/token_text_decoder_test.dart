import 'dart:convert';
import 'package:test/test.dart';
import 'package:lib_llama_cpp/src/token_text_decoder.dart';

void main() {
  test('decodes every byte boundary before matching unicode stops', () {
    for (final text in ['你好😀𠮷结束tail', 'hello😀结束tail']) {
      final decoder = TokenTextDecoder(stop: ['结束']);
      final output = StringBuffer();
      for (final byte in utf8.encode(text)) {
        output.write(decoder.add([byte]));
      }
      output.write(decoder.close());
      expect(output.toString(), text.split('结束').first);
      expect(decoder.isStopped, isTrue);
    }
  });
  test(
    'flushes a partial stop prefix and rejects incomplete utf8 residual',
    () {
      final decoder = TokenTextDecoder(stop: ['停止']);
      expect(decoder.add(utf8.encode('你好停')), '你好');
      expect(decoder.close(), '停');
      final incomplete = TokenTextDecoder();
      expect(incomplete.add([0xf0, 0x9f]), '');
      expect(incomplete.close, throwsFormatException);
    },
  );
  test('never emits unpaired surrogates while holding possible stops', () {
    final decoder = TokenTextDecoder(stop: ['end']);
    final chunks = [decoder.add(utf8.encode('😀')), decoder.close()];
    for (final chunk in chunks) {
      expect(utf8.decode(utf8.encode(chunk)), chunk);
    }
    expect(chunks.join(), '😀');
  });
}
