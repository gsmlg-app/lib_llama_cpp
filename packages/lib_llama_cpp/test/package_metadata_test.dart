import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('package metadata', () {
    test('Apple podspec versions match package versions', () {
      final root = _repoRoot();
      final packages = {
        'lib_llama_cpp_ios': (
          pubspec: root / 'packages/lib_llama_cpp_ios/pubspec.yaml',
          podspec:
              root / 'packages/lib_llama_cpp_ios/ios/lib_llama_cpp_ios.podspec',
        ),
        'lib_llama_cpp_macos': (
          pubspec: root / 'packages/lib_llama_cpp_macos/pubspec.yaml',
          podspec:
              root /
              'packages/lib_llama_cpp_macos/macos/lib_llama_cpp_macos.podspec',
        ),
      };

      for (final entry in packages.entries) {
        final pubspecVersion = _pubspecVersion(entry.value.pubspec);
        final podspecVersion = _podspecVersion(entry.value.podspec);

        expect(
          podspecVersion,
          pubspecVersion,
          reason:
              '${entry.key} podspec version must match its pubspec version.',
        );
      }
    });

    test('facade package re-exports the local server package', () {
      final root = _repoRoot();
      final pubspec = (root / 'packages/lib_llama_cpp/pubspec.yaml')
          .readAsStringSync();
      final library = (root / 'packages/lib_llama_cpp/lib/lib_llama_cpp.dart')
          .readAsStringSync();

      expect(pubspec, contains('  lib_llama_cpp_server: ^'));
      expect(
        library,
        contains(
          "export 'package:lib_llama_cpp_server/lib_llama_cpp_server.dart';",
        ),
      );
    });
  });
}

Directory _repoRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/melos.yaml').existsSync() &&
        Directory('${current.path}/packages/lib_llama_cpp').existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'Could not find repository root from ${Directory.current.path}',
      );
    }
    current = parent;
  }
}

String _pubspecVersion(File file) {
  final match = RegExp(
    r'^version:\s*([^\s]+)\s*$',
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  if (match == null) {
    throw StateError('Could not find version in ${file.path}');
  }
  return match.group(1)!;
}

String _podspecVersion(File file) {
  final match = RegExp(
    r'''s\.version\s*=\s*['"]([^'"]+)['"]''',
  ).firstMatch(file.readAsStringSync());
  if (match == null) {
    throw StateError('Could not find s.version in ${file.path}');
  }
  return match.group(1)!;
}

extension on Directory {
  File operator /(String child) => File('$path/$child');
}
