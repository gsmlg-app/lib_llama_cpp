import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'llama_cpp_library.dart';

abstract class LibLlamaCppPlatform extends PlatformInterface {
  LibLlamaCppPlatform() : super(token: _token);

  static final Object _token = Object();

  static LibLlamaCppPlatform _instance = UnimplementedLibLlamaCppPlatform();

  static LibLlamaCppPlatform get instance => _instance;

  static set instance(LibLlamaCppPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) {
    throw UnimplementedError('resolveLibrary() has not been implemented.');
  }
}

final class UnimplementedLibLlamaCppPlatform extends LibLlamaCppPlatform {}
