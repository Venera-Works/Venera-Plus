import 'dart:io';

import 'package:flutter/services.dart';

import 'sync_device_name.dart';

export 'sync_device_name.dart';

const _deviceNameChannel = MethodChannel('venera/method_channel');

/// Reads a platform-provided device name and normalizes it for sync storage.
///
/// Mobile platforms use the application's native method channel. Desktop
/// platforms use the local hostname. Unsupported or unavailable metadata falls
/// back to a name based on the operating system.
Future<String> readSyncDeviceName() async {
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      final name = await _deviceNameChannel.invokeMethod<String>(
        'getSyncDeviceName',
      );
      if (name != null && name.trim().isNotEmpty) {
        try {
          return normalizeSyncDeviceName(name);
        } on FormatException {
          // Try the host name if the platform returned an unusable value.
        }
      }
    } on MissingPluginException {
      // Fall back to the runtime hostname when the native bridge is unavailable.
    } on PlatformException {
      // Fall back to the runtime hostname when native metadata is unavailable.
    }
  }

  try {
    final hostname = Platform.localHostname.trim();
    if (hostname.isNotEmpty && hostname.toLowerCase() != 'localhost') {
      try {
        return normalizeSyncDeviceName(hostname);
      } on FormatException {
        // Use the operating system name if the host name is unusable.
      }
    }
  } on UnsupportedError {
    // Some runtimes do not expose a host name.
  }

  return normalizeSyncDeviceName('${Platform.operatingSystem} Device');
}
