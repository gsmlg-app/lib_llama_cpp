enum LlamaCppLibraryResolution { process, executable, path, lookupName }

enum LlamaCppLibraryCapability {
  cpu,
  metal,
  cuda,
  vulkan,
  openCl,
  openBlas,
  rpc,
  nnapi,
}

final class LlamaCppLibraryRequest {
  const LlamaCppLibraryRequest({
    this.preferredPath,
    this.requiredCapabilities = const {},
  });

  final String? preferredPath;
  final Set<LlamaCppLibraryCapability> requiredCapabilities;
}

final class LlamaCppLibraryDescriptor {
  const LlamaCppLibraryDescriptor({
    required this.resolution,
    this.path,
    this.lookupName,
    this.capabilities = const {},
  });

  final LlamaCppLibraryResolution resolution;
  final String? path;
  final String? lookupName;
  final Set<LlamaCppLibraryCapability> capabilities;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LlamaCppLibraryDescriptor &&
            other.resolution == resolution &&
            other.path == path &&
            other.lookupName == lookupName &&
            _setEquals(other.capabilities, capabilities);
  }

  @override
  int get hashCode => Object.hash(
    resolution,
    path,
    lookupName,
    Object.hashAllUnordered(capabilities),
  );

  @override
  String toString() {
    final capabilityNames =
        capabilities.map((capability) => capability.name).toList()..sort();

    return 'LlamaCppLibraryDescriptor('
        'resolution: ${resolution.name}, '
        'path: $path, '
        'lookupName: $lookupName, '
        'capabilities: {${capabilityNames.join(', ')}}'
        ')';
  }
}

bool _setEquals<T>(Set<T> first, Set<T> second) {
  if (identical(first, second)) {
    return true;
  }
  if (first.length != second.length) {
    return false;
  }

  return first.every(second.contains);
}
