import 'dart:io';

import 'package:flutter/services.dart';

import 'sync_device_name.dart';

export 'sync_device_name.dart';

const _deviceNameChannel = MethodChannel('venera/method_channel');

/// Reads platform hardware metadata and normalizes it for sync storage.
///
/// Hostnames and user-configurable device names are deliberately not used:
/// unavailable hardware metadata falls back to a non-sensitive OS label.
Future<String> readSyncDeviceName() async {
  String? name;
  if (Platform.isLinux) {
    name = await _readLinuxHardwareName();
  } else {
    try {
      name = await _deviceNameChannel.invokeMethod<String>('getSyncDeviceName');
    } on MissingPluginException {
      // Use the OS label when the platform bridge is unavailable.
    } on PlatformException {
      // Use the OS label when native metadata is unavailable.
    }
  }

  var hardwareName = name?.trim();
  if (Platform.isWindows && hardwareName != null && hardwareName.isNotEmpty) {
    hardwareName = formatSyncDeviceHardwareName(brand: hardwareName);
  }
  if (hardwareName != null && hardwareName.isNotEmpty) {
    try {
      return normalizeSyncDeviceName(hardwareName);
    } on FormatException {
      // Use the non-sensitive OS label if hardware metadata is unusable.
    }
  }

  return normalizeSyncDeviceName('${_syncDeviceOperatingSystemName()} Device');
}

Future<String?> _readLinuxHardwareName() async {
  final brand = await _readLinuxDmiValue('sys_vendor');
  final model = await _readLinuxDmiValue('product_name');
  return formatSyncDeviceHardwareName(brand: brand, model: model);
}

Future<String?> _readLinuxDmiValue(String field) async {
  try {
    final value = (await File(
      '/sys/class/dmi/id/$field',
    ).readAsString()).trim();
    return value.isEmpty ? null : value;
  } on FileSystemException {
    return null;
  } on UnsupportedError {
    return null;
  }
}

String _syncDeviceOperatingSystemName() => switch (Platform.operatingSystem) {
  'android' => 'Android',
  'ios' => 'iOS',
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  final name => name,
};
