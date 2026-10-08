final _invalidDeviceNameCharacters = RegExp(
  r'[\\/:*?"<>|%#\x00-\x1f\x7f-\x9f]',
);
final _trailingDeviceNameCharacters = RegExp(r'[. ]+$');
final _reservedDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
  caseSensitive: false,
);

/// Returns a safe, non-empty single directory segment for a sync device.
///
/// Characters that can change path/URL structure or are forbidden by common
/// filesystems are replaced with underscores. Windows-incompatible trailing
/// dots and spaces are removed, and reserved device names are prefixed.
/// Empty names and dot path segments are rejected.
String normalizeSyncDeviceName(String name) {
  final normalized = name
      .replaceAll(_invalidDeviceNameCharacters, '_')
      .trim()
      .replaceAll(_trailingDeviceNameCharacters, '');

  if (normalized.isEmpty || normalized == '.' || normalized == '..') {
    throw const FormatException('Device name must be a non-empty path segment');
  }

  if (_reservedDeviceName.hasMatch(normalized)) {
    return '_$normalized';
  }
  return normalized;
}
