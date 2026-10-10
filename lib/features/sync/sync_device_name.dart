final _invalidDeviceNameCharacters = RegExp(
  r'[\\/:*?"<>|%#\x00-\x1f\x7f-\x9f]',
);
final _trailingDeviceNameCharacters = RegExp(r'[. ]+$');
final _reservedDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
  caseSensitive: false,
);
final _reservedSyncDirectory = RegExp(
  r'^(sync-v4|sync-v5)$',
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

  if (_reservedDeviceName.hasMatch(normalized) ||
      _reservedSyncDirectory.hasMatch(normalized)) {
    return '_$normalized';
  }
  return normalized;
}

/// Builds a device label from hardware metadata, without repeating the brand
/// when the model already includes it.
///
/// Returns `null` when neither value contains usable hardware metadata.
String? formatSyncDeviceHardwareName({String? brand, String? model}) {
  final normalizedBrand = _canonicalSyncDeviceBrand(brand);
  final normalizedModel = _usableSyncDeviceHardwareValue(model);

  if (normalizedModel == null) return normalizedBrand;
  if (normalizedBrand == null ||
      normalizedModel.toLowerCase().startsWith(normalizedBrand.toLowerCase())) {
    return normalizedModel;
  }
  return '$normalizedBrand $normalizedModel';
}

String? _canonicalSyncDeviceBrand(String? value) {
  final brand = _usableSyncDeviceHardwareValue(value);
  if (brand == null) return null;

  final key = brand.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return switch (key) {
    'lenovo' => 'Lenovo',
    'dell' || 'dellinc' => 'Dell',
    'hp' || 'hpinc' || 'hewlettpackard' => 'HP',
    'asus' || 'asustek' || 'asustekcomputerinc' => 'ASUS',
    'acer' || 'acerinc' => 'Acer',
    'apple' || 'appleinc' => 'Apple',
    'microsoft' || 'microsoftcorporation' => 'Microsoft',
    'samsung' || 'samsungelectronics' => 'Samsung',
    'google' || 'googleinc' => 'Google',
    'xiaomi' => 'Xiaomi',
    'huawei' || 'huaweitechnologiescoltd' => 'Huawei',
    'motorola' => 'Motorola',
    'oneplus' => 'OnePlus',
    'redmi' => 'Redmi',
    'poco' => 'POCO',
    _ => _titleCaseSyncDeviceBrand(brand),
  };
}

String _titleCaseSyncDeviceBrand(String brand) => brand
    .split(RegExp(r'\s+'))
    .map((word) {
      final lower = word.toLowerCase();
      return lower.isEmpty
          ? lower
          : '${lower[0].toUpperCase()}${lower.substring(1)}';
    })
    .join(' ');

String? _usableSyncDeviceHardwareValue(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final key = trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (const {
    'unknown',
    'none',
    'notspecified',
    'defaultstring',
    'systemmanufacturer',
    'systemproductname',
    'tobefilledbyoem',
  }.contains(key)) {
    return null;
  }
  return trimmed;
}
