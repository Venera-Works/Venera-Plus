import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// An obsolete in-memory initialization must never publish itself as ready.
class SyncInitializationSupersededException implements Exception {
  const SyncInitializationSupersededException();

  @override
  String toString() => 'Synchronization initialization was superseded.';
}

/// Shared, payload-free context for one initialization and its bounded reload.
class SyncInitializationDiagnostics {
  SyncInitializationDiagnostics({
    required this.trigger,
    required String actor,
    required String stateDirectory,
    this.endpointHash,
    this.configurationGeneration,
    this.currentGeneration,
    this.dataSyncInstanceId,
    this.logger,
  }) : actorHash = digest(actor),
       stateDirHash = digest(stateDirectory),
       loadAttemptId = nextInstanceId('load');

  static int _sequence = 0;
  static final String _isolateId = identityHashCode(
    Isolate.current,
  ).toRadixString(16);

  static String nextInstanceId(String kind) =>
      '$kind-$pid-$_isolateId-${++_sequence}';

  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 16);

  final String trigger;
  final String actorHash;
  final String stateDirHash;
  final String loadAttemptId;
  final String? endpointHash;
  final int? configurationGeneration;
  final int Function()? currentGeneration;
  final String? dataSyncInstanceId;
  final void Function(String)? logger;

  Map<String, Object?> get metadata => {
    'processId': pid,
    'isolateId': _isolateId,
    'loadAttemptId': loadAttemptId,
    'trigger': trigger,
    'endpointHash': endpointHash,
    'actorHash': actorHash,
    'stateDirHash': stateDirHash,
    'configurationGeneration':
        currentGeneration?.call() ?? configurationGeneration,
    'expectedGeneration': configurationGeneration,
    if (dataSyncInstanceId != null) 'dataSyncInstanceId': dataSyncInstanceId,
  };

  void record(String phase, {Map<String, Object?> values = const {}}) {
    final sink = logger;
    if (sink == null) return;
    sink(jsonEncode({...metadata, ...values, 'phase': phase}));
  }
}
