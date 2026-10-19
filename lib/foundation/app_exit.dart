import 'dart:io';

import 'package:flutter/foundation.dart';

Future<void> Function()? _prepareAppExit;
Future<void>? _pendingExit;

void configureAppExitPreparation(Future<void> Function()? handler) {
  _prepareAppExit = handler;
}

@visibleForTesting
void Function(int code)? debugExitProcess;

/// Every controlled desktop exit waits for the same in-flight preparation.
Future<void> exitApp() =>
    _pendingExit ??= _exitAfterPreparation().whenComplete(() {
      _pendingExit = null;
    });

Future<void> _exitAfterPreparation() async {
  await _prepareAppExit?.call();
  (debugExitProcess ?? exit)(0);
}
