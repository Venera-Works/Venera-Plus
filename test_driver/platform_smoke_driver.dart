import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:integration_test/integration_test_driver.dart';

const List<int> _kPngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 15),
  responseDataCallback: (data) async {
    final encoded = data?['smokeScreenshotPng'];
    if (encoded is! String || encoded.isEmpty) {
      throw StateError(
        'Missing or invalid smokeScreenshotPng payload in reportData: $encoded',
      );
    }

    final bytes = base64Decode(encoded);
    if (bytes.length < 24) {
      throw StateError(
        'Invalid PNG data: payload is too short (${bytes.length} bytes)',
      );
    }

    for (var i = 0; i < _kPngSignature.length; i++) {
      if (bytes[i] != _kPngSignature[i]) {
        throw StateError(
          'Invalid PNG signature at offset $i: expected ${_kPngSignature[i]}, got ${bytes[i]}',
        );
      }
    }

    final view = ByteData.sublistView(bytes);
    final width = view.getUint32(16);
    final height = view.getUint32(20);
    if (width == 0 || height == 0) {
      throw StateError(
        'Invalid PNG dimensions parsed from header: ${width}x$height',
      );
    }

    stdout.writeln(
      'Android smoke screenshot validated: ${width}x$height (${bytes.length} bytes)',
    );

    final artifactFile = File('build/smoke-artifacts/android_smoke.png');
    artifactFile.parent.createSync(recursive: true);
    artifactFile.writeAsBytesSync(bytes);
    stdout.writeln('Saved Android smoke screenshot to ${artifactFile.path}');
  },
);
