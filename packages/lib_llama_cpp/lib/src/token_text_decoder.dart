import 'dart:convert';

/// Decodes native token bytes strictly before withholding possible stop prefixes.
final class TokenTextDecoder {
  TokenTextDecoder({List<String> stop = const []})
    : _stops = stop.where((text) => text.isNotEmpty).toList() {
    _decoder = const Utf8Decoder().startChunkedConversion(
      StringConversionSink.fromStringSink(_decoded),
    );
  }

  final List<String> _stops;
  final StringBuffer _decoded = StringBuffer();
  late final ByteConversionSink _decoder;
  var _pending = '';
  var isStopped = false;

  String add(List<int> bytes) {
    if (isStopped) return '';
    _decoder.add(bytes);
    _pending += _decoded.toString();
    _decoded.clear();
    int? stopIndex;
    for (final stop in _stops) {
      final index = _pending.indexOf(stop);
      if (index >= 0 && (stopIndex == null || index < stopIndex)) {
        stopIndex = index;
      }
    }
    if (stopIndex != null) {
      isStopped = true;
      final text = _pending.substring(0, stopIndex);
      _pending = '';
      return text;
    }
    var hold = 0;
    for (final stop in _stops) {
      for (
        var length = 1;
        length < stop.length && length <= _pending.length;
        length++
      ) {
        if (length > hold && _pending.endsWith(stop.substring(0, length))) {
          hold = length;
        }
      }
    }
    var end = _pending.length - hold;
    // Stop prefixes can begin between the UTF-16 pair of an astral character.
    if (end > 0 &&
        end < _pending.length &&
        _pending.codeUnitAt(end - 1) >= 0xd800 &&
        _pending.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    final text = _pending.substring(0, end);
    _pending = _pending.substring(end);
    return text;
  }

  String close() {
    if (isStopped) return '';
    _decoder.close(); // Strictly rejects an unfinished UTF-8 scalar.
    final text = _pending + _decoded.toString();
    _pending = '';
    _decoded.clear();
    return text;
  }
}
