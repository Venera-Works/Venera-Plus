import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/sync_records.dart';

/// Durable record of a quarantined source file.
class SourceQuarantineRecord {
  final String originalPath;
  final String filename;
  final String originalHash;
  final String backupPath;
  final String reason;
  final DateTime timestamp;
  final int fileSize;
  final String? sourceKey;
  final String? recoveredByKey;
  final bool recovered;

  const SourceQuarantineRecord({
    required this.originalPath,
    required this.filename,
    required this.originalHash,
    required this.backupPath,
    required this.reason,
    required this.timestamp,
    required this.fileSize,
    this.sourceKey,
    this.recoveredByKey,
    this.recovered = false,
  });

  SourceQuarantineRecord copyWith({
    String? originalPath,
    String? filename,
    String? originalHash,
    String? backupPath,
    String? reason,
    DateTime? timestamp,
    int? fileSize,
    String? sourceKey,
    String? recoveredByKey,
    bool? recovered,
  }) {
    return SourceQuarantineRecord(
      originalPath: originalPath ?? this.originalPath,
      filename: filename ?? this.filename,
      originalHash: originalHash ?? this.originalHash,
      backupPath: backupPath ?? this.backupPath,
      reason: reason ?? this.reason,
      timestamp: timestamp ?? this.timestamp,
      fileSize: fileSize ?? this.fileSize,
      sourceKey: sourceKey ?? this.sourceKey,
      recoveredByKey: recoveredByKey ?? this.recoveredByKey,
      recovered: recovered ?? this.recovered,
    );
  }

  Map<String, Object?> toJson() => {
    'originalPath': originalPath,
    'filename': filename,
    'originalHash': originalHash,
    'backupPath': backupPath,
    'reason': reason,
    'timestamp': timestamp.toIso8601String(),
    'fileSize': fileSize,
    if (sourceKey != null) 'sourceKey': sourceKey,
    if (recoveredByKey != null) 'recoveredByKey': recoveredByKey,
    'recovered': recovered,
  };

  factory SourceQuarantineRecord.fromJson(Map<String, Object?> json) {
    final originalPath = json['originalPath'];
    final filename = json['filename'];
    final originalHash = json['originalHash'];
    final backupPath = json['backupPath'];
    final reason = json['reason'];
    final timestampStr = json['timestamp'];
    final fileSize = json['fileSize'];
    final recovered = json['recovered'];

    if (originalPath is! String || originalPath.isEmpty) {
      throw const FormatException(
        'Invalid originalPath in quarantine record: must be non-empty string',
      );
    }
    if (filename is! String || filename.isEmpty) {
      throw const FormatException(
        'Invalid filename in quarantine record: must be non-empty string',
      );
    }
    SourceFileMetadata.validateFileName(filename);
    if (originalHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(originalHash)) {
      throw const FormatException(
        'Invalid originalHash in quarantine record: must be 64-hex SHA-256',
      );
    }
    if (backupPath is! String || backupPath.isEmpty) {
      throw const FormatException(
        'Invalid backupPath in quarantine record: must be non-empty string',
      );
    }
    if (reason is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(reason)) {
      throw const FormatException('Invalid reason in quarantine record');
    }
    if (timestampStr is! String || DateTime.tryParse(timestampStr) == null) {
      throw const FormatException(
        'Invalid timestamp in quarantine record: must be valid ISO-8601 string',
      );
    }
    if (fileSize is! int || fileSize < 0) {
      throw const FormatException(
        'Invalid fileSize in quarantine record: must be non-negative integer',
      );
    }
    if (recovered is! bool) {
      throw const FormatException(
        'Invalid recovered flag in quarantine record: must be boolean',
      );
    }

    final sourceKeyRaw = json['sourceKey'];
    if (sourceKeyRaw != null && sourceKeyRaw is! String) {
      throw const FormatException('Invalid sourceKey in quarantine record');
    }
    final sourceKey = sourceKeyRaw as String?;
    if (sourceKey != null) SourceFileMetadata.validateKey(sourceKey);
    final recoveredByKeyRaw = json['recoveredByKey'];
    if (recoveredByKeyRaw != null && recoveredByKeyRaw is! String) {
      throw const FormatException(
        'Invalid recoveredByKey in quarantine record',
      );
    }
    final recoveredByKey = recoveredByKeyRaw as String?;
    if (recoveredByKey != null) {
      SourceFileMetadata.validateKey(recoveredByKey);
      if (sourceKey != null && recoveredByKey != sourceKey) {
        throw const FormatException(
          'Recovered source key does not match quarantine identity',
        );
      }
      if (!recovered) {
        throw const FormatException(
          'Unrecovered quarantine record cannot have recoveredByKey',
        );
      }
    }
    return SourceQuarantineRecord(
      originalPath: originalPath,
      filename: filename,
      originalHash: originalHash,
      backupPath: backupPath,
      reason: reason,
      timestamp: DateTime.parse(timestampStr),
      fileSize: fileSize,
      sourceKey: sourceKey,
      recoveredByKey: recoveredByKey,
      recovered: recovered,
    );
  }
}

/// Manages private per-profile quarantine storage for corrupted or empty source files.
class SourceQuarantineManager {
  final Directory sourceDir;

  SourceQuarantineManager(this.sourceDir);

  Directory get quarantineDir =>
      Directory(p.join(sourceDir.path, '.quarantine'));
  Directory get recordsDir => Directory(p.join(quarantineDir.path, 'records'));
  File get journalFile => File(p.join(quarantineDir.path, 'journal.json'));
  File get journalBakFile =>
      File(p.join(quarantineDir.path, 'journal.json.bak'));

  Future<void> _ensureDirs(void Function()? beforeCommit) async {
    if (!await recordsDir.exists()) {
      beforeCommit?.call();
      await recordsDir.create(recursive: true);
    }
  }

  /// Atomically replaces the quarantine journal using a verified staged file.
  /// The old primary remains intact if staging or rename fails.
  Future<void> _atomicWriteJournal(
    List<SourceQuarantineRecord> records, {
    required String? expectedJournalDigest,
    void Function()? beforeCommit,
  }) async {
    await _ensureDirs(beforeCommit);
    final jsonBytes = utf8.encode(
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
    final tempJournal = File(
      p.join(
        quarantineDir.path,
        '.journal_stage_${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    );
    try {
      beforeCommit?.call();
      await tempJournal.writeAsBytes(jsonBytes, flush: true);
      if (sha256.convert(await tempJournal.readAsBytes()).toString() !=
          sha256.convert(jsonBytes).toString()) {
        throw const FileSystemException('Quarantine journal staging failed');
      }
      await SourceFileMetadata.atomicReplace(
        tempJournal,
        journalFile,
        beforeCommit: () {
          beforeCommit?.call();
          if (_digestFileSync(journalFile) != expectedJournalDigest) {
            throw const _RecoveryConflict();
          }
        },
      );
    } finally {
      await tempJournal.deleteIgnoreError();
    }
  }

  /// Strictly validates and reads the quarantine journal. A backup is never
  /// used to substitute for a missing/corrupt primary because it may omit blockers.
  Future<List<SourceQuarantineRecord>> readJournal() async {
    if (!await journalFile.exists()) {
      if (await journalBakFile.exists()) {
        throw const FormatException(
          'Quarantine journal primary is missing while a backup exists',
        );
      }
      return [];
    }
    if (await journalFile.length() == 0) {
      throw const FormatException('Empty quarantine journal');
    }
    final decoded = jsonDecode(await journalFile.readAsString());
    if (decoded is! List) {
      throw const FormatException('Quarantine journal root must be a list');
    }
    final records = <SourceQuarantineRecord>[];
    for (final item in decoded) {
      if (item is! Map) {
        throw const FormatException('Invalid quarantine journal entry');
      }
      final record = SourceQuarantineRecord.fromJson(
        Map<String, Object?>.from(item),
      );
      _validateRecordPaths(record);
      if (!await verifyBackup(record)) {
        throw const FormatException(
          'Quarantine record backup is missing or corrupt',
        );
      }
      records.add(record);
    }
    return records;
  }

  void _validateRecordPaths(SourceQuarantineRecord record) {
    final sourceCanonical = p.canonicalize(sourceDir.path);
    final originalCanonical = p.canonicalize(record.originalPath);
    final backupCanonical = p.canonicalize(record.backupPath);
    if (p.dirname(originalCanonical) != sourceCanonical ||
        p.basename(originalCanonical) != record.filename ||
        p.dirname(backupCanonical) != p.canonicalize(recordsDir.path) ||
        !p.basename(backupCanonical).startsWith('${record.originalHash}_')) {
      throw const FormatException('Unsafe quarantine journal path');
    }
  }

  Future<bool> verifyBackup(SourceQuarantineRecord record) async {
    _validateRecordPaths(record);
    final backupFile = File(record.backupPath);
    if (!await backupFile.exists()) return false;
    final bytes = await backupFile.readAsBytes();
    return bytes.length == record.fileSize &&
        sha256.convert(bytes).toString() == record.originalHash;
  }

  bool verifyBackupSync(SourceQuarantineRecord record) {
    _validateRecordPaths(record);
    final backupFile = File(record.backupPath);
    if (!backupFile.existsSync()) return false;
    final bytes = backupFile.readAsBytesSync();
    return bytes.length == record.fileSize &&
        sha256.convert(bytes).toString() == record.originalHash;
  }

  Future<void> markRecovered(
    String filename, {
    required String originalHash,
    String? sourceKey,
    void Function()? beforeCommit,
  }) async {
    if (sourceKey != null) SourceFileMetadata.validateKey(sourceKey);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(originalHash)) {
      throw const FormatException('Invalid recovered source digest');
    }
    final expectedJournalDigest = await SourceRecovery._digestFile(journalFile);
    final existing = await readJournal();
    if (await SourceRecovery._digestFile(journalFile) !=
        expectedJournalDigest) {
      throw const _RecoveryConflict();
    }
    final matches = existing
        .where(
          (record) =>
              record.filename == filename &&
              record.originalHash == originalHash &&
              (sourceKey == null
                  ? record.sourceKey == null
                  : record.sourceKey == sourceKey ||
                        record.recoveredByKey == sourceKey ||
                        record.sourceKey == null),
        )
        .toList();
    if (matches.length != 1) {
      throw StateError('No unique matching quarantine record to recover');
    }
    if (!await verifyBackup(matches.single)) {
      throw const FormatException('Cannot recover corrupt quarantine evidence');
    }
    final index = existing.indexOf(matches.single);
    if (matches.single.recovered) return;
    existing[index] = matches.single.copyWith(
      recovered: true,
      recoveredByKey: sourceKey != null && matches.single.sourceKey == null
          ? sourceKey
          : null,
    );
    await _atomicWriteJournal(
      existing,
      expectedJournalDigest: expectedJournalDigest,
      beforeCommit: () {
        beforeCommit?.call();
        if (!verifyBackupSync(matches.single)) {
          throw const _RecoveryConflict();
        }
      },
    );
  }

  /// Preserves exact original bytes before any caller replaces/removes the file.
  /// Quarantine files are immutable and hash-verified; this method never changes
  /// the source file itself.
  Future<SourceQuarantineRecord?> quarantineFile(
    File file, {
    required String reason,
    String? sourceKey,
    String? expectedDigest,
    bool recovered = false,
    void Function()? beforeCommit,
  }) async {
    final canonicalSource = p.canonicalize(sourceDir.path);
    final canonicalFile = p.canonicalize(file.path);
    if (p.dirname(canonicalFile) != canonicalSource) {
      throw const FormatException(
        'Quarantine source is outside source directory',
      );
    }
    if (sourceKey != null) SourceFileMetadata.validateKey(sourceKey);
    if (!await file.exists()) return null;
    await _ensureDirs(beforeCommit);

    final statBefore = await file.stat();
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    if (expectedDigest != null && expectedDigest != hash) return null;
    final safeName = p
        .basename(file.path)
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final backupFile = File(p.join(recordsDir.path, '${hash}_$safeName'));

    var verifiedBackupExists = false;
    if (await backupFile.exists()) {
      final existingBytes = await backupFile.readAsBytes();
      if (existingBytes.length != bytes.length ||
          sha256.convert(existingBytes).toString() != hash) {
        throw StateError('Immutable quarantine evidence path is occupied');
      }
      verifiedBackupExists = true;
    }

    File? stageFile;
    if (!verifiedBackupExists) {
      stageFile = File(
        p.join(
          recordsDir.path,
          '.tmp_${hash}_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        beforeCommit?.call();
        await stageFile.writeAsBytes(bytes, flush: true);
        if (sha256.convert(await stageFile.readAsBytes()).toString() != hash) {
          throw const FileSystemException('Quarantine backup staging failed');
        }
        if (await _currentMatches(file, hash, statBefore)) {
          await SourceFileMetadata.atomicReplace(
            stageFile,
            backupFile,
            beforeCommit: () {
              beforeCommit?.call();
              if (backupFile.existsSync() ||
                  !_currentMatchesSync(file, hash, statBefore)) {
                throw const _RecoveryConflict();
              }
            },
          );
        } else {
          return null;
        }
      } finally {
        await stageFile.deleteIgnoreError();
      }
    }

    final preservedBytes = await backupFile.readAsBytes();
    if (preservedBytes.length != bytes.length ||
        sha256.convert(preservedBytes).toString() != hash) {
      throw StateError('Immutable quarantine evidence failed verification');
    }
    if (!await _currentMatches(file, hash, statBefore)) return null;

    final filename = p.basename(file.path);
    final expectedJournalDigest = await SourceRecovery._digestFile(journalFile);
    final existing = await readJournal();
    if (await SourceRecovery._digestFile(journalFile) !=
            expectedJournalDigest ||
        !_currentMatchesSync(file, hash, statBefore)) {
      throw const _RecoveryConflict();
    }
    final prior = existing.where(
      (record) =>
          record.filename == filename &&
          record.originalPath == canonicalFile &&
          record.originalHash == hash &&
          record.sourceKey == sourceKey,
    );
    if (prior.isNotEmpty) return prior.first;

    final record = SourceQuarantineRecord(
      originalPath: canonicalFile,
      filename: filename,
      originalHash: hash,
      backupPath: p.canonicalize(backupFile.path),
      reason: reason,
      timestamp: DateTime.now().toUtc(),
      fileSize: bytes.length,
      sourceKey: sourceKey,
      recovered: recovered,
    );

    if (!await _currentMatches(file, hash, statBefore)) return null;
    existing.add(record);
    await _atomicWriteJournal(
      existing,
      expectedJournalDigest: expectedJournalDigest,
      beforeCommit: () {
        beforeCommit?.call();
        if (!_currentMatchesSync(file, hash, statBefore)) {
          throw const _RecoveryConflict();
        }
      },
    );
    return record;
  }

  static Future<bool> _currentMatches(
    File file,
    String expectedDigest,
    FileStat expectedStat,
  ) async {
    if (!await file.exists()) return false;
    final currentBytes = await file.readAsBytes();
    final stat = await file.stat();
    return sha256.convert(currentBytes).toString() == expectedDigest &&
        stat.size == expectedStat.size &&
        stat.modified == expectedStat.modified;
  }

  static bool _currentMatchesSync(
    File file,
    String expectedDigest,
    FileStat expectedStat,
  ) {
    if (!file.existsSync()) return false;
    final currentBytes = file.readAsBytesSync();
    final stat = file.statSync();
    return sha256.convert(currentBytes).toString() == expectedDigest &&
        stat.size == expectedStat.size &&
        stat.modified == expectedStat.modified;
  }

  static String? _digestFileSync(File file) {
    if (!file.existsSync()) return null;
    return sha256.convert(file.readAsBytesSync()).toString();
  }
}

class ProblematicSourceFile {
  final File file;
  final String filename;
  final String content;
  final List<int> bytes;
  final String initialDigest;
  final String failureName;
  final bool isCorruptOrEmpty;
  final FileStat initialStat;

  ProblematicSourceFile({
    required this.file,
    required this.filename,
    required this.content,
    required this.bytes,
    required this.initialDigest,
    required this.failureName,
    required this.isCorruptOrEmpty,
    required this.initialStat,
  });
}

class _PlannedSourceRepair {
  final ProblematicSourceFile? pf;
  final SourceQuarantineRecord? existingQRecord;
  final String key;
  final String filename;
  final String canonicalName;
  final String replacementContent;
  final String logicalFilename;
  final String expectedDigest;
  final String reason;
  final String? existingBackupPath;

  _PlannedSourceRepair({
    this.pf,
    this.existingQRecord,
    this.existingBackupPath,
    required this.key,
    required this.filename,
    required this.canonicalName,
    required this.replacementContent,
    required this.logicalFilename,
    required this.expectedDigest,
    required this.reason,
  });

  Map<String, Object?> toJson() => {
    'key': key,
    'filename': filename,
    'canonicalName': canonicalName,
    'expectedDigest': expectedDigest,
    'replacementContent': replacementContent,
    'logicalFilename': logicalFilename,
    'reason': reason,
    if (existingQRecord != null || existingBackupPath != null)
      'existingBackupPath': existingQRecord?.backupPath ?? existingBackupPath,
  };

  factory _PlannedSourceRepair.fromJson(
    Map<String, Object?> json,
    Directory sourceDir,
  ) {
    final key = json['key'];
    final filename = json['filename'];
    final canonicalName = json['canonicalName'];
    final expectedDigest = json['expectedDigest'];
    final replacementContent = json['replacementContent'];
    final logicalFilename = json['logicalFilename'];
    final reason = json['reason'];
    final backupPath = json['existingBackupPath'];
    if (key is! String ||
        filename is! String ||
        canonicalName is! String ||
        expectedDigest is! String ||
        replacementContent is! String ||
        logicalFilename is! String ||
        reason is! String ||
        (backupPath != null && backupPath is! String)) {
      throw const FormatException('Invalid recovery journal entry fields');
    }
    SourceFileMetadata.validateKey(key);
    SourceFileMetadata.validateFileName(filename);
    SourceFileMetadata.validateFileName(canonicalName);
    SourceFileMetadata.validateFileName(logicalFilename);
    if (!filename.endsWith('.js') ||
        canonicalName != SourceFileMetadata.physicalName(key) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedDigest) ||
        replacementContent.isEmpty ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(reason)) {
      throw const FormatException('Invalid recovery journal entry');
    }
    if (backupPath is String) {
      final canonicalBackup = p.canonicalize(backupPath);
      final recordsDir = p.canonicalize(
        p.join(sourceDir.path, '.quarantine', 'records'),
      );
      if (p.dirname(canonicalBackup) != recordsDir) {
        throw const FormatException(
          'Recovery backup path is outside quarantine',
        );
      }
    }
    return _PlannedSourceRepair(
      key: key,
      filename: filename,
      canonicalName: canonicalName,
      expectedDigest: expectedDigest,
      replacementContent: replacementContent,
      logicalFilename: logicalFilename,
      reason: reason,
      existingBackupPath: backupPath as String?,
    );
  }
}

class _ValidSourceCandidate {
  final File file;
  final String filename;
  final String key;
  final String content;
  final String digest;

  const _ValidSourceCandidate({
    required this.file,
    required this.filename,
    required this.key,
    required this.content,
    required this.digest,
  });
}

class _RecoveryConflict implements Exception {
  const _RecoveryConflict();
}

/// Helper for evidence-based source scanning, quarantine, and repair.
class SourceRecovery {
  static File _recoveryJournalFile(Directory sourceDir) =>
      File(p.join(sourceDir.path, '.recovery_journal.json'));

  /// Creates and replays a hash-bound repair for one selected, currently
  /// present source file. The journal survives all incomplete finishes.
  static Future<List<SyncSourceIssue>> repairCurrentSource(
    Directory sourceDir, {
    required String filename,
    required String expectedDigest,
    required String key,
    required String replacementContent,
    String reason = 'manualRepair',
    void Function()? beforeCommit,
    bool requireRuntimeFinish = false,
    Future<bool> Function()? finishRuntime,
  }) async {
    SourceFileMetadata.validateFileName(filename);
    SourceFileMetadata.validateKey(key);
    if (!filename.endsWith('.js') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedDigest) ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(reason)) {
      throw const FormatException('Invalid selected source repair identity');
    }
    final probe = await ComicSourceParser.probeKey(
      replacementContent,
      filename,
    );
    if (!probe.isSuccess || probe.key != key) {
      throw const FormatException('Selected replacement source key mismatch');
    }
    final currentFile = File(p.join(sourceDir.path, filename));
    if (_digestFileSync(currentFile) != expectedDigest) {
      throw const _RecoveryConflict();
    }
    final currentStat = currentFile.statSync();
    await SourceFileMetadata.read(sourceDir);
    final metadataFile = File(
      p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
    );
    final metadataDigest = await _digestFile(metadataFile);
    final quarantineManager = SourceQuarantineManager(sourceDir);
    final qRecords = await quarantineManager.readJournal();
    final quarantineDigest = await _digestFile(quarantineManager.journalFile);
    if (_digestFileSync(currentFile) != expectedDigest ||
        await _digestFile(metadataFile) != metadataDigest ||
        await _digestFile(quarantineManager.journalFile) != quarantineDigest) {
      throw const _RecoveryConflict();
    }
    final existing = _matchingQuarantineRecord(
      qRecords,
      filename,
      expectedDigest,
      key,
    );
    if (existing != null && !await quarantineManager.verifyBackup(existing)) {
      throw const FormatException('Selected source backup is corrupt');
    }
    final plan = _PlannedSourceRepair(
      existingQRecord: existing,
      existingBackupPath: existing?.backupPath,
      key: key,
      filename: filename,
      canonicalName: SourceFileMetadata.physicalName(key),
      expectedDigest: expectedDigest,
      replacementContent: replacementContent,
      logicalFilename: filename,
      reason: reason,
    );
    await _writeRecoveryJournal(
      sourceDir,
      [plan],
      beforeCommit: () {
        beforeCommit?.call();
        if (_digestFileSync(currentFile) != expectedDigest ||
            currentFile.statSync().size != currentStat.size ||
            currentFile.statSync().modified != currentStat.modified ||
            _digestFileSync(metadataFile) != metadataDigest ||
            _digestFileSync(quarantineManager.journalFile) !=
                quarantineDigest) {
          throw const _RecoveryConflict();
        }
      },
    );
    return replayPendingRecovery(
      sourceDir,
      beforeCommit: beforeCommit,
      requireRuntimeFinish: requireRuntimeFinish,
      finishRuntime: finishRuntime,
    );
  }

  static Future<({List<_PlannedSourceRepair> entries, String digest})?>
  _readRecoveryJournal(Directory sourceDir) async {
    final journal = _recoveryJournalFile(sourceDir);
    if (!await journal.exists()) return null;
    final bytes = await journal.readAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('Empty source recovery journal');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map ||
        decoded['status'] != 'planned' ||
        decoded['entries'] is! List ||
        decoded['timestamp'] is! String ||
        DateTime.tryParse(decoded['timestamp'] as String) == null) {
      throw const FormatException('Invalid source recovery journal');
    }

    final entries = <_PlannedSourceRepair>[];
    final identities = <String>{};
    for (final rawEntry in decoded['entries'] as List) {
      if (rawEntry is! Map) {
        throw const FormatException('Invalid source recovery journal entry');
      }
      final entry = _PlannedSourceRepair.fromJson(
        Map<String, Object?>.from(rawEntry),
        sourceDir,
      );
      final identity =
          '${entry.filename}\u0000${entry.expectedDigest}\u0000${entry.key}';
      if (!identities.add(identity)) {
        throw const FormatException('Duplicate source recovery journal action');
      }
      entries.add(entry);
    }
    if (entries.isEmpty) {
      throw const FormatException('Source recovery journal has no actions');
    }
    return (entries: entries, digest: sha256.convert(bytes).toString());
  }

  static Future<void> _writeRecoveryJournal(
    Directory sourceDir,
    List<_PlannedSourceRepair> entries, {
    void Function()? beforeCommit,
  }) async {
    final journal = _recoveryJournalFile(sourceDir);
    if (await journal.exists()) throw const _RecoveryConflict();
    final raw = utf8.encode(
      jsonEncode({
        'status': 'planned',
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    final stage = File(
      p.join(
        sourceDir.path,
        '.recovery_journal_${DateTime.now().microsecondsSinceEpoch}.stage',
      ),
    );
    try {
      beforeCommit?.call();
      await stage.writeAsBytes(raw, flush: true);
      if (sha256.convert(await stage.readAsBytes()).toString() !=
          sha256.convert(raw).toString()) {
        throw const FileSystemException('Recovery journal staging failed');
      }
      await SourceFileMetadata.atomicReplace(
        stage,
        journal,
        beforeCommit: () {
          beforeCommit?.call();
          if (journal.existsSync()) throw const _RecoveryConflict();
        },
      );
    } finally {
      await stage.deleteIgnoreError();
    }
  }

  static Future<String?> _digestFile(File file) async {
    if (!await file.exists()) return null;
    return sha256.convert(await file.readAsBytes()).toString();
  }

  static String? _digestFileSync(File file) {
    if (!file.existsSync()) return null;
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  static Future<SourceQuarantineRecord?> _findQuarantineRecord(
    SourceQuarantineManager manager,
    List<SourceQuarantineRecord> records,
    _PlannedSourceRepair entry,
  ) async {
    final matches = records
        .where(
          (record) =>
              record.filename == entry.filename &&
              record.originalHash == entry.expectedDigest &&
              (record.sourceKey == entry.key ||
                  record.recoveredByKey == entry.key ||
                  record.sourceKey == null),
        )
        .toList();
    if (matches.length > 1) {
      throw const FormatException('Ambiguous source quarantine records');
    }
    if (matches.isEmpty) return null;
    final record = matches.single;
    if (record.sourceKey != null && record.sourceKey != entry.key) {
      throw const FormatException('Quarantine source identity mismatch');
    }
    if (record.recoveredByKey != null && record.recoveredByKey != entry.key) {
      throw const FormatException('Quarantine recovered identity mismatch');
    }
    if (entry.existingBackupPath != null &&
        p.canonicalize(entry.existingBackupPath!) !=
            p.canonicalize(record.backupPath)) {
      throw const FormatException(
        'Recovery journal backup does not match quarantine evidence',
      );
    }
    if (!await manager.verifyBackup(record)) return null;
    return record;
  }

  /// Replays a strictly validated repair plan idempotently. Its journal and
  /// quarantine records remain until all file, metadata, and required runtime
  /// actions have been proved complete.
  static Future<List<SyncSourceIssue>> replayPendingRecovery(
    Directory sourceDir, {
    void Function()? beforeCommit,
    bool requireRuntimeFinish = false,
    Future<bool> Function()? finishRuntime,
  }) async {
    final loaded = await _readRecoveryJournal(sourceDir);
    if (loaded == null) return [];
    final journal = _recoveryJournalFile(sourceDir);
    final quarantineManager = SourceQuarantineManager(sourceDir);
    var qRecords = await quarantineManager.readJournal();
    final issues = <SyncSourceIssue>[];
    final completed = <(_PlannedSourceRepair, SourceQuarantineRecord)>[];

    for (final entry in loaded.entries) {
      try {
        final probe = await ComicSourceParser.probeKey(
          entry.replacementContent,
        );
        if (!probe.isSuccess || probe.key != entry.key) {
          throw const FormatException(
            'Recovery journal replacement identity mismatch',
          );
        }

        final oldFile = File(p.join(sourceDir.path, entry.filename));
        var quarantineRecord = await _findQuarantineRecord(
          quarantineManager,
          qRecords,
          entry,
        );
        if (quarantineRecord == null &&
            await oldFile.exists() &&
            await _digestFile(oldFile) == entry.expectedDigest) {
          final newlyQuarantined = await quarantineManager.quarantineFile(
            oldFile,
            reason: entry.reason,
            sourceKey: entry.key,
            expectedDigest: entry.expectedDigest,
            beforeCommit: beforeCommit,
          );
          if (newlyQuarantined != null) {
            quarantineRecord = newlyQuarantined;
            qRecords = await quarantineManager.readJournal();
          }
        }
        if (quarantineRecord == null ||
            !await quarantineManager.verifyBackup(quarantineRecord)) {
          throw const _RecoveryConflict();
        }

        final canonicalFile = File(p.join(sourceDir.path, entry.canonicalName));
        final replacementDigest = SourceFileMetadata.digest(
          entry.replacementContent,
        );
        final targetDigest = await _digestFile(canonicalFile);
        var published = targetDigest == replacementDigest;
        if (!published) {
          if (targetDigest != null &&
              !(entry.filename == entry.canonicalName &&
                  targetDigest == entry.expectedDigest)) {
            throw const _RecoveryConflict();
          }

          final stagedFile = File(
            p.join(
              sourceDir.path,
              '.${entry.canonicalName}.recovery_stage_'
              '${DateTime.now().microsecondsSinceEpoch}',
            ),
          );
          beforeCommit?.call();
          try {
            await stagedFile.writeAsString(
              entry.replacementContent,
              flush: true,
            );
            if (await _digestFile(stagedFile) != replacementDigest) {
              throw const FileSystemException(
                'Staged source replacement failed verification',
              );
            }
            final stagedProbe = await ComicSourceParser.probeKey(
              await stagedFile.readAsString(),
              stagedFile.path,
            );
            if (!stagedProbe.isSuccess || stagedProbe.key != entry.key) {
              throw const FormatException('Staged source identity mismatch');
            }
            if (await _digestFile(canonicalFile) != targetDigest) {
              throw const _RecoveryConflict();
            }
            await SourceFileMetadata.atomicReplace(
              stagedFile,
              canonicalFile,
              beforeCommit: () {
                beforeCommit?.call();
                if (_digestFileSync(canonicalFile) != targetDigest) {
                  throw const _RecoveryConflict();
                }
              },
            );
            published = true;
          } finally {
            await stagedFile.deleteIgnoreError();
          }
        }
        if (!published ||
            await _digestFile(canonicalFile) != replacementDigest) {
          throw const _RecoveryConflict();
        }

        try {
          await SourceFileMetadata.recordValidated(
            sourceDir,
            key: entry.key,
            filename: entry.canonicalName,
            originFilename: entry.logicalFilename,
            content: entry.replacementContent,
            beforeCommit: beforeCommit,
          );
        } on FormatException {
          issues.add(
            SyncSourceIssue(
              filename: SourceFileMetadata.sidecarFileName,
              reason: 'metadataCorrupted',
              contentDigest: await _digestFile(
                File(
                  p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
                ),
              ),
            ),
          );
          continue;
        }

        if (oldFile.path != canonicalFile.path && await oldFile.exists()) {
          final oldDigest = await _digestFile(oldFile);
          if (oldDigest == entry.expectedDigest) {
            if (!await quarantineManager.verifyBackup(quarantineRecord)) {
              throw const _RecoveryConflict();
            }
            beforeCommit?.call();
            if (_digestFileSync(oldFile) != entry.expectedDigest) {
              throw const _RecoveryConflict();
            }
            oldFile.deleteSync();
          } else if (entry.existingQRecord == null &&
              entry.existingBackupPath == null) {
            throw const _RecoveryConflict();
          }
        }
        completed.add((entry, quarantineRecord));
      } on _RecoveryConflict {
        issues.add(
          SyncSourceIssue(
            filename: entry.filename,
            reason: 'concurrentModification',
            contentDigest: entry.expectedDigest,
            sourceKey: entry.key,
            backupPath: entry.existingBackupPath,
          ),
        );
      } on FileSystemException {
        issues.add(
          SyncSourceIssue(
            filename: entry.filename,
            reason: 'writeFailure',
            contentDigest: entry.expectedDigest,
            sourceKey: entry.key,
            backupPath: entry.existingBackupPath,
          ),
        );
      }
    }

    if (completed.length != loaded.entries.length) return issues;

    if (requireRuntimeFinish || finishRuntime != null) {
      var runtimeFinished = false;
      var runtimeFailed = false;
      if (finishRuntime != null) {
        try {
          runtimeFinished = await finishRuntime();
        } catch (_) {
          runtimeFailed = true;
        }
      }
      if (!runtimeFinished) {
        for (final (entry, record) in completed) {
          issues.add(
            SyncSourceIssue(
              filename: entry.filename,
              reason: runtimeFailed
                  ? 'runtimeReloadFailed'
                  : 'runtimeReloadDeferred',
              contentDigest: entry.expectedDigest,
              sourceKey: entry.key,
              backupPath: record.backupPath,
            ),
          );
        }
        return issues;
      }
    }

    final metadataFile = File(
      p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
    );
    final metadataDigest = await _digestFile(metadataFile);
    final metadata = await SourceFileMetadata.read(sourceDir);
    for (final (entry, record) in completed) {
      final replacementDigest = SourceFileMetadata.digest(
        entry.replacementContent,
      );
      final canonicalFile = File(p.join(sourceDir.path, entry.canonicalName));
      final sourceMetadata = metadata[entry.key];
      final files = sourceMetadata?['files'];
      final revisions = sourceMetadata?['revisions'];
      if (_digestFileSync(canonicalFile) != replacementDigest ||
          files is! Map ||
          files[entry.canonicalName] != replacementDigest ||
          revisions is! Map ||
          revisions[replacementDigest] != entry.logicalFilename) {
        throw const _RecoveryConflict();
      }
      await quarantineManager.markRecovered(
        record.filename,
        originalHash: record.originalHash,
        sourceKey: entry.key,
        beforeCommit: () {
          beforeCommit?.call();
          if (_digestFileSync(canonicalFile) != replacementDigest ||
              _digestFileSync(metadataFile) != metadataDigest) {
            throw const _RecoveryConflict();
          }
        },
      );
      issues.add(
        SyncSourceIssue(
          filename: entry.filename,
          reason: entry.reason,
          contentDigest: entry.expectedDigest,
          sourceKey: entry.key,
          backupPath: record.backupPath,
          recovered: true,
        ),
      );
    }

    if (_digestFileSync(journal) != loaded.digest) {
      throw const _RecoveryConflict();
    }
    beforeCommit?.call();
    if (_digestFileSync(journal) != loaded.digest ||
        _digestFileSync(metadataFile) != metadataDigest ||
        completed.any(
          (action) =>
              _digestFileSync(
                File(p.join(sourceDir.path, action.$1.canonicalName)),
              ) !=
              SourceFileMetadata.digest(action.$1.replacementContent),
        )) {
      throw const _RecoveryConflict();
    }
    journal.deleteSync();
    return issues;
  }

  /// Attempts evidence-based local recovery for empty or corrupt scripts.
  /// Unknown invalid files are left byte-for-byte in place and remain blockers.
  static Future<List<SyncSourceIssue>> recoverLocalSources(
    Directory sourceDir, {
    SyncRecords recoveryRecords = const {},
    void Function()? beforeCommit,
    bool isLiveDirectory = false,
    Future<bool> Function()? finishRuntime,
  }) async {
    if (!await sourceDir.exists()) return [];

    final issues = <SyncSourceIssue>[];
    final quarantineManager = SourceQuarantineManager(sourceDir);
    var canMutate = true;
    List<SourceQuarantineRecord> quarantineRecords = [];
    try {
      quarantineRecords = await quarantineManager.readJournal();
    } on FormatException {
      canMutate = false;
      final journal = quarantineManager.journalFile;
      issues.add(
        SyncSourceIssue(
          filename: '.quarantine/journal.json',
          reason: 'journalCorrupted',
          contentDigest: await _digestFile(journal),
          backupPath: await quarantineManager.journalBakFile.exists()
              ? quarantineManager.journalBakFile.path
              : await journal.exists()
              ? journal.path
              : null,
        ),
      );
    }

    var hasPendingRecovery = false;
    try {
      issues.addAll(
        await replayPendingRecovery(
          sourceDir,
          beforeCommit: beforeCommit,
          requireRuntimeFinish: isLiveDirectory,
          finishRuntime: finishRuntime,
        ),
      );
      hasPendingRecovery = await _recoveryJournalFile(sourceDir).exists();
      if (hasPendingRecovery) canMutate = false;
    } on FormatException {
      canMutate = false;
      final journal = _recoveryJournalFile(sourceDir);
      issues.add(
        SyncSourceIssue(
          filename: p.basename(journal.path),
          reason: 'journalCorrupted',
          contentDigest: await _digestFile(journal),
          backupPath: await journal.exists() ? journal.path : null,
        ),
      );
    }

    try {
      quarantineRecords = await quarantineManager.readJournal();
    } on FormatException {
      canMutate = false;
    }

    Map<String, Map<String, Object?>> metadata = {};
    var metadataReadable = true;
    try {
      metadata = await SourceFileMetadata.read(sourceDir);
    } on FormatException {
      metadataReadable = false;
      canMutate = false;
      final metadataFile = File(
        p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
      );
      final backupFile = File('${metadataFile.path}.bak');
      issues.add(
        SyncSourceIssue(
          filename: SourceFileMetadata.sidecarFileName,
          reason: 'metadataCorrupted',
          contentDigest: await _digestFile(metadataFile),
          backupPath: await backupFile.exists() ? backupFile.path : null,
        ),
      );
    }

    final validByKey = <String, List<_ValidSourceCandidate>>{};
    final problems = <ProblematicSourceFile>[];
    await for (final entity in sourceDir.list()) {
      if (entity is! File) continue;
      final filename = p.basename(entity.path);
      if (filename.startsWith('.') || !filename.endsWith('.js')) continue;

      final stat = await entity.stat();
      List<int> bytes;
      try {
        bytes = await entity.readAsBytes();
      } on FileSystemException {
        issues.add(
          SyncSourceIssue(
            filename: filename,
            reason: 'readFailure',
            sourceKey: _resolveKey(
              filename,
              null,
              metadata,
              recoveryRecords,
              quarantineRecords,
            ),
          ),
        );
        continue;
      }
      final digest = sha256.convert(bytes).toString();
      String content;
      try {
        content = utf8.decode(bytes);
      } on FormatException {
        problems.add(
          ProblematicSourceFile(
            file: entity,
            filename: filename,
            content: '',
            bytes: bytes,
            initialDigest: digest,
            failureName: 'readFailure',
            isCorruptOrEmpty: true,
            initialStat: stat,
          ),
        );
        continue;
      }

      final probe = await ComicSourceParser.probeKey(content, entity.path);
      if (probe.isSuccess && probe.key != null) {
        try {
          SourceFileMetadata.validateKey(probe.key!);
          validByKey
              .putIfAbsent(probe.key!, () => [])
              .add(
                _ValidSourceCandidate(
                  file: entity,
                  filename: filename,
                  key: probe.key!,
                  content: content,
                  digest: digest,
                ),
              );
          continue;
        } on FormatException {
          // Do not infer or normalize a source with an invalid identity.
        }
      }

      final failureName = probe.failure?.name ?? 'evaluationError';
      final runtimeLimited = const {
        'unsupportedHostApi',
        'timeout',
        'memoryLimit',
        'runtimeFailure',
        'evaluationError',
      }.contains(failureName);
      problems.add(
        ProblematicSourceFile(
          file: entity,
          filename: filename,
          content: content,
          bytes: bytes,
          initialDigest: digest,
          failureName: failureName,
          isCorruptOrEmpty: !runtimeLimited,
          initialStat: stat,
        ),
      );
    }

    final plans = <_PlannedSourceRepair>[];
    final planIdentities = <String>{};
    void addPlan(_PlannedSourceRepair plan) {
      final identity =
          '${plan.filename}\u0000${plan.expectedDigest}\u0000${plan.key}';
      if (planIdentities.add(identity)) plans.add(plan);
    }

    for (final problem in problems) {
      final key = _resolveKey(
        problem.filename,
        problem.initialDigest,
        metadata,
        recoveryRecords,
        quarantineRecords,
      );
      if (!problem.isCorruptOrEmpty) {
        issues.add(
          SyncSourceIssue(
            filename: problem.filename,
            reason: problem.failureName,
            contentDigest: problem.initialDigest,
            sourceKey: key,
          ),
        );
        continue;
      }
      if (key == null) {
        issues.add(
          SyncSourceIssue(
            filename: problem.filename,
            reason: problem.failureName,
            contentDigest: problem.initialDigest,
          ),
        );
        continue;
      }

      final localCandidates = validByKey[key] ?? const [];
      String? replacement;
      String? logicalName;
      if (localCandidates.isNotEmpty) {
        final candidates = List<_ValidSourceCandidate>.from(localCandidates)
          ..sort((a, b) {
            final canonicalName = SourceFileMetadata.physicalName(key);
            if (a.filename == canonicalName && b.filename != canonicalName) {
              return -1;
            }
            if (b.filename == canonicalName && a.filename != canonicalName) {
              return 1;
            }
            return a.filename.compareTo(b.filename);
          });
        final candidate = candidates.first;
        replacement = candidate.content;
        logicalName = _logicalName(key, candidate, metadata);
      } else {
        final approved = await _approvedScript(recoveryRecords, key);
        replacement = approved?.content;
        logicalName = approved?.filename ?? problem.filename;
      }
      if (replacement == null ||
          replacement.isEmpty ||
          !metadataReadable ||
          !canMutate) {
        issues.add(
          SyncSourceIssue(
            filename: problem.filename,
            reason: problem.failureName,
            contentDigest: problem.initialDigest,
            sourceKey: key,
          ),
        );
        continue;
      }
      final existing = _matchingQuarantineRecord(
        quarantineRecords,
        problem.filename,
        problem.initialDigest,
        key,
      );
      addPlan(
        _PlannedSourceRepair(
          pf: problem,
          existingQRecord: existing,
          existingBackupPath: existing?.backupPath,
          key: key,
          filename: problem.filename,
          canonicalName: SourceFileMetadata.physicalName(key),
          replacementContent: replacement,
          logicalFilename: logicalName,
          expectedDigest: problem.initialDigest,
          reason: problem.failureName,
        ),
      );
    }

    for (final record in quarantineRecords) {
      if (record.recovered) {
        issues.add(
          SyncSourceIssue(
            filename: record.filename,
            reason: record.reason,
            contentDigest: record.originalHash,
            sourceKey: record.recoveredByKey ?? record.sourceKey,
            backupPath: record.backupPath,
            recovered: true,
          ),
        );
        continue;
      }
      final sameNameCandidates = validByKey.values
          .expand((candidates) => candidates)
          .where((candidate) => candidate.filename == record.filename)
          .toList();
      final installedKey = sameNameCandidates.length == 1
          ? sameNameCandidates.single.key
          : null;
      final key =
          record.sourceKey ??
          record.recoveredByKey ??
          installedKey ??
          _resolveKey(
            record.filename,
            record.originalHash,
            metadata,
            recoveryRecords,
            quarantineRecords,
          );
      if (key == null) {
        issues.add(
          SyncSourceIssue(
            filename: record.filename,
            reason: record.reason,
            contentDigest: record.originalHash,
            backupPath: record.backupPath,
          ),
        );
        continue;
      }
      if (plans.any(
        (plan) =>
            plan.filename == record.filename &&
            plan.expectedDigest == record.originalHash &&
            plan.key == key,
      )) {
        continue;
      }
      if (!canMutate || !await quarantineManager.verifyBackup(record)) {
        issues.add(
          SyncSourceIssue(
            filename: record.filename,
            reason: 'backupCorrupted',
            contentDigest: record.originalHash,
            sourceKey: key,
            backupPath: record.backupPath,
          ),
        );
        continue;
      }

      String? replacement;
      String? logicalName;
      final candidates = validByKey[key] ?? const [];
      if (candidates.isNotEmpty) {
        final candidate = candidates.first;
        replacement = candidate.content;
        logicalName = _logicalName(key, candidate, metadata);
      } else {
        final approved = await _approvedScript(recoveryRecords, key);
        replacement = approved?.content;
        logicalName = approved?.filename ?? record.filename;
      }
      if (replacement == null || replacement.isEmpty) {
        issues.add(
          SyncSourceIssue(
            filename: record.filename,
            reason: record.reason,
            contentDigest: record.originalHash,
            sourceKey: key,
            backupPath: record.backupPath,
          ),
        );
        continue;
      }
      addPlan(
        _PlannedSourceRepair(
          existingQRecord: record,
          existingBackupPath: record.backupPath,
          key: key,
          filename: record.filename,
          canonicalName: SourceFileMetadata.physicalName(key),
          replacementContent: replacement,
          logicalFilename: logicalName,
          expectedDigest: record.originalHash,
          reason: record.reason,
        ),
      );
    }

    if (plans.isNotEmpty && canMutate && !hasPendingRecovery) {
      try {
        await _writeRecoveryJournal(
          sourceDir,
          plans,
          beforeCommit: beforeCommit,
        );
        issues.addAll(
          await replayPendingRecovery(
            sourceDir,
            beforeCommit: beforeCommit,
            requireRuntimeFinish: isLiveDirectory,
            finishRuntime: finishRuntime,
          ),
        );
      } on _RecoveryConflict {
        issues.add(
          const SyncSourceIssue(
            filename: '.recovery_journal.json',
            reason: 'concurrentModification',
          ),
        );
      } on FileSystemException {
        issues.add(
          const SyncSourceIssue(
            filename: '.recovery_journal.json',
            reason: 'writeFailure',
          ),
        );
      }
    }

    final currentQRecords = await _safeReadQuarantineJournal(quarantineManager);
    for (final record in currentQRecords) {
      if (record.recovered) continue;
      if (issues.any(
        (issue) =>
            issue.filename == record.filename &&
            issue.contentDigest == record.originalHash &&
            issue.sourceKey == (record.recoveredByKey ?? record.sourceKey),
      )) {
        continue;
      }
      issues.add(
        SyncSourceIssue(
          filename: record.filename,
          reason: record.reason,
          contentDigest: record.originalHash,
          sourceKey: record.recoveredByKey ?? record.sourceKey,
          backupPath: record.backupPath,
        ),
      );
    }

    return issues.toSet().toList();
  }

  static Future<List<SourceQuarantineRecord>> _safeReadQuarantineJournal(
    SourceQuarantineManager manager,
  ) async {
    try {
      return await manager.readJournal();
    } on FormatException {
      return [];
    }
  }

  static SourceQuarantineRecord? _matchingQuarantineRecord(
    List<SourceQuarantineRecord> records,
    String filename,
    String digest,
    String key,
  ) {
    final matches = records.where(
      (record) =>
          record.filename == filename &&
          record.originalHash == digest &&
          (record.sourceKey == key ||
              record.recoveredByKey == key ||
              record.sourceKey == null),
    );
    return matches.length == 1 ? matches.single : null;
  }

  static String? _resolveKey(
    String filename,
    String? contentDigest,
    Map<String, Map<String, Object?>> metadata,
    SyncRecords recoveryRecords,
    List<SourceQuarantineRecord> quarantineRecords,
  ) {
    final matches = <String>{};
    final possibleKeys = <String>{
      ...metadata.keys,
      for (final recordKey in recoveryRecords.keys)
        if (syncRecordDomain(recordKey) == 'source')
          ..._sourceKeyIdentity(recordKey),
    };
    for (final key in possibleKeys) {
      if (!SourceFileMetadata.isValidKey(key)) continue;
      if (SourceFileMetadata.physicalName(key) == filename) matches.add(key);
      final entry = metadata[key];
      if (entry != null) {
        final files = entry['files'];
        final aliases = entry['aliases'];
        final revisions = entry['revisions'];
        if ((files is Map && files.containsKey(filename)) ||
            (aliases is List && aliases.contains(filename)) ||
            entry['filename'] == filename ||
            (revisions is Map && revisions.values.contains(filename))) {
          matches.add(key);
        }
      }
      final script = recoveryRecords[syncRecordKey('source', [key])]?['script'];
      if (script is Map && script['filename'] == filename) matches.add(key);
    }
    for (final record in quarantineRecords) {
      if (record.filename == filename &&
          (contentDigest == null || record.originalHash == contentDigest)) {
        final key = record.recoveredByKey ?? record.sourceKey;
        if (key != null) matches.add(key);
      }
    }
    return matches.length == 1 ? matches.single : null;
  }

  static List<String> _sourceKeyIdentity(String recordKey) {
    final identity = syncRecordIdentity(recordKey);
    if (identity.length == 1 && identity.single is String) {
      return [identity.single as String];
    }
    return const [];
  }

  static String _logicalName(
    String key,
    _ValidSourceCandidate candidate,
    Map<String, Map<String, Object?>> metadata,
  ) {
    final entry = metadata[key];
    final revisions = entry?['revisions'];
    final logical = revisions is Map ? revisions[candidate.digest] : null;
    if (logical is String) return logical;
    return entry?['filename'] as String? ?? candidate.filename;
  }

  static Future<({String filename, String content})?> _approvedScript(
    SyncRecords recoveryRecords,
    String key,
  ) async {
    final script = recoveryRecords[syncRecordKey('source', [key])]?['script'];
    if (script is! Map || script['content'] is! String) return null;
    final content = script['content'] as String;
    final filename = script['filename'] as String? ?? '$key.js';
    try {
      SourceFileMetadata.validateFileName(filename);
    } on FormatException {
      return null;
    }
    if (!filename.endsWith('.js') || content.isEmpty) return null;
    final probe = await ComicSourceParser.probeKey(content);
    if (!probe.isSuccess || probe.key != key) return null;
    return (filename: filename, content: content);
  }
}
