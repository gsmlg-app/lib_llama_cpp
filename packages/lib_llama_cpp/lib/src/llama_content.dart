import 'dart:typed_data';

sealed class LlamaContentPart {
  const LlamaContentPart();

  bool get isMedia {
    final part = this;
    return part is LlamaImageFilePart ||
        part is LlamaImageBytesPart ||
        part is LlamaAudioFilePart ||
        part is LlamaAudioBytesPart;
  }
}

final class LlamaTextPart extends LlamaContentPart {
  const LlamaTextPart(this.text);

  final String text;
}

final class LlamaImageFilePart extends LlamaContentPart {
  const LlamaImageFilePart({required this.path, this.mimeType});

  final String path;
  final String? mimeType;
}

final class LlamaImageBytesPart extends LlamaContentPart {
  const LlamaImageBytesPart({required this.bytes, this.mimeType});

  final Uint8List bytes;
  final String? mimeType;
}

final class LlamaAudioFilePart extends LlamaContentPart {
  const LlamaAudioFilePart({required this.path, this.mimeType});

  final String path;
  final String? mimeType;
}

final class LlamaAudioBytesPart extends LlamaContentPart {
  const LlamaAudioBytesPart({required this.bytes, this.mimeType});

  final Uint8List bytes;
  final String? mimeType;
}

bool llamaContentHasMedia(Object content) {
  if (content is List<LlamaContentPart>) {
    return content.any((part) => part.isMedia);
  }
  return false;
}

String llamaContentToPlainText(Object content) {
  if (content is String) {
    return content;
  }
  if (content is List<LlamaContentPart>) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is LlamaTextPart) {
        buffer.write(part.text);
      } else if (part.isMedia) {
        buffer.write('<__media__>');
      }
    }
    return buffer.toString();
  }
  throw ArgumentError.value(content, 'content', 'Unsupported message content');
}
