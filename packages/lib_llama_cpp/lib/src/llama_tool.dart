final class LlamaTool {
  const LlamaTool({
    required this.name,
    this.description = '',
    this.parameters = const {},
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

final class LlamaToolChoice {
  const LlamaToolChoice.tool(String name) : this._('tool', name: name);

  const LlamaToolChoice._(this.mode, {this.name});

  static const auto = LlamaToolChoice._('auto');
  static const none = LlamaToolChoice._('none');
  static const required = LlamaToolChoice._('required');

  final String mode;
  final String? name;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaToolChoice && other.mode == mode && other.name == name;
  }

  @override
  int get hashCode => Object.hash(mode, name);

  @override
  String toString() {
    final toolName = name == null ? '' : ', name: $name';
    return 'LlamaToolChoice(mode: $mode$toolName)';
  }
}

final class LlamaToolCall {
  const LlamaToolCall({
    required this.id,
    required this.index,
    required this.name,
    required this.arguments,
  });

  final String id;
  final int index;
  final String name;
  final String arguments;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaToolCall &&
            other.id == id &&
            other.index == index &&
            other.name == name &&
            other.arguments == arguments;
  }

  @override
  int get hashCode => Object.hash(id, index, name, arguments);

  @override
  String toString() {
    return 'LlamaToolCall('
        'id: $id, '
        'index: $index, '
        'name: $name, '
        'arguments: $arguments'
        ')';
  }
}
