import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// SQLite's default exception text includes SQL parameters (possibly an entire
/// snapshot). Keep the failure code, not those payloads, at UI/log boundaries.
String mergeStoreErrorMessage(Object error) {
  if (error is SqliteException) {
    return 'SYNC_LOCAL_DATABASE_FAILURE: Local synchronization database '
        'operation failed; reload before retrying '
        '(${jsonEncode({'sqliteCode': error.extendedResultCode})}).';
  }
  return error.toString();
}

/// UI surfaces show a stable code and action, not instance/revision diagnostics.
/// Keep the original message for logs and exception propagation.
String? mergeStoreErrorSummary(String? message) {
  if (message == null) return null;
  final separator = message.indexOf(':');
  if (separator < 0) return message;
  final code = message.substring(0, separator);
  return switch (code) {
    'SYNC_STATE_CHANGED' =>
      'SYNC_STATE_CHANGED: Synchronization state changed. Retry synchronization; details are in the log.',
    'SYNC_STATE_DIVERGED' =>
      'SYNC_STATE_DIVERGED: Keep both synchronization databases and inspect the log before repair.',
    'SYNC_STATE_INVALID' =>
      'SYNC_STATE_INVALID: Synchronization data was preserved. Inspect the log before repair.',
    'SYNC_OUTBOX_COUNTER_CONFLICT' =>
      'SYNC_OUTBOX_COUNTER_CONFLICT: Pending changes were preserved. Inspect the log before repair.',
    'SYNC_RECOVERY_REMOTE_UNVERIFIED' =>
      'SYNC_RECOVERY_REMOTE_UNVERIFIED: Check the connection and remote backup data, then retry synchronization.',
    'SYNC_LOCAL_DATABASE_FAILURE' =>
      'SYNC_LOCAL_DATABASE_FAILURE: Check local storage and retry synchronization; details are in the log.',
    _ => message,
  };
}

/// Local causal-state failures. Diagnostics contain identities and counters only,
/// never business records, snapshot bodies, credentials, or source scripts.
class MergeStoreStateException extends FormatException {
  final String code;
  final Map<String, Object?> metadata;
  final bool recoverable;

  MergeStoreStateException(
    this.code,
    String message, {
    Map<String, Object?> metadata = const {},
    this.recoverable = false,
  }) : metadata = Map.unmodifiable(metadata),
       super(message);

  @override
  String toString() => '$code: $message (${jsonEncode(metadata)})';
}

class MergeOutboxCounterConflictException extends MergeStoreStateException {
  final String actor;
  final int counter;
  final String existingBatchId;
  final String incomingBatchId;

  MergeOutboxCounterConflictException({
    required this.actor,
    required this.counter,
    required this.existingBatchId,
    required this.incomingBatchId,
    Map<String, Object?> metadata = const {},
  }) : super(
         'SYNC_OUTBOX_COUNTER_CONFLICT',
         'A pending publication already owns this actor/counter. '
             'Local synchronization state was preserved; automatic retries '
             'are paused. Repair the state before retrying manually.',
         metadata: {
           ...metadata,
           'actor': actor,
           'counter': counter,
           'existingBatchId': existingBatchId,
           'incomingBatchId': incomingBatchId,
         },
       );
}

class MergeStoreStaleStateException extends MergeStoreStateException {
  MergeStoreStaleStateException({Map<String, Object?> metadata = const {}})
    : super(
        'SYNC_STATE_CHANGED',
        'Durable synchronization state changed after it was loaded. '
            'Reload it before allocating or committing another event.',
        metadata: metadata,
        recoverable: true,
      );
}

class MergeStoreReplicaDivergenceException extends MergeStoreStateException {
  MergeStoreReplicaDivergenceException({
    Map<String, Object?> metadata = const {},
  }) : super(
         'SYNC_STATE_DIVERGED',
         'Primary and backup synchronization states disagree at the same '
             'revision. Both copies were preserved; automatic retries are '
             'paused. Keep both databases for explicit diagnosis and repair.',
         metadata: metadata,
       );
}

class MergeStoreIntegrityException extends MergeStoreStateException {
  MergeStoreIntegrityException({Map<String, Object?> metadata = const {}})
    : super(
        'SYNC_STATE_INVALID',
        'Local synchronization state has inconsistent causal identities. '
            'The durable state was preserved; automatic retries are paused.',
        metadata: metadata,
      );
}

class MergeStoreRemoteRecoveryException extends MergeStoreStateException {
  MergeStoreRemoteRecoveryException({Map<String, Object?> metadata = const {}})
    : super(
        'SYNC_RECOVERY_REMOTE_UNVERIFIED',
        'Cannot verify this device\'s remote publications after backup recovery. '
            'Pending local changes and the counter-recovery requirement were '
            'preserved. Restore the missing/corrupt remote data or connection '
            'and retry synchronization.',
        metadata: metadata,
        recoverable: true,
      );
}
