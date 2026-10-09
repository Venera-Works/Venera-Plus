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
