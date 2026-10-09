import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

import '../../foundation/sync_records.dart';
import 'merge_engine.dart';
import 'merge_snapshot.dart';

/// Normalized, close-after-use SQLite persistence backing [MergeStore].
///
/// The durable representation is split into record rows, causal metadata rows,
/// and immutable snapshot object references. No connection escapes an operation,
/// which also ensures Windows can replace/restore the database between commits.
class MergeStoreDatabase {
  final MergeSnapshotEncodingCache _snapshotEncodingCache =
      MergeSnapshotEncodingCache();
  final Directory directory;
  final String actor;

  final Map<(String, String, String), String> _persistedRows = {};
  final Map<String, String> _persistedMeta = {};
  final Set<String> _persistedReceived = {};
  final Set<String> _persistedOutboxIds = {};
  final Map<String, Set<String>> _persistedOutboxChangedRecords = {};
  int _persistedRevision = 0;
  bool _loaded = false;
  bool _databaseExists = false;

  MergeStoreDatabase(this.directory, this.actor);

  File get _databaseFile => File('${directory.path}/merge_store.sqlite3');
  File get _backupFile => File('${_databaseFile.path}.bak');

  Future<MergeStoreDatabaseState?> load() async {
    _loaded = false;
    _databaseExists = false;
    _persistedRows.clear();
    _persistedMeta.clear();
    _persistedReceived.clear();
    _persistedOutboxIds.clear();
    _persistedOutboxChangedRecords.clear();
    _persistedRevision = 0;
    await directory.create(recursive: true);
    final primaryExists = await _exists(_databaseFile);
    final backupExists = await _exists(_backupFile);
    if (!backupExists) {
      for (final suffix in ['.bak-journal', '.bak-wal', '.bak-shm']) {
        if (await _exists(File('${_databaseFile.path}$suffix'))) {
          throw const FormatException('Incomplete merge SQLite replica');
        }
      }
    }
    if (!primaryExists && !backupExists) {
      for (final suffix in [
        '.tmp',
        '.restore.tmp',
        '.bak.tmp',
        '-journal',
        '-wal',
        '-shm',
        '.bak-journal',
        '.bak-wal',
        '.bak-shm',
      ]) {
        if (await _exists(File('${_databaseFile.path}$suffix'))) {
          throw const FormatException('Incomplete merge SQLite state');
        }
      }
      _loaded = false;
      _databaseExists = false;
      _persistedRevision = 0;
      return null;
    }

    MergeStoreDatabaseState? primaryState;
    Object? primaryError;
    if (primaryExists) {
      try {
        primaryState = _readDatabase(_databaseFile, recoveredFromBackup: false);
      } on _DatabaseActorMismatch {
        rethrow;
      } catch (error) {
        primaryError = error;
      }
    }

    MergeStoreDatabaseState? backupState;
    Object? backupError;
    if (backupExists) {
      try {
        backupState = _readDatabase(_backupFile, recoveredFromBackup: false);
      } on _DatabaseActorMismatch {
        rethrow;
      } catch (error) {
        backupError = error;
      }
    }

    late final MergeStoreDatabaseState state;
    if (primaryState == null) {
      if (backupState == null) {
        throw FormatException(
          'Invalid merge SQLite state and backup: $primaryError; $backupError',
        );
      }
      await _restorePrimaryFromBackup();
      state = backupState.withRecovery(true);
    } else if (backupState == null) {
      await _repairBackupFromPrimary();
      state = primaryState;
    } else if (backupState.commitRevision > primaryState.commitRevision) {
      await _restorePrimaryFromBackup();
      state = backupState.withRecovery(true);
    } else {
      if (backupState.commitRevision < primaryState.commitRevision) {
        await _repairBackupFromPrimary();
      }
      state = primaryState;
    }

    _activateState(state);
    return state;
  }

  void _activateState(MergeStoreDatabaseState state) {
    _persistedRows
      ..clear()
      ..addAll(state.persistedRows);
    _persistedMeta
      ..clear()
      ..addAll(state.persistedMeta);
    _persistedReceived
      ..clear()
      ..addAll(state.received);
    _persistedOutboxIds
      ..clear()
      ..addAll(state.outboxIds);
    _persistedOutboxChangedRecords
      ..clear()
      ..addAll(state.outboxChangedRecords);
    _persistedRevision = state.commitRevision;
    _databaseExists = true;
    _loaded = true;
  }

  MergeBatch pendingBatch(String id, {required MergeDocument currentDocument}) {
    _ensureLoaded();
    final database = sqlite3.open(_databaseFile.path);
    try {
      database.execute('PRAGMA busy_timeout = 5000;');
      final rows = database.select(
        'SELECT actor, counter, manifest FROM merge_outbox WHERE batch_id = ?;',
        [id],
      );
      if (rows.length != 1) {
        throw StateError('No pending merge batch with id "$id"');
      }
      final row = rows.single;
      final actor = row['actor'] as String;
      final counter = row['counter'] as int;
      final manifest = _asBytes(row['manifest']);
      final objectRows = database.select(
        '''
        SELECT objects.path, objects.content
        FROM merge_outbox_objects AS refs
        JOIN merge_snapshot_objects AS objects ON objects.path = refs.path
        WHERE refs.batch_id = ?;
        ''',
        [id],
      );
      final objects = <String, Uint8List>{};
      for (final objectRow in objectRows) {
        final path = objectRow['path'] as String;
        if (objects.containsKey(path)) {
          throw const FormatException('Duplicate outbox object reference');
        }
        objects[path] = _asBytes(objectRow['content']);
      }
      final batch = MergeSnapshot.decode(manifest, objects);
      if (batch.id != id ||
          batch.actor != actor ||
          actor != this.actor ||
          batch.counter != counter ||
          batch.document.counterFor(actor) != counter ||
          counter > currentDocument.counterFor(actor)) {
        throw const FormatException('Invalid persisted outbox snapshot');
      }
      return batch;
    } finally {
      database.close();
    }
  }

  MergeSnapshot pendingSnapshot(String id) {
    _ensureLoaded();
    final database = sqlite3.open(_databaseFile.path);
    try {
      database.execute('PRAGMA busy_timeout = 5000;');
      final rows = database.select(
        'SELECT actor, counter, manifest FROM merge_outbox WHERE batch_id = ?;',
        [id],
      );
      if (rows.length != 1) {
        throw StateError('No pending merge batch with id "$id"');
      }
      final row = rows.single;
      final batchActor = row['actor'] as String;
      final counter = row['counter'] as int;
      final manifest = _asBytes(row['manifest']);
      final objectRows = database.select(
        '''
        SELECT objects.path, objects.content
        FROM merge_outbox_objects AS refs
        JOIN merge_snapshot_objects AS objects ON objects.path = refs.path
        WHERE refs.batch_id = ?;
        ''',
        [id],
      );
      final objects = <String, Uint8List>{};
      for (final objectRow in objectRows) {
        final path = objectRow['path'] as String;
        if (objects.containsKey(path)) {
          throw const FormatException('Duplicate outbox object reference');
        }
        objects[path] = _asBytes(objectRow['content']);
      }
      final snapshot = MergeSnapshot.fromEncoded(manifest, objects);
      if (batchActor != actor ||
          snapshot.manifest['batchId'] != id ||
          snapshot.manifest['actor'] != batchActor ||
          snapshot.manifest['counter'] != counter) {
        throw const FormatException('Invalid persisted outbox snapshot');
      }
      return snapshot;
    } finally {
      database.close();
    }
  }

  Future<Map<String, MergeSnapshot>> commit({
    required MergeDocument document,
    required MergeDocument localObservation,
    required SyncRecords observed,
    required Set<String> received,
    required List<String> outboxIds,
    required Map<String, MergeBatch> newOutboxBatches,
    required Map<String, Set<String>> outboxChangedRecords,
    required SyncRecords? pendingApply,
    required Set<String> pendingUnavailableDomains,
    required bool initialized,
  }) async {
    if (_loaded && !_databaseExists) {
      throw StateError('Invalid SQLite store lifecycle');
    }
    final nextRows = _encodeRows(
      {'document': document, 'localObservation': localObservation},
      observed,
      pendingApply,
    );
    final nextMeta = <String, String>{
      'actor': actor,
      'initialized': initialized ? '1' : '0',
      'hasPendingApply': pendingApply == null ? '0' : '1',
      'pendingUnavailableDomains': canonicalSyncJson(
        pendingUnavailableDomains.toList()..sort(),
      ),
      'legacyStateMigrated': '1',
      'outboxDeltasVersion': '1',
      'commitRevision': '$_persistedRevision',
    };
    final nextReceived = Set<String>.of(received);
    final nextOutboxIds = List<String>.of(outboxIds);
    if (nextOutboxIds.toSet().length != nextOutboxIds.length) {
      throw const FormatException('Duplicate pending outbox id');
    }

    final rowsChanged = !_sameRowValues(_persistedRows, nextRows);
    final metaChanged = !_sameMap(_persistedMeta, nextMeta);
    final receivedChanged = !_sameSet(_persistedReceived, nextReceived);
    final desiredOutbox = nextOutboxIds.toSet();
    final removedOutbox = _persistedOutboxIds.difference(desiredOutbox);
    final addedOutbox = desiredOutbox.difference(_persistedOutboxIds);
    if (outboxChangedRecords.keys.any((id) => !desiredOutbox.contains(id))) {
      throw const FormatException(
        'Changed-record metadata has no outbox batch',
      );
    }
    final nextOutboxChangedRecords = <String, Set<String>>{};
    for (final entry in outboxChangedRecords.entries) {
      for (final key in entry.value) {
        _validateRecordKey(key);
      }
      if (entry.value.isNotEmpty) {
        nextOutboxChangedRecords[entry.key] = Set<String>.of(entry.value);
      }
    }
    final changedOutboxDeltas =
        <String>{
              ..._persistedOutboxChangedRecords.keys,
              ...nextOutboxChangedRecords.keys,
            }
            .where(
              (id) => !_sameSet(
                _persistedOutboxChangedRecords[id] ?? const <String>{},
                nextOutboxChangedRecords[id] ?? const <String>{},
              ),
            )
            .toSet();
    final needsCreate = !_databaseExists;
    if (!needsCreate &&
        !rowsChanged &&
        !metaChanged &&
        !receivedChanged &&
        removedOutbox.isEmpty &&
        changedOutboxDeltas.isEmpty &&
        addedOutbox.isEmpty) {
      return const <String, MergeSnapshot>{};
    }
    final nextRevision = _persistedRevision + 1;
    nextMeta['commitRevision'] = '$nextRevision';

    for (final id in addedOutbox) {
      if (!newOutboxBatches.containsKey(id)) {
        throw StateError('Missing in-memory batch for new outbox entry "$id"');
      }
    }
    final nextOutboxSnapshots = <String, MergeSnapshot>{};
    for (final id in addedOutbox) {
      final batch = newOutboxBatches[id]!;
      if (batch.actor != actor ||
          batch.counter <= 0 ||
          batch.document.counterFor(actor) != batch.counter) {
        throw const FormatException('Invalid new outbox batch');
      }
      nextOutboxSnapshots[id] = MergeSnapshot.fromBatch(
        batch,
        encodingCache: _snapshotEncodingCache,
      );
    }

    Database? database;
    try {
      database = sqlite3.open(_databaseFile.path);
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('ATTACH DATABASE ? AS replica;', [_backupFile.path]);
      database.execute('PRAGMA main.journal_mode = DELETE;');
      database.execute('PRAGMA replica.journal_mode = DELETE;');
      database.execute('PRAGMA main.synchronous = FULL;');
      database.execute('PRAGMA replica.synchronous = FULL;');
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('BEGIN IMMEDIATE;');
      try {
        _ensureSchema(database, schema: 'main');
        _ensureSchema(database, schema: 'replica');
        if (_databaseExists) {
          _assertCommitRevision(database, schema: 'main');
          _assertCommitRevision(database, schema: 'replica');
        }
        for (final schema in ['main', 'replica']) {
          if (_persistedMeta.containsKey('checkpointMigrationComplete')) {
            database.execute(
              'DROP TABLE IF EXISTS $schema.merge_checkpoint_inventory;',
            );
          }
          _applyRowDiff(database, nextRows, schema: schema);
          _applyMetaDiff(database, nextMeta, schema: schema);
          _applyReceivedDiff(database, nextReceived, schema: schema);
          _applyOutboxChanges(
            database,
            schema: schema,
            removed: removedOutbox,
            added: addedOutbox,
            newBatches: newOutboxBatches,
            deltaChanges: changedOutboxDeltas,
            changedRecords: nextOutboxChangedRecords,
            newSnapshots: nextOutboxSnapshots,
          );
        }
        database.execute('COMMIT;');
      } catch (_) {
        database.execute('ROLLBACK;');
        rethrow;
      }
    } finally {
      database?.close();
    }

    _persistedRows
      ..clear()
      ..addEntries(
        nextRows.entries.map(
          (entry) => MapEntry(entry.key, _rowFingerprint(entry.value)),
        ),
      );
    _persistedMeta
      ..clear()
      ..addAll(nextMeta);
    _persistedReceived
      ..clear()
      ..addAll(nextReceived);
    _persistedOutboxIds
      ..clear()
      ..addAll(desiredOutbox);
    _persistedOutboxChangedRecords
      ..clear()
      ..addAll(nextOutboxChangedRecords);
    _databaseExists = true;
    _persistedRevision = nextRevision;
    _loaded = true;
    return Map.unmodifiable(nextOutboxSnapshots);
  }

  MergeStoreDatabaseState _readDatabase(
    File file, {
    required bool recoveredFromBackup,
  }) {
    Database? database;
    try {
      database = sqlite3.open(file.path);
      database.execute('PRAGMA busy_timeout = 5000;');
      final integrity = database.select('PRAGMA integrity_check;');
      if (integrity.length != 1 || integrity.single.values.first != 'ok') {
        throw const FormatException('SQLite integrity check failed');
      }
      final version = database
          .select('PRAGMA user_version;')
          .single
          .values
          .first;
      if (version != 1) {
        throw FormatException(
          'Unsupported merge SQLite schema version: $version',
        );
      }
      final meta = <String, String>{};
      for (final row in database.select(
        'SELECT key, value FROM merge_store_meta;',
      )) {
        final key = row['key'] as String;
        if (meta.containsKey(key)) {
          throw const FormatException('Duplicate store metadata');
        }
        meta[key] = row['value'] as String;
      }
      const requiredMeta = {
        'actor',
        'initialized',
        'hasPendingApply',
        'pendingUnavailableDomains',
        'legacyStateMigrated',
        'outboxDeltasVersion',
        'commitRevision',
      };
      const allowedMeta = {...requiredMeta, 'checkpointMigrationComplete'};
      if (!meta.keys.toSet().containsAll(requiredMeta) ||
          !allowedMeta.containsAll(meta.keys)) {
        throw const FormatException('Invalid merge SQLite metadata');
      }
      if (meta['actor'] != actor) {
        throw _DatabaseActorMismatch(actor, meta['actor']!);
      }
      if (!{'0', '1'}.contains(meta['initialized']) ||
          !{'0', '1'}.contains(meta['hasPendingApply']) ||
          meta['legacyStateMigrated'] != '1' ||
          meta['outboxDeltasVersion'] != '1' ||
          (meta.containsKey('checkpointMigrationComplete') &&
              !{'0', '1'}.contains(meta['checkpointMigrationComplete']))) {
        throw const FormatException('Invalid merge SQLite metadata values');
      }
      final commitRevision = int.tryParse(meta['commitRevision']!);
      if (commitRevision == null ||
          commitRevision <= 0 ||
          '$commitRevision' != meta['commitRevision']) {
        throw const FormatException('Invalid merge commit revision');
      }
      final rows = <(String, String, String), String>{};
      final documents = <String, MergeDocument>{};
      for (final scope in ['document', 'localObservation']) {
        final vclock = <String, Object?>{};
        final eventDigests = <String, Object?>{};
        final records = <String, Object?>{};
        for (final row in database.select(
          'SELECT actor, counter FROM merge_document_vclock WHERE scope = ?;',
          [scope],
        )) {
          final actor = row['actor'] as String;
          final counter = row['counter'] as int;
          if (actor.isEmpty || counter < 0 || vclock.containsKey(actor)) {
            throw const FormatException('Invalid document counter row');
          }
          vclock[actor] = counter;
          rows[('vclock', scope, actor)] = _rowFingerprint('$counter');
        }
        for (final row in database.select(
          'SELECT dot, digest FROM merge_document_event_digests WHERE scope = ?;',
          [scope],
        )) {
          final dot = row['dot'] as String;
          final digest = row['digest'] as String;
          if (eventDigests.containsKey(dot)) {
            throw const FormatException('Duplicate document event digest');
          }
          eventDigests[dot] = digest;
          rows[('event', scope, dot)] = _rowFingerprint(digest);
        }
        for (final row in database.select(
          'SELECT record_key, value_json FROM merge_document_records WHERE scope = ?;',
          [scope],
        )) {
          final key = row['record_key'] as String;
          final encoded = row['value_json'] as String;
          final value = _decodeCanonicalObject(encoded);
          if (records.containsKey(key)) {
            throw const FormatException('Duplicate document record row');
          }
          records[key] = value;
          rows[('doc', scope, key)] = _rowFingerprint(encoded);
        }
        final rawDocument = <String, Object?>{
          'schema': 3,
          'vclock': vclock,
          'eventDigests': eventDigests,
          'records': records,
        };
        final document = MergeDocument.fromJson(rawDocument);
        if (!syncValuesEqual(rawDocument, document.toJson())) {
          throw const FormatException(
            'Noncanonical or incomplete SQLite merge document',
          );
        }
        documents[scope] = document;
      }
      final document = documents['document']!;
      final localObservation = documents['localObservation']!;
      if (!document.dominates(localObservation)) {
        throw const FormatException(
          'Invalid local business causal observation',
        );
      }
      final recordsByKind = <String, SyncRecords>{
        'observed': <String, Map<String, Object?>>{},
        'pendingApply': <String, Map<String, Object?>>{},
      };
      for (final row in database.select(
        'SELECT kind, record_key, value_json FROM merge_business_records;',
      )) {
        final kind = row['kind'] as String;
        final key = row['record_key'] as String;
        final encoded = row['value_json'] as String;
        final recordSet = recordsByKind[kind];
        if (recordSet == null || recordSet.containsKey(key)) {
          throw const FormatException('Invalid business record row');
        }
        final value = _decodeCanonicalObject(encoded);
        _validateRecordKey(key);
        _validateJson(value);
        recordSet[key] = value;
        rows[(kind, '', key)] = _rowFingerprint(encoded);
      }
      final observed = recordsByKind['observed']!;
      final pendingRecords = recordsByKind['pendingApply']!;
      final pendingApply = meta['hasPendingApply'] == '1'
          ? pendingRecords
          : null;
      if (meta['initialized'] == '0' && observed.isNotEmpty) {
        throw const FormatException(
          'Uninitialized state has an observed baseline',
        );
      }
      if (pendingApply == null && pendingRecords.isNotEmpty) {
        throw const FormatException('Unexpected pending apply records');
      }
      final pendingUnavailableDomains = _decodeDomains(
        meta['pendingUnavailableDomains']!,
      );
      if (pendingApply == null && pendingUnavailableDomains.isNotEmpty) {
        throw const FormatException('Pending domains without a pending apply');
      }
      final received = <String>{};
      for (final row in database.select(
        'SELECT filename FROM merge_received;',
      )) {
        final filename = row['filename'] as String;
        if (filename.isEmpty || !received.add(filename)) {
          throw const FormatException('Invalid or duplicate received filename');
        }
      }
      final outboxIds = <String>[];
      final outboxCounters = <int>{};
      for (final row in database.select(
        'SELECT batch_id, actor, counter FROM merge_outbox ORDER BY counter ASC, batch_id ASC;',
      )) {
        final id = row['batch_id'] as String;
        final batchActor = row['actor'] as String;
        final counter = row['counter'] as int;
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
            batchActor != actor ||
            counter <= 0 ||
            counter > document.counterFor(batchActor) ||
            !outboxCounters.add(counter)) {
          throw const FormatException('Invalid durable outbox metadata');
        }
        outboxIds.add(id);
      }
      final outboxChangedRecords = <String, Set<String>>{};
      for (final row in database.select(
        'SELECT batch_id, record_key FROM merge_outbox_changed_records;',
      )) {
        final batchId = row['batch_id'] as String;
        final key = row['record_key'] as String;
        if (!outboxIds.contains(batchId)) {
          throw const FormatException('Orphaned changed-record metadata');
        }
        _validateRecordKey(key);
        if (!outboxChangedRecords
            .putIfAbsent(batchId, () => <String>{})
            .add(key)) {
          throw const FormatException('Duplicate changed-record metadata');
        }
      }
      for (final row in database.select(
        'SELECT batch_id, path FROM merge_outbox_objects;',
      )) {
        final batchId = row['batch_id'] as String;
        final path = row['path'] as String;
        if (!outboxIds.contains(batchId) || path.isEmpty) {
          throw const FormatException('Orphaned outbox object reference');
        }
        final object = database.select(
          'SELECT 1 FROM merge_snapshot_objects WHERE path = ?;',
          [path],
        );
        if (object.length != 1) {
          throw const FormatException('Missing outbox snapshot object');
        }
      }
      return MergeStoreDatabaseState(
        document: document,
        localObservation: localObservation,
        observed: observed,
        received: received,
        outboxIds: outboxIds,
        outboxChangedRecords: outboxChangedRecords,
        pendingApply: pendingApply,
        pendingUnavailableDomains: pendingUnavailableDomains,
        initialized: meta['initialized'] == '1',
        recoveredFromBackup: recoveredFromBackup,
        persistedRows: rows,
        persistedMeta: meta,
        commitRevision: commitRevision,
      );
    } finally {
      database?.close();
    }
  }

  void _ensureSchema(Database database, {required String schema}) {
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_store_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_records (
        scope TEXT NOT NULL,
        record_key TEXT NOT NULL,
        value_json TEXT NOT NULL,
        PRIMARY KEY (scope, record_key)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_vclock (
        scope TEXT NOT NULL,
        actor TEXT NOT NULL,
        counter INTEGER NOT NULL,
        PRIMARY KEY (scope, actor)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_event_digests (
        scope TEXT NOT NULL,
        dot TEXT NOT NULL,
        digest TEXT NOT NULL,
        PRIMARY KEY (scope, dot)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_business_records (
        kind TEXT NOT NULL,
        record_key TEXT NOT NULL,
        value_json TEXT NOT NULL,
        PRIMARY KEY (kind, record_key)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_received (
        filename TEXT PRIMARY KEY NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox (
        batch_id TEXT PRIMARY KEY NOT NULL,
        actor TEXT NOT NULL,
        counter INTEGER NOT NULL,
        manifest BLOB NOT NULL,
        UNIQUE (actor, counter)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_snapshot_objects (
        path TEXT PRIMARY KEY NOT NULL,
        content BLOB NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox_objects (
        batch_id TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (batch_id, path),
        FOREIGN KEY (batch_id) REFERENCES merge_outbox(batch_id) ON DELETE CASCADE,
        FOREIGN KEY (path) REFERENCES merge_snapshot_objects(path)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox_changed_records (
        batch_id TEXT NOT NULL,
        record_key TEXT NOT NULL,
        PRIMARY KEY (batch_id, record_key),
        FOREIGN KEY (batch_id) REFERENCES merge_outbox(batch_id) ON DELETE CASCADE
      );
    ''');
    database.execute('PRAGMA $schema.user_version = 1;');
    final storedActor = database.select(
      "SELECT value FROM $schema.merge_store_meta WHERE key = 'actor';",
    );
    if (storedActor.isNotEmpty && storedActor.single['value'] != actor) {
      throw _DatabaseActorMismatch(
        actor,
        storedActor.single['value'] as String,
      );
    }
  }

  void _assertCommitRevision(Database database, {required String schema}) {
    final rows = database.select('''
      SELECT key, value FROM $schema.merge_store_meta
      WHERE key IN ('actor', 'commitRevision');
      ''');
    final metadata = <String, String>{
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    if (metadata['actor'] != null && metadata['actor'] != actor) {
      throw _DatabaseActorMismatch(actor, metadata['actor']!);
    }
    if (metadata.length != 2 ||
        metadata['actor'] != actor ||
        metadata['commitRevision'] != '$_persistedRevision') {
      throw const FormatException('Attached SQLite replica revision mismatch');
    }
  }

  Map<(String, String, String), String> _encodeRows(
    Map<String, MergeDocument> documents,
    SyncRecords observed,
    SyncRecords? pendingApply,
  ) {
    final result = <(String, String, String), String>{};
    for (final entry in documents.entries) {
      final json = entry.value.toJson();
      final scope = entry.key;
      final vclock = (json['vclock'] as Map).cast<String, Object?>();
      for (final counter in vclock.entries) {
        result[('vclock', scope, counter.key)] = '${counter.value}';
      }
      final eventDigests = (json['eventDigests'] as Map)
          .cast<String, Object?>();
      for (final event in eventDigests.entries) {
        result[('event', scope, event.key)] = event.value as String;
      }
      final records = (json['records'] as Map).cast<String, Object?>();
      for (final record in records.entries) {
        result[('doc', scope, record.key)] = canonicalSyncJson(record.value);
      }
    }
    for (final entry in observed.entries) {
      result[('observed', '', entry.key)] = canonicalSyncJson(entry.value);
    }
    if (pendingApply != null) {
      for (final entry in pendingApply.entries) {
        result[('pendingApply', '', entry.key)] = canonicalSyncJson(
          entry.value,
        );
      }
    }
    return result;
  }

  void _applyRowDiff(
    Database database,
    Map<(String, String, String), String> next, {
    required String schema,
  }) {
    for (final entry in _persistedRows.entries) {
      if (next.containsKey(entry.key)) continue;
      final (kind, scope, key) = entry.key;
      switch (kind) {
        case 'doc':
          database.execute(
            'DELETE FROM $schema.merge_document_records WHERE scope = ? AND record_key = ?;',
            [scope, key],
          );
          break;
        case 'vclock':
          database.execute(
            'DELETE FROM $schema.merge_document_vclock WHERE scope = ? AND actor = ?;',
            [scope, key],
          );
          break;
        case 'event':
          database.execute(
            'DELETE FROM $schema.merge_document_event_digests WHERE scope = ? AND dot = ?;',
            [scope, key],
          );
          break;
        case 'observed':
        case 'pendingApply':
          database.execute(
            'DELETE FROM $schema.merge_business_records WHERE kind = ? AND record_key = ?;',
            [kind, key],
          );
          break;
      }
    }
    for (final entry in next.entries) {
      if (_persistedRows[entry.key] == _rowFingerprint(entry.value)) continue;
      final (kind, scope, key) = entry.key;
      switch (kind) {
        case 'doc':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_records(scope, record_key, value_json)
            VALUES (?, ?, ?);
            ''',
            [scope, key, entry.value],
          );
          break;
        case 'vclock':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_vclock(scope, actor, counter)
            VALUES (?, ?, ?);
            ''',
            [scope, key, int.parse(entry.value)],
          );
          break;
        case 'event':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_event_digests(scope, dot, digest)
            VALUES (?, ?, ?);
            ''',
            [scope, key, entry.value],
          );
          break;
        case 'observed':
        case 'pendingApply':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_business_records(kind, record_key, value_json)
            VALUES (?, ?, ?);
            ''',
            [kind, key, entry.value],
          );
          break;
      }
    }
  }

  void _applyMetaDiff(
    Database database,
    Map<String, String> next, {
    required String schema,
  }) {
    for (final entry in next.entries) {
      if (_persistedMeta[entry.key] == entry.value) continue;
      database.execute(
        'INSERT OR REPLACE INTO $schema.merge_store_meta(key, value) VALUES (?, ?);',
        [entry.key, entry.value],
      );
    }
    for (final key in _persistedMeta.keys) {
      if (!next.containsKey(key)) {
        database.execute(
          'DELETE FROM $schema.merge_store_meta WHERE key = ?;',
          [key],
        );
      }
    }
  }

  void _applyReceivedDiff(
    Database database,
    Set<String> next, {
    required String schema,
  }) {
    for (final filename in _persistedReceived.difference(next)) {
      database.execute(
        'DELETE FROM $schema.merge_received WHERE filename = ?;',
        [filename],
      );
    }
    for (final filename in next.difference(_persistedReceived)) {
      database.execute(
        'INSERT INTO $schema.merge_received(filename) VALUES (?);',
        [filename],
      );
    }
  }

  void _applyOutboxChanges(
    Database database, {
    required String schema,
    required Set<String> removed,
    required Set<String> added,
    required Map<String, MergeBatch> newBatches,
    required Set<String> deltaChanges,
    required Map<String, Set<String>> changedRecords,
    required Map<String, MergeSnapshot> newSnapshots,
  }) {
    for (final id in removed) {
      database.execute(
        'DELETE FROM $schema.merge_outbox_objects WHERE batch_id = ?;',
        [id],
      );
      database.execute(
        'DELETE FROM $schema.merge_outbox_changed_records WHERE batch_id = ?;',
        [id],
      );
      database.execute('DELETE FROM $schema.merge_outbox WHERE batch_id = ?;', [
        id,
      ]);
    }
    for (final id in added) {
      final batch = newBatches[id]!;
      final snapshot = newSnapshots[id]!;
      final manifest = snapshot.serializeManifest();
      database.execute(
        '''
        INSERT INTO $schema.merge_outbox(batch_id, actor, counter, manifest)
        VALUES (?, ?, ?, ?);
        ''',
        [batch.id, batch.actor, batch.counter, manifest],
      );
      for (final entry in snapshot.objects.entries) {
        final prior = database.select(
          'SELECT content FROM $schema.merge_snapshot_objects WHERE path = ?;',
          [entry.key],
        );
        if (prior.isNotEmpty &&
            !_bytesEqual(_asBytes(prior.single['content']), entry.value)) {
          throw const FormatException(
            'Snapshot object path has conflicting content',
          );
        }
        if (prior.isEmpty) {
          database.execute(
            'INSERT INTO $schema.merge_snapshot_objects(path, content) VALUES (?, ?);',
            [entry.key, entry.value],
          );
        }
        database.execute(
          'INSERT INTO $schema.merge_outbox_objects(batch_id, path) VALUES (?, ?);',
          [id, entry.key],
        );
      }
    }
    for (final id in deltaChanges.difference(removed)) {
      database.execute(
        'DELETE FROM $schema.merge_outbox_changed_records WHERE batch_id = ?;',
        [id],
      );
      for (final key in changedRecords[id] ?? const <String>{}) {
        database.execute(
          'INSERT INTO $schema.merge_outbox_changed_records(batch_id, record_key) VALUES (?, ?);',
          [id, key],
        );
      }
    }
    if (removed.isNotEmpty) {
      database.execute('''
        DELETE FROM $schema.merge_snapshot_objects AS objects
        WHERE NOT EXISTS (
          SELECT 1 FROM $schema.merge_outbox_objects AS refs
          WHERE refs.path = objects.path
        );
      ''');
    }
  }

  Future<void> _repairBackupFromPrimary() async {
    if (!await _exists(_databaseFile)) return;
    final temporary = File('${_backupFile.path}.tmp');
    await _databaseFile.copy(temporary.path);
    await temporary.rename(_backupFile.path);
  }

  Future<void> _restorePrimaryFromBackup() async {
    final temporary = File('${_databaseFile.path}.restore.tmp');
    await _backupFile.copy(temporary.path);
    await temporary.rename(_databaseFile.path);
  }

  void _ensureLoaded() {
    if (!_loaded || !_databaseExists) {
      throw StateError('MergeStore database must successfully load before use');
    }
  }

  static Map<String, Object?> _decodeCanonicalObject(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Expected a JSON record object');
    }
    final result = value.cast<String, Object?>();
    if (canonicalSyncJson(result) != encoded) {
      throw const FormatException('Noncanonical SQLite record row');
    }
    return result;
  }

  static Set<String> _decodeDomains(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! List) throw const FormatException('Invalid pending domains');
    final domains = <String>{};
    for (final domain in value) {
      if (domain is! String ||
          !{'source', 'sourceSession'}.contains(domain) ||
          !domains.add(domain)) {
        throw const FormatException('Invalid pending domains');
      }
    }
    if (canonicalSyncJson(value) != encoded) {
      throw const FormatException('Noncanonical pending domains');
    }
    return domains;
  }

  static void _validateRecordKey(String key) {
    final identity = decodeSyncRecordKey(key);
    if (identity.isEmpty ||
        identity.first is! String ||
        (identity.first as String).isEmpty) {
      throw const FormatException('Invalid business record identity');
    }
    _validateJson(identity);
  }

  static void _validateJson(Object? value) {
    if (value == null || value is bool || value is String) return;
    if (value is num && value.isFinite) return;
    if (value is List) {
      for (final item in value) {
        _validateJson(item);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('JSON map key is not a string');
        }
        _validateJson(entry.value);
      }
      return;
    }
    throw const FormatException('Invalid JSON business field');
  }

  static Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw const FormatException('Invalid SQLite snapshot bytes');
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameRowValues(
    Map<(String, String, String), String> persisted,
    Map<(String, String, String), String> next,
  ) =>
      persisted.length == next.length &&
      next.entries.every(
        (entry) => persisted[entry.key] == _rowFingerprint(entry.value),
      );

  static String _rowFingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static bool _sameMap<K, V>(Map<K, V> left, Map<K, V> right) =>
      left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);

  static Future<bool> _exists(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;
}

class MergeStoreDatabaseState {
  final MergeDocument document;
  final MergeDocument localObservation;
  final SyncRecords observed;
  final Set<String> received;
  final List<String> outboxIds;
  final SyncRecords? pendingApply;
  final Set<String> pendingUnavailableDomains;
  final Map<String, Set<String>> outboxChangedRecords;
  final bool initialized;
  final bool recoveredFromBackup;
  final Map<(String, String, String), String> persistedRows;
  final Map<String, String> persistedMeta;
  final int commitRevision;

  const MergeStoreDatabaseState({
    required this.document,
    required this.localObservation,
    required this.observed,
    required this.received,
    required this.outboxIds,
    required this.pendingApply,
    required this.outboxChangedRecords,
    required this.pendingUnavailableDomains,
    required this.initialized,
    required this.recoveredFromBackup,
    required this.persistedRows,
    required this.persistedMeta,
    required this.commitRevision,
  });
  MergeStoreDatabaseState withRecovery(bool value) => MergeStoreDatabaseState(
    document: document,
    localObservation: localObservation,
    observed: observed,
    received: received,
    outboxIds: outboxIds,
    pendingApply: pendingApply,
    outboxChangedRecords: outboxChangedRecords,
    pendingUnavailableDomains: pendingUnavailableDomains,
    initialized: initialized,
    recoveredFromBackup: value,
    persistedRows: persistedRows,
    persistedMeta: persistedMeta,
    commitRevision: commitRevision,
  );
}

class _DatabaseActorMismatch extends StateError {
  _DatabaseActorMismatch(String expected, String actual)
    : super('Store actor mismatch: expected "$expected", found "$actual"');
}
