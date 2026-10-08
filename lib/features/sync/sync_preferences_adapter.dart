import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/sync/app_data_transfer.dart';
import 'package:venera_plus/features/sync/source_recovery.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/network/cookie_jar.dart';

/// Exception thrown when a path containment or traversal violation occurs.
class SyncPathSecurityException implements Exception {
  final String message;
  const SyncPathSecurityException(this.message);
  @override
  String toString() => 'SyncPathSecurityException: $message';
}

Future<String?> _digestExistingFile(File file) async {
  if (!await file.exists()) return null;
  return sha256.convert(await file.readAsBytes()).toString();
}

String? _digestExistingFileSync(File file) {
  if (!file.existsSync()) return null;
  return sha256.convert(file.readAsBytesSync()).toString();
}

class _StagedFileMove {
  final File staged;
  final File target;
  final String expectedStagedDigest;
  final String? expectedTargetDigest;

  const _StagedFileMove({
    required this.staged,
    required this.target,
    required this.expectedStagedDigest,
    required this.expectedTargetDigest,
  });
}

class _FileDeletion {
  final File target;
  final String expectedDigest;

  const _FileDeletion({required this.target, required this.expectedDigest});
}

class SourceRepairPendingException implements Exception {
  final String reason;
  final Object? cause;
  final bool fileCommitted;

  const SourceRepairPendingException({
    required this.reason,
    this.cause,
    this.fileCommitted = true,
  });

  @override
  String toString() =>
      'SourceRepairPendingException($reason; fileCommitted=$fileCommitted)';
}

class _ScannedSourceFile {
  final File file;
  final String filename;
  final String content;
  final String contentDigest;
  final String key;

  _ScannedSourceFile({
    required this.file,
    required this.filename,
    required this.content,
    required this.contentDigest,
    required this.key,
  });
}

class _ScannedSession {
  final File file;
  final String key;
  final Map<String, Object?> data;
  final String contentDigest;

  _ScannedSession({
    required this.file,
    required this.key,
    required this.data,
    required this.contentDigest,
  });
}

class _SourceScanResult {
  final SyncRecords records;
  final Map<String, List<Map<String, Object?>>> sourceVariants;
  final bool needsSourceNormalization;
  final Map<String, List<_ScannedSourceFile>> filesByKey;
  final Map<String, _ScannedSession> sessionsByKey;
  final Map<String, Map<String, Object?>> sourceNames;
  final String? sourceNamesDigest;
  final String? sourceNamesBackupDigest;
  final List<SyncSourceIssue> sourceIssues;
  final Set<String> unavailableDomains;

  _SourceScanResult({
    required this.records,
    required this.sourceVariants,
    required this.needsSourceNormalization,
    required this.filesByKey,
    required this.sessionsByKey,
    required this.sourceNames,
    this.sourceNamesDigest,
    this.sourceNamesBackupDigest,
    this.sourceIssues = const [],
    this.unavailableDomains = const {},
  });
}

/// Sync adapter for preferences, search history, cookies, and comic sources.
///
/// Implements lossless record-level export, apply, and legacy migration for
/// domains: `setting`, `search`, `cookies`, `source`, and `sourceSession`.
class SyncPreferencesAdapter {
  SyncPreferencesAdapter({
    Appdata? appdataInstance,
    CookieJarSql? cookieJarInstance,
    String? dataPath,
  }) : _appdata = appdataInstance ?? appdata,
       _cookieJar = cookieJarInstance,
       _customDataPath = dataPath;

  final Appdata _appdata;
  final CookieJarSql? _cookieJar;
  final String? _customDataPath;

  bool _reloadSourcesPending = false;
  final Set<String> _reloadSessionsPending = {};
  List<SyncSourceIssue> _recoveryIssues = const [];

  bool isDomainEnabled(String domain) =>
      isAppDataSyncDomainEnabled(_appdata.implicitData, domain);

  /// Records outside this device's domain or field policy are invisible,
  /// rather than deletions.
  bool shouldObserveRecord(String recordKey) {
    final domain = syncRecordDomain(recordKey);
    if (!isDomainEnabled(domain)) return false;
    if (domain != 'setting') return true;
    final identity = syncRecordIdentity(recordKey);
    return identity.isNotEmpty &&
        identity.first is String &&
        _appdata.isSettingSyncAllowed(identity.first as String);
  }

  SyncRecords projectRecordsForLocalPolicy(SyncRecords records) {
    final ancestors = <String>{};
    for (final key in records.keys) {
      if (syncRecordDomain(key) != 'setting') continue;
      final path = syncRecordIdentity(key);
      for (int length = 1; length < path.length; length++) {
        ancestors.add(syncRecordKey('setting', path.sublist(0, length)));
      }
    }
    return {
      for (final entry in records.entries)
        if (shouldObserveRecord(entry.key) &&
            !(ancestors.contains(entry.key) &&
                entry.value['value'] is Map &&
                (entry.value['value'] as Map).isEmpty))
          entry.key: entry.value,
    };
  }

  String get _dataPath => _customDataPath ?? App.dataPath;

  /// Global callback for runtime notification after settings are imported.
  static FutureOr<void> Function()? onSettingsImported;

  /// Registers a runtime hook called when settings have been applied.
  static void registerSettingsImportedCallback(
    FutureOr<void> Function()? callback,
  ) {
    onSettingsImported = callback;
  }

  /// Triggers runtime reload notification.
  static Future<void> notifySettingsImported() async {
    final custom = onSettingsImported;
    if (custom != null) {
      await Future.sync(custom);
    } else {
      await notifyAppDataSettingsChanged();
    }
  }

  CookieJarSql _resolveCookieJar() {
    if (_cookieJar != null) return _cookieJar;
    final dbPath = p.join(_dataPath, 'cookie.db');
    final shared = SingleInstanceCookieJar.instance;
    if (shared != null && p.equals(shared.path, dbPath)) return shared;
    return CookieJarSql(dbPath);
  }

  void _closeOwnedCookieJar(CookieJarSql jar) {
    if (!identical(jar, _cookieJar) &&
        !identical(jar, SingleInstanceCookieJar.instance)) {
      jar.dispose();
    }
  }

  // ===========================================================================
  // Validation Helpers
  // ===========================================================================

  static void _validateRecordKey(String key) {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(key)) {
      throw FormatException('Invalid comic source identity: $key');
    }
  }

  static void _validateFileName(String filename) {
    if (!filename.endsWith('.js')) {
      throw const FormatException('Source scripts must use a .js filename');
    }
    if (filename.isEmpty ||
        p.basename(filename) != filename ||
        filename.contains('..') ||
        filename.contains('/') ||
        filename.contains(r'\') ||
        filename.contains('\u0000')) {
      throw FormatException(
        'Invalid filename with path traversal characters: $filename',
      );
    }
  }

  static void _assertPathContained(Directory parent, File target) {
    final parentCanon = p.canonicalize(parent.path);
    final targetCanon = p.canonicalize(target.path);
    if (!p.isWithin(parentCanon, targetCanon)) {
      throw SyncPathSecurityException(
        'Target path $targetCanon is outside allowed directory $parentCanon',
      );
    }
  }

  static int _stageSequence = 0;

  File _siblingStage(File target) {
    final sequence = _stageSequence++;
    final name =
        '.sync_${pid}_${DateTime.now().microsecondsSinceEpoch}_$sequence.stage';
    return File(p.join(p.dirname(target.path), name));
  }

  static bool _isRecoveryJournalContentValid(
    String content,
    Directory sourceDir,
  ) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map ||
          decoded['status'] != 'planned' ||
          decoded['entries'] is! List ||
          (decoded['entries'] as List).isEmpty ||
          decoded['timestamp'] is! String ||
          DateTime.tryParse(decoded['timestamp'] as String) == null) {
        return false;
      }
      final identities = <String>{};
      final recordsDir = p.canonicalize(
        p.join(sourceDir.path, '.quarantine', 'records'),
      );
      for (final rawEntry in decoded['entries'] as List) {
        if (rawEntry is! Map) return false;
        final key = rawEntry['key'];
        final filename = rawEntry['filename'];
        final canonicalName = rawEntry['canonicalName'];
        final expectedDigest = rawEntry['expectedDigest'];
        final replacementContent = rawEntry['replacementContent'];
        final logicalFilename = rawEntry['logicalFilename'];
        final reason = rawEntry['reason'];
        final backupPath = rawEntry['existingBackupPath'];
        if (key is! String ||
            filename is! String ||
            canonicalName is! String ||
            expectedDigest is! String ||
            replacementContent is! String ||
            logicalFilename is! String ||
            reason is! String ||
            (backupPath != null && backupPath is! String)) {
          return false;
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
          return false;
        }
        if (backupPath is String &&
            p.dirname(p.canonicalize(backupPath)) != recordsDir) {
          return false;
        }
        final identity = jsonEncode([filename, expectedDigest, key]);
        if (!identities.add(identity)) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _logicalSourceName(
    String key,
    String physicalName,
    String content,
    Map<String, Map<String, Object?>> names, {
    bool hasCanonicalGroup = false,
  }) {
    final canonPhys = SourceFileMetadata.physicalName(key);
    if (physicalName != canonPhys) {
      if (hasCanonicalGroup) {
        final metadata = names[key];
        if (metadata != null) {
          final revision = SourceFileMetadata.digest(content);
          final revisions = metadata['revisions'];
          if (revisions is Map) {
            final rev = revisions[revision];
            if (rev is String) return rev;
          }
        }
      }
      return physicalName;
    }
    final metadata = names[key];
    if (metadata == null) {
      return '$key.js';
    }
    final revision = SourceFileMetadata.digest(content);
    final revisions = metadata['revisions'];
    if (revisions is Map) {
      final rev = revisions[revision];
      if (rev is String) return rev;
    }
    return (metadata['filename'] as String?) ?? '$key.js';
  }

  Future<_SourceScanResult> _scanSourceDirectory(
    Directory sourceDir, {
    bool isLiveDirectory = false,
    SyncRecords recoveryRecords = const {},
    bool includeQuarantineJournal = true,
    bool includeRecoveryJournal = true,
  }) async {
    final filesByKey = <String, List<_ScannedSourceFile>>{};
    final sessionsByKey = <String, _ScannedSession>{};
    final sourceIssues = <SyncSourceIssue>[];
    final unavailableDomains = <String>{};

    if (includeQuarantineJournal) {
      final quarantineManager = SourceQuarantineManager(sourceDir);
      try {
        final quarantineJournal = await quarantineManager.readJournal();
        for (final qRecord in quarantineJournal) {
          final issue = SyncSourceIssue(
            filename: qRecord.filename,
            reason: qRecord.reason,
            contentDigest: qRecord.originalHash,
            sourceKey: qRecord.recoveredByKey ?? qRecord.sourceKey,
            backupPath: qRecord.backupPath,
            recovered: qRecord.recovered,
          );
          sourceIssues.add(issue);
          if (!qRecord.recovered) unavailableDomains.add('source');
        }
      } on FormatException {
        final journal = quarantineManager.journalFile;
        final journalBackup = quarantineManager.journalBakFile;
        sourceIssues.add(
          SyncSourceIssue(
            filename: '.quarantine/journal.json',
            reason: 'journalCorrupted',
            contentDigest: await _digestExistingFile(journal),
            backupPath: await journalBackup.exists()
                ? journalBackup.path
                : await journal.exists()
                ? journal.path
                : null,
          ),
        );
        unavailableDomains.add('source');
      } on FileSystemException {
        sourceIssues.add(
          const SyncSourceIssue(
            filename: '.quarantine/journal.json',
            reason: 'readFailure',
          ),
        );
        unavailableDomains.add('source');
      }
    }
    if (includeRecoveryJournal) {
      var recoveryJournalExists = false;

      final journal = File(p.join(sourceDir.path, '.recovery_journal.json'));
      try {
        if (await journal.exists()) {
          recoveryJournalExists = true;
          final bytes = await journal.readAsBytes();
          final content = utf8.decode(bytes);
          final valid = _isRecoveryJournalContentValid(content, sourceDir);
          final issue = SyncSourceIssue(
            filename: p.basename(journal.path),
            reason: valid ? 'repairPending' : 'journalCorrupted',
            contentDigest: sha256.convert(bytes).toString(),
            backupPath: journal.path,
          );
          final cachedJournalBlocker = _recoveryIssues.any(
            (item) =>
                item.filename == p.basename(journal.path) && !item.recovered,
          );
          if (!cachedJournalBlocker && !sourceIssues.contains(issue)) {
            sourceIssues.add(issue);
          }
          unavailableDomains.add('source');
        }
      } on FormatException {
        final issue = SyncSourceIssue(
          filename: p.basename(journal.path),
          reason: 'journalCorrupted',
          contentDigest: await _digestExistingFile(journal),
          backupPath: await journal.exists() ? journal.path : null,
        );
        if (!sourceIssues.contains(issue)) sourceIssues.add(issue);
        unavailableDomains.add('source');
      } on FileSystemException {
        recoveryJournalExists = true;
        final issue = SyncSourceIssue(
          filename: '.recovery_journal.json',
          reason: 'readFailure',
          backupPath: journal.path,
        );
        if (!sourceIssues.contains(issue)) sourceIssues.add(issue);
        unavailableDomains.add('source');
      }
      for (final issue in _recoveryIssues) {
        if (!issue.recovered && !recoveryJournalExists) continue;
        if (!sourceIssues.contains(issue)) sourceIssues.add(issue);
        if (!issue.recovered) unavailableDomains.add('source');
      }
    }
    // 2. Scan physical files in sourceDir
    if (await sourceDir.exists()) {
      await for (final entity in sourceDir.list()) {
        if (entity is! File) continue;
        final filename = p.basename(entity.path);
        if (filename.startsWith('.') || filename.startsWith('.sync_stage')) {
          continue;
        }

        if (filename.endsWith('.js')) {
          _validateFileName(filename);
          String content;
          String contentDigest;
          try {
            final bytes = await entity.readAsBytes();
            contentDigest = sha256.convert(bytes).toString();
            content = utf8.decode(bytes);
          } catch (_) {
            sourceIssues.add(
              SyncSourceIssue(
                filename: filename,
                reason: 'readFailure',
                contentDigest: await _digestExistingFile(entity),
              ),
            );
            unavailableDomains.add('source');
            continue;
          }

          final probeResult = await ComicSourceParser.probeKey(
            content,
            entity.path,
          );
          if (probeResult.isSuccess &&
              probeResult.key != null &&
              probeResult.key!.isNotEmpty) {
            final key = probeResult.key!;
            _validateRecordKey(key);
            filesByKey
                .putIfAbsent(key, () => [])
                .add(
                  _ScannedSourceFile(
                    file: entity,
                    filename: filename,
                    content: content,
                    contentDigest: contentDigest,
                    key: key,
                  ),
                );
          } else {
            final failure = probeResult.failure;
            final failureName = failure?.name ?? 'evaluationError';
            String? sourceKey;
            for (final entry in recoveryRecords.entries) {
              if (syncRecordDomain(entry.key) == 'source') {
                final script = entry.value['script'];
                if (script is Map && script['filename'] == filename) {
                  final id = syncRecordIdentity(entry.key);
                  if (id.isNotEmpty && id.first is String) {
                    sourceKey = id.first as String;
                    break;
                  }
                }
              }
            }
            sourceIssues.add(
              SyncSourceIssue(
                filename: filename,
                reason: failureName,
                contentDigest: contentDigest,
                sourceKey: sourceKey,
              ),
            );
            unavailableDomains.add('source');
          }
        } else if (filename.endsWith('.data')) {
          final key = filename.substring(0, filename.length - 5);
          _validateRecordKey(key);
          try {
            final bytes = await entity.readAsBytes();
            final contentDigest = sha256.convert(bytes).toString();
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is! Map) {
              sourceIssues.add(
                SyncSourceIssue(
                  filename: filename,
                  reason: 'invalidSession',
                  contentDigest: contentDigest,
                  sourceKey: key,
                ),
              );
              unavailableDomains.add('sourceSession');
              continue;
            }
            sessionsByKey[key] = _ScannedSession(
              file: entity,
              key: key,
              data: Map<String, Object?>.from(decoded),
              contentDigest: contentDigest,
            );
          } catch (_) {
            sourceIssues.add(
              SyncSourceIssue(
                filename: filename,
                reason: 'invalidSession',
                contentDigest: await _digestExistingFile(entity),
                sourceKey: key,
              ),
            );
            unavailableDomains.add('sourceSession');
          }
        }
      }
    }

    Map<String, Map<String, Object?>> sourceNames = {};
    String? sourceNamesDigest;
    String? sourceNamesBackupDigest;
    final sidecarFile = File(
      p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
    );
    final sidecarBackup = File('${sidecarFile.path}.bak');
    try {
      final beforeDigest = await _digestExistingFile(sidecarFile);
      final beforeBackupDigest = await _digestExistingFile(sidecarBackup);
      sourceNames = await SourceFileMetadata.read(sourceDir);
      sourceNamesDigest = await _digestExistingFile(sidecarFile);
      sourceNamesBackupDigest = await _digestExistingFile(sidecarBackup);
      if (sourceNamesDigest != beforeDigest ||
          sourceNamesBackupDigest != beforeBackupDigest) {
        throw StateError('Source metadata changed while it was inspected');
      }
    } catch (_) {
      sourceNamesDigest = null;
      sourceNamesBackupDigest = null;
      sourceIssues.add(
        SyncSourceIssue(
          filename: SourceFileMetadata.sidecarFileName,
          reason: 'metadataCorrupted',
          contentDigest: await _digestExistingFile(sidecarFile),
          backupPath: await sidecarBackup.exists() ? sidecarBackup.path : null,
        ),
      );
      unavailableDomains.add('source');
    }

    Map<String, String>? liveFileNamesByKey;
    if (isLiveDirectory) {
      liveFileNamesByKey = <String, String>{};
      final canonicalSourceDirPath = p.canonicalize(sourceDir.path);
      for (final source in ComicSource.all()) {
        if (source.filePath.isNotEmpty) {
          final file = File(source.filePath);
          if (p.canonicalize(p.dirname(file.path)) == canonicalSourceDirPath) {
            liveFileNamesByKey[source.key] = p.basename(file.path);
          }
        }
      }
    }

    final records = <String, Map<String, Object?>>{};
    final sourceVariants = <String, List<Map<String, Object?>>>{};
    var needsSourceNormalization = false;

    for (final entry in filesByKey.entries) {
      final key = entry.key;
      final files = entry.value;

      if (files.length > 1) {
        needsSourceNormalization = true;
      }

      final canonicalName = SourceFileMetadata.physicalName(key);
      final hasCanonicalGroup =
          files.length > 1 && files.any((f) => f.filename == canonicalName);
      _ScannedSourceFile pickRepresentative(
        List<_ScannedSourceFile> candidates,
      ) {
        final liveName = liveFileNamesByKey?[key];
        _ScannedSourceFile? canonicalMatch;
        _ScannedSourceFile? liveMatch;
        _ScannedSourceFile minLexical = candidates.first;

        for (final f in candidates) {
          if (f.filename == canonicalName) {
            canonicalMatch = f;
            break;
          }
          if (liveName != null && f.filename == liveName) {
            liveMatch ??= f;
          }
          if (f.filename.compareTo(minLexical.filename) < 0) {
            minLexical = f;
          }
        }

        return canonicalMatch ?? liveMatch ?? minLexical;
      }

      final repFile = pickRepresentative(files);
      final repLogicalName = _logicalSourceName(
        key,
        repFile.filename,
        repFile.content,
        sourceNames,
        hasCanonicalGroup: hasCanonicalGroup,
      );
      final repScript = <String, Object?>{
        'filename': repLogicalName,
        'content': repFile.content,
      };

      records[syncRecordKey('source', [key])] = {'script': repScript};

      final contentToFiles = <String, List<_ScannedSourceFile>>{};
      for (final f in files) {
        contentToFiles.putIfAbsent(f.content, () => []).add(f);
      }

      if (contentToFiles.length > 1) {
        final variants = <Map<String, Object?>>[repScript];
        final otherVariants = <Map<String, Object?>>[];

        for (final entry in contentToFiles.entries) {
          final c = entry.key;
          if (c == repFile.content) continue;
          final bestForContent = pickRepresentative(entry.value);
          final logicalName = _logicalSourceName(
            key,
            bestForContent.filename,
            c,
            sourceNames,
            hasCanonicalGroup: hasCanonicalGroup,
          );
          otherVariants.add(<String, Object?>{
            'filename': logicalName,
            'content': c,
          });
        }

        otherVariants.sort((a, b) {
          final nameCmp = (a['filename'] as String).compareTo(
            b['filename'] as String,
          );
          if (nameCmp != 0) return nameCmp;
          return (a['content'] as String).compareTo(b['content'] as String);
        });

        variants.addAll(otherVariants);
        sourceVariants[syncRecordKey('source', [key])] = variants;
      }
    }

    for (final session in sessionsByKey.values) {
      records[syncRecordKey('sourceSession', [session.key])] = {
        'data': session.data,
      };
    }

    return _SourceScanResult(
      records: records,
      sourceVariants: sourceVariants,
      needsSourceNormalization: needsSourceNormalization,
      filesByKey: filesByKey,
      sessionsByKey: sessionsByKey,
      sourceNames: sourceNames,
      sourceNamesDigest: sourceNamesDigest,
      sourceNamesBackupDigest: sourceNamesBackupDigest,
      sourceIssues: sourceIssues,
      unavailableDomains: unavailableDomains,
    );
  }

  // ===========================================================================
  Future<void> recoverLocalSources({
    SyncRecords recoveryRecords = const {},
    void Function()? beforeCommit,
  }) async {
    final comicSourceDir = Directory(p.join(_dataPath, 'comic_source'));
    Future<bool> Function()? finishRuntime;
    if (_customDataPath == null) {
      finishRuntime = () async {
        final scan = await _scanSourceDirectory(
          comicSourceDir,
          isLiveDirectory: false,
          includeQuarantineJournal: false,
          includeRecoveryJournal: false,
        );
        if (scan.unavailableDomains.contains('source') ||
            scan.unavailableDomains.contains('sourceSession')) {
          return false;
        }
        await ComicSourceManager().reload();
        return true;
      };
    }
    _recoveryIssues = const [];
    _recoveryIssues = await SourceRecovery.recoverLocalSources(
      comicSourceDir,
      recoveryRecords: recoveryRecords,
      beforeCommit: beforeCommit,
      isLiveDirectory: _customDataPath == null,
      finishRuntime: finishRuntime,
    );
  }

  /// Repairs one hash-bound source issue. Journal corruption is deliberately
  /// not replaced from a backup because its missing actions cannot be proven.
  Future<bool> repairLocalSource({
    required SyncSourceIssue issue,
    required String replacementContent,
  }) async {
    final sourceDir = Directory(p.join(_dataPath, 'comic_source'));
    if (!await sourceDir.exists() ||
        issue.contentDigest == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(issue.contentDigest!)) {
      return false;
    }
    if (issue.reason == 'journalCorrupted' ||
        issue.filename == '.recovery_journal.json' ||
        issue.filename == '.quarantine/journal.json') {
      return false;
    }
    try {
      SourceFileMetadata.validateFileName(issue.filename);
    } on FormatException {
      return false;
    }

    final isMetadata = issue.filename == SourceFileMetadata.sidecarFileName;
    final isSession = issue.filename.endsWith('.data');
    final isScript = issue.filename.endsWith('.js');
    if (!isMetadata && !isSession && !isScript) return false;

    String? key;
    if (isScript) {
      final probe = await ComicSourceParser.probeKey(replacementContent);
      if (!probe.isSuccess || probe.key == null) return false;
      key = probe.key!;
      if (issue.sourceKey != null && issue.sourceKey != key) return false;
    } else if (isSession) {
      key = issue.filename.substring(0, issue.filename.length - 5);
      try {
        SourceFileMetadata.validateKey(key);
      } on FormatException {
        return false;
      }
      if (issue.sourceKey != null && issue.sourceKey != key) return false;
      try {
        if (jsonDecode(replacementContent) is! Map) return false;
      } on FormatException {
        return false;
      }
    } else {
      try {
        await _validateSourceMetadataContent(sourceDir, replacementContent);
      } on FormatException {
        return false;
      }
    }

    final replacementDigest = SourceFileMetadata.digest(replacementContent);
    final target = File(p.join(sourceDir.path, issue.filename));
    final currentDigest = await _digestExistingFile(target);
    final quarantine = SourceQuarantineManager(sourceDir);
    final records = await quarantine.readJournal();

    // A valid manual reinstall at the original filename proves an unknown
    // quarantined identity only when its exact bytes and backup both match.
    if (currentDigest != issue.contentDigest) {
      if (currentDigest != replacementDigest) return false;
      final matching = records
          .where(
            (record) =>
                record.filename == issue.filename &&
                record.originalHash == issue.contentDigest &&
                (record.sourceKey == issue.sourceKey ||
                    record.recoveredByKey == issue.sourceKey ||
                    (issue.sourceKey == null && record.sourceKey == null)),
          )
          .toList();
      if (matching.length != 1 ||
          (issue.backupPath != null &&
              p.canonicalize(issue.backupPath!) !=
                  p.canonicalize(matching.single.backupPath)) ||
          !await quarantine.verifyBackup(matching.single)) {
        return false;
      }
      if (isScript) {
        final currentProbe = await ComicSourceParser.probeKey(
          replacementContent,
          target.path,
        );
        if (!currentProbe.isSuccess || currentProbe.key != key) return false;
      } else if (isMetadata) {
        await SourceFileMetadata.read(sourceDir);
      } else {
        try {
          final decoded = jsonDecode(replacementContent);
          if (decoded is! Map) return false;
        } on FormatException {
          return false;
        }
      }
      await _requireSourceRepairRuntime(sourceDir);
      await quarantine.markRecovered(
        issue.filename,
        originalHash: issue.contentDigest!,
        sourceKey: key,
        beforeCommit: () {
          if (_digestExistingFileSync(target) != replacementDigest ||
              !quarantine.verifyBackupSync(matching.single)) {
            throw StateError('Source repair proof changed');
          }
        },
      );
      return true;
    }

    if (isScript) {
      final scriptKey = key;
      if (scriptKey == null) return false;
      try {
        final recoveryIssues = await SourceRecovery.repairCurrentSource(
          sourceDir,
          filename: issue.filename,
          expectedDigest: issue.contentDigest!,
          key: scriptKey,
          replacementContent: replacementContent,
          beforeCommit: null,
          requireRuntimeFinish: _customDataPath == null,
          finishRuntime: _customDataPath == null
              ? () => _finishSourceRepairRuntime(sourceDir)
              : null,
        );
        if (recoveryIssues.any((item) => item.recovered)) return true;
        final journal = File(p.join(sourceDir.path, '.recovery_journal.json'));
        final canonical = File(
          p.join(sourceDir.path, SourceFileMetadata.physicalName(scriptKey)),
        );
        final committed =
            await _digestExistingFile(canonical) == replacementDigest;
        if (await journal.exists() || committed) {
          final runtimeIssue = recoveryIssues
              .cast<SyncSourceIssue?>()
              .firstWhere(
                (item) =>
                    item?.reason == 'runtimeReloadDeferred' ||
                    item?.reason == 'runtimeReloadFailed',
                orElse: () => null,
              );
          throw SourceRepairPendingException(
            reason: runtimeIssue?.reason ?? 'repairPending',
            fileCommitted: committed,
          );
        }
        return false;
      } on SourceRepairPendingException {
        rethrow;
      } on FormatException {
        return false;
      } on StateError {
        return false;
      } on FileSystemException catch (error) {
        final canonical = File(
          p.join(sourceDir.path, SourceFileMetadata.physicalName(scriptKey)),
        );
        final journal = File(p.join(sourceDir.path, '.recovery_journal.json'));
        final committed =
            await _digestExistingFile(canonical) == replacementDigest;
        if (committed || await journal.exists()) {
          throw SourceRepairPendingException(
            reason: 'repairPending',
            fileCommitted: committed,
            cause: error,
          );
        }
        return false;
      } catch (error) {
        final canonical = File(
          p.join(sourceDir.path, SourceFileMetadata.physicalName(scriptKey)),
        );
        final journal = File(p.join(sourceDir.path, '.recovery_journal.json'));
        final committed =
            await _digestExistingFile(canonical) == replacementDigest;
        if (committed || await journal.exists()) {
          throw SourceRepairPendingException(
            reason: 'repairPending',
            fileCommitted: committed,
            cause: error,
          );
        }
        rethrow;
      }
    }

    final originalStat = await target.stat();
    final recordReason =
        RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(issue.reason)
        ? issue.reason
        : 'manualRepair';
    SourceQuarantineRecord? quarantineRecord;
    final matchingRecord = records
        .where(
          (record) =>
              record.filename == issue.filename &&
              record.originalHash == issue.contentDigest &&
              (record.sourceKey == key || record.sourceKey == null),
        )
        .toList();
    if (matchingRecord.length > 1) return false;
    if (matchingRecord.isNotEmpty) {
      quarantineRecord = matchingRecord.single;
      if (!await quarantine.verifyBackup(quarantineRecord)) return false;
    } else {
      quarantineRecord = await quarantine.quarantineFile(
        target,
        reason: recordReason,
        sourceKey: key,
        expectedDigest: issue.contentDigest,
        beforeCommit: () {
          if (_digestExistingFileSync(target) != issue.contentDigest ||
              target.statSync().modified != originalStat.modified ||
              target.statSync().size != originalStat.size) {
            throw StateError('Source repair issue changed');
          }
        },
      );
      if (quarantineRecord == null) return false;
    }

    final staged = File(
      p.join(
        sourceDir.path,
        '.${issue.filename}.repair_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await staged.writeAsString(replacementContent, flush: true);
      if (await _digestExistingFile(staged) != replacementDigest) return false;
      await SourceFileMetadata.atomicReplace(
        staged,
        target,
        beforeCommit: () {
          if (_digestExistingFileSync(target) != issue.contentDigest ||
              target.statSync().modified != originalStat.modified ||
              target.statSync().size != originalStat.size) {
            throw StateError('Source repair issue changed');
          }
        },
      );
    } on FileSystemException {
      return false;
    } on StateError {
      return false;
    } finally {
      await staged.deleteIgnoreError();
    }

    try {
      if (isMetadata) await SourceFileMetadata.read(sourceDir);
      await _requireSourceRepairRuntime(sourceDir);
      await quarantine.markRecovered(
        issue.filename,
        originalHash: issue.contentDigest!,
        sourceKey: key,
        beforeCommit: () {
          if (_digestExistingFileSync(target) != replacementDigest ||
              !quarantine.verifyBackupSync(quarantineRecord!)) {
            throw StateError('Source repair proof changed');
          }
        },
      );
      return true;
    } on SourceRepairPendingException {
      rethrow;
    } catch (error) {
      if (await _digestExistingFile(target) == replacementDigest) {
        final reason = error is StateError
            ? 'repairPending'
            : 'runtimeReloadFailed';
        throw SourceRepairPendingException(
          reason: reason,
          fileCommitted: true,
          cause: error,
        );
      }
      return false;
    }
  }

  Future<bool> _finishSourceRepairRuntime(Directory sourceDir) async {
    final scan = await _scanSourceDirectory(
      sourceDir,
      isLiveDirectory: false,
      includeQuarantineJournal: false,
    );
    if (scan.unavailableDomains.contains('source') ||
        scan.unavailableDomains.contains('sourceSession')) {
      return false;
    }
    await ComicSourceManager().reload();
    return true;
  }

  Future<void> _requireSourceRepairRuntime(Directory sourceDir) async {
    if (_customDataPath != null) return;
    try {
      if (!await _finishSourceRepairRuntime(sourceDir)) {
        throw const SourceRepairPendingException(
          reason: 'runtimeReloadDeferred',
          fileCommitted: true,
        );
      }
    } on SourceRepairPendingException {
      rethrow;
    } catch (error) {
      throw SourceRepairPendingException(
        reason: 'runtimeReloadFailed',
        fileCommitted: true,
        cause: error,
      );
    }
  }

  Future<void> _validateSourceMetadataContent(
    Directory sourceDir,
    String content,
  ) async {
    final validationDir = Directory(
      p.join(
        sourceDir.path,
        '.metadata_validation_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await validationDir.create();
    try {
      await File(
        p.join(validationDir.path, SourceFileMetadata.sidecarFileName),
      ).writeAsString(content, flush: true);
      await SourceFileMetadata.read(validationDir);
    } finally {
      await validationDir.deleteIgnoreError(recursive: true);
    }
  }

  /// Exports current local preferences and file-backed assets into [SyncLocalSnapshot].
  ///
  /// [domains] limits both the returned records and the business domains read.
  /// Source and session files may share an identity scan, but only requested
  /// domains are returned. Local exclusions remain invisible, not deletions.
  Future<SyncLocalSnapshot> exportSyncSnapshot({
    SyncRecords recoveryRecords = const {},
    Set<String>? domains,
  }) async {
    final requestedDomains = domains ?? appdataSyncDomains;
    final unknownDomains = requestedDomains.difference(appdataSyncDomains);
    if (unknownDomains.isNotEmpty) {
      throw ArgumentError.value(
        unknownDomains,
        'domains',
        'Contains unknown sync domains',
      );
    }
    final selectedDomains = {
      for (final domain in requestedDomains)
        if (isDomainEnabled(domain)) domain,
    };
    final records = <String, Map<String, Object?>>{};

    // 1. Settings domain (flattened to per-leaf records)
    if (selectedDomains.contains('setting')) {
      final settingsMap = _appdata.exportSyncSettings();
      for (final entry in settingsMap.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is Map) {
          _flattenMapLeaves([key], value, records);
        } else {
          records[syncRecordKey('setting', [key])] = {
            'value': canonicalizeSyncValue(value),
          };
        }
      }
    }

    // 2. Search domain (each keyword is an independent record with order)
    if (selectedDomains.contains('search')) {
      records.addAll(_appdata.exportSearchHistoryRecords());
    }

    // 3. Cookies domain (per normalized domain, atomic sorted list)
    // Any error here MUST propagate so capture fails rather than creating tombstones.
    if (selectedDomains.contains('cookies')) {
      final jar = _resolveCookieJar();
      try {
        final grouped = jar.exportAllCookiesGroupedByDomain();
        for (final entry in grouped.entries) {
          records[syncRecordKey('cookies', [entry.key])] = {
            'cookies': entry.value,
          };
        }
      } finally {
        _closeOwnedCookieJar(jar);
      }
    }

    // Scripts and sessions share a safe identity scan, but only requested
    // domains are returned to the caller.
    final wantsSources = selectedDomains.contains('source');
    final wantsSessions = selectedDomains.contains('sourceSession');
    var sourceVariants = const <String, List<Map<String, Object?>>>{};
    var needsSourceNormalization = false;
    final sourceIssues = <SyncSourceIssue>[];
    final unavailableDomains = <String>{};
    if (wantsSources || wantsSessions) {
      for (final source in ComicSource.all()) {
        await source.waitForDataWrites();
      }
      final comicSourceDir = Directory(p.join(_dataPath, 'comic_source'));
      if (await comicSourceDir.exists()) {
        final scanResult = await _scanSourceDirectory(
          comicSourceDir,
          isLiveDirectory: _customDataPath == null,
          recoveryRecords: recoveryRecords,
        );
        records.addAll({
          for (final entry in scanResult.records.entries)
            if (selectedDomains.contains(syncRecordDomain(entry.key)))
              entry.key: entry.value,
        });
        if (wantsSources) {
          sourceVariants = scanResult.sourceVariants;
          needsSourceNormalization = scanResult.needsSourceNormalization;
        }
        for (final domain in ['source', 'sourceSession']) {
          if (selectedDomains.contains(domain) &&
              scanResult.unavailableDomains.contains(domain)) {
            unavailableDomains.add(domain);
          }
        }
        sourceIssues.addAll(
          scanResult.sourceIssues.where((issue) {
            final issueDomain =
                issue.filename.endsWith('.data') ||
                    issue.reason == 'invalidSession'
                ? 'sourceSession'
                : 'source';
            return selectedDomains.contains(issueDomain);
          }),
        );
      }
    }

    return SyncLocalSnapshot(
      records: records,
      sourceVariants: sourceVariants,
      needsSourceNormalization: needsSourceNormalization,
      sourceIssues: sourceIssues,
      unavailableDomains: unavailableDomains,
    );
  }

  void _flattenMapLeaves(List<String> path, Map map, SyncRecords output) {
    if (map.isEmpty) {
      output[syncRecordKey('setting', path)] = {'value': <String, Object?>{}};
      return;
    }
    for (final entry in map.entries) {
      final nextKey = entry.key.toString();
      final subPath = [...path, nextKey];
      final val = entry.value;
      if (val is Map) {
        _flattenMapLeaves(subPath, val, output);
      } else {
        output[syncRecordKey('setting', subPath)] = {
          'value': canonicalizeSyncValue(val),
        };
      }
    }
  }

  // ===========================================================================
  // Apply
  // ===========================================================================

  /// Applies materialized records for owned domains.
  ///
  /// Flow:
  /// 1. Asynchronously stage all file writes in a temporary directory.
  /// 2. Invoke [beforeCommit].
  /// 3. Enter a short synchronous section to replace files/SQL/settings.
  /// 4. Await durable Appdata persistence. The caller completes its journal
  ///    before invoking [finishApply] for runtime reload notifications.
  Future<void> applySyncRecords(
    SyncRecords records, {
    void Function()? beforeCommit,
    bool Function(String recordKey, Map<String, Object?> script)?
    hasPreservedSourceVariant,
    bool Function(String recordKey, Map<String, Object?> script)?
    shouldStageScript,
    Set<String> unavailableDomains = const {},
  }) async {
    final stagedArtifacts = <File>[];

    final applySettings =
        isDomainEnabled('setting') && !unavailableDomains.contains('setting');
    final applySearch =
        isDomainEnabled('search') && !unavailableDomains.contains('search');
    final applyCookies =
        isDomainEnabled('cookies') && !unavailableDomains.contains('cookies');
    var applySources =
        isDomainEnabled('source') && !unavailableDomains.contains('source');
    var applySessions =
        isDomainEnabled('sourceSession') &&
        !unavailableDomains.contains('sourceSession');
    final checkPreserved = shouldStageScript ?? hasPreservedSourceVariant;

    try {
      // -----------------------------------------------------------------------
      // Phase 1: Asynchronous Staging
      // -----------------------------------------------------------------------

      // Parse incoming records by domain
      final incomingSettings = <List<String>, Object?>{};
      final incomingSearch = <String, num>{};
      final incomingCookies = <String, List<Map<String, Object?>>>{};
      final incomingSources = <String, ({String filename, String content})>{};
      final incomingSessions = <String, Map<String, Object?>>{};

      for (final entry in records.entries) {
        final domain = syncRecordDomain(entry.key);
        if (!isDomainEnabled(domain)) continue;
        final identity = syncRecordIdentity(entry.key);
        if (const {
              'search',
              'cookies',
              'source',
              'sourceSession',
            }.contains(domain) &&
            (identity.length != 1 || identity.single is! String)) {
          throw FormatException('Invalid identity for $domain record');
        }

        switch (domain) {
          case 'setting':
            if (!applySettings) break;
            if (identity.isEmpty || identity.any((part) => part is! String)) {
              throw const FormatException(
                'Setting identity must be a string path',
              );
            }
            final rootKey = identity.first as String;
            if (_appdata.isSettingSyncAllowed(rootKey)) {
              if (!entry.value.containsKey('value')) {
                throw FormatException(
                  'Setting "$rootKey" is missing its value',
                );
              }
              incomingSettings[identity.cast<String>()] = entry.value['value'];
            }
            break;

          case 'search':
            if (!applySearch) break;
            if (identity.isNotEmpty) {
              final keyword = identity.first.toString();
              final rawOrder = entry.value['order'];
              if (rawOrder != null && rawOrder is! num) {
                throw FormatException(
                  'Invalid search order for $keyword: must be a number',
                );
              }
              final order = rawOrder is num ? rawOrder : incomingSearch.length;
              incomingSearch[keyword] = order;
            }
            break;

          case 'cookies':
            if (!applyCookies) break;
            if (identity.isNotEmpty) {
              final normalizedDomain = identity.single as String;
              final rawCookies = entry.value['cookies'];
              if (rawCookies is! List) {
                throw FormatException(
                  'Invalid cookies record for domain "$normalizedDomain": cookies must be a List',
                );
              }
              final rows = <Map<String, Object?>>[];
              for (final item in rawCookies) {
                if (item is! Map) {
                  throw FormatException(
                    'Invalid cookie row for domain "$normalizedDomain": item must be a Map',
                  );
                }
                rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
              }
              incomingCookies[normalizedDomain] =
                  CookieJarSql.validateDomainCookies(normalizedDomain, rows);
            }
            break;

          case 'source':
            if (!applySources) break;
            if (identity.isNotEmpty) {
              final key = identity.first.toString();
              _validateRecordKey(key);
              final rawScript = entry.value['script'];
              if (rawScript is! Map) {
                throw FormatException(
                  'Invalid source script record for "$key": script must be an object {filename, content}',
                );
              }
              final filename = rawScript['filename'];
              final content = rawScript['content'];
              if (filename is! String || content is! String) {
                throw FormatException(
                  'Source script record for "$key" must contain both filename and content',
                );
              }
              _validateFileName(filename);
              final probeResult = await ComicSourceParser.probeKey(
                content,
                filename,
              );
              if (!probeResult.isSuccess || probeResult.key != key) {
                throw FormatException(
                  'Source script identity does not match "$key"',
                );
              }
              incomingSources[key] = (filename: filename, content: content);
            }
            break;

          case 'sourceSession':
            if (!applySessions) break;
            if (identity.isNotEmpty) {
              final key = identity.first.toString();
              _validateRecordKey(key);
              final rawData = entry.value['data'];
              if (rawData is! Map) {
                throw FormatException(
                  'Invalid source session record for "$key": data must be a Map',
                );
              }
              incomingSessions[key] = Map<String, Object?>.from(rawData);
            }
            break;
        }
      }

      // Reconstruct root settings from leaf records
      final reconstructedSettings = applySettings
          ? _reconstructSettingsFromLeaves(incomingSettings)
          : <String, dynamic>{};
      if (applySettings) {
        for (final entry in reconstructedSettings.entries) {
          _appdata.validateSyncSetting(entry.key, entry.value);
        }
      }
      if (applySources || applySessions) {
        for (final source in ComicSource.all()) {
          await source.waitForDataWrites();
        }
      }

      // Reconstruct sorted search history
      final sortedKeywords = incomingSearch.entries.toList()
        ..sort((a, b) {
          final order = a.value.compareTo(b.value);
          return order == 0 ? a.key.compareTo(b.key) : order;
        });
      final newSearchHistory = sortedKeywords.map((e) => e.key).toList();

      final targetSourceDir = Directory(p.join(_dataPath, 'comic_source'));
      final _SourceScanResult localScan;
      if (applySources || applySessions) {
        await targetSourceDir.create(recursive: true);
        localScan = await _scanSourceDirectory(
          targetSourceDir,
          isLiveDirectory: true,
        );
        if (localScan.unavailableDomains.contains('source')) {
          applySources = false;
        }
        if (localScan.unavailableDomains.contains('sourceSession')) {
          applySessions = false;
        }
      } else {
        localScan = _SourceScanResult(
          records: const {},
          sourceVariants: const {},
          needsSourceNormalization: false,
          filesByKey: const {},
          sessionsByKey: const {},
          sourceNames: const {},
        );
      }
      final sourceNames = localScan.sourceNames;

      final stagedSourceMoves = <_StagedFileMove>[];
      final metadataFileProofs = <File, String>{};
      final sourceNamesTarget = File(
        p.join(targetSourceDir.path, SourceFileMetadata.sidecarFileName),
      );
      File? sourceNamesStaged;
      File? sourceNamesBackupStaged;
      String? sourceNamesStagedDigest;
      String? sourceNamesBackupStagedDigest;
      final sourceNamesBackupTarget = File('${sourceNamesTarget.path}.bak');
      final sourceNamesCurrentDigest = localScan.sourceNamesDigest;
      final sourceNamesBackupCurrentDigest = localScan.sourceNamesBackupDigest;

      String? scannedSourceDigest(String key, String filename) {
        for (final sourceFile
            in localScan.filesByKey[key] ?? const <_ScannedSourceFile>[]) {
          if (sourceFile.filename == filename) {
            return sourceFile.contentDigest;
          }
        }
        return null;
      }

      if (applySources) {
        if (await _digestExistingFile(sourceNamesTarget) !=
                sourceNamesCurrentDigest ||
            await _digestExistingFile(sourceNamesBackupTarget) !=
                sourceNamesBackupCurrentDigest) {
          throw StateError('Source metadata changed while apply was staged');
        }

        for (final entry in incomingSources.entries) {
          final key = entry.key;
          final data = entry.value;
          _validateRecordKey(key);
          _validateFileName(data.filename);

          final physicalName = SourceFileMetadata.physicalName(key);
          final targetFile = File(p.join(targetSourceDir.path, physicalName));
          _assertPathContained(targetSourceDir, targetFile);
          final expectedTargetDigest = scannedSourceDigest(key, physicalName);
          final currentDigest = await _digestExistingFile(targetFile);
          if (currentDigest != expectedTargetDigest) {
            throw StateError('Source file changed while apply was staged');
          }
          final incomingDigest = SourceFileMetadata.digest(data.content);
          if (currentDigest != incomingDigest) {
            final staged = _siblingStage(targetFile);
            stagedArtifacts.add(staged);
            await staged.writeAsString(data.content, flush: true);
            if (await _digestExistingFile(staged) != incomingDigest) {
              throw const FileSystemException(
                'Staged source script verification failed',
              );
            }
            stagedSourceMoves.add(
              _StagedFileMove(
                staged: staged,
                target: targetFile,
                expectedStagedDigest: incomingDigest,
                expectedTargetDigest: expectedTargetDigest,
              ),
            );
          }
          metadataFileProofs[targetFile] = incomingDigest;
        }

        final nextSourceNames = <String, Map<String, Object?>>{};
        final sourceKeys = <String>{
          ...localScan.filesByKey.keys,
          ...incomingSources.keys,
        }.toList()..sort();
        for (final key in sourceKeys) {
          final incoming = incomingSources[key];
          if (incoming == null) continue;

          final revisions = <String, String>{};
          final aliases = <String>[];
          final prior = sourceNames[key];
          if (prior != null) {
            if (prior['revisions'] is Map) {
              for (final revision in (prior['revisions'] as Map).entries) {
                if (revision.key is String && revision.value is String) {
                  revisions[revision.key as String] = revision.value as String;
                }
              }
            }
            if (prior['aliases'] is List) {
              for (final alias in (prior['aliases'] as List)) {
                if (alias is String && !aliases.contains(alias)) {
                  aliases.add(alias);
                }
              }
            }
          }

          final localFiles =
              localScan.filesByKey[key] ?? <_ScannedSourceFile>[];
          localFiles.sort((a, b) => a.filename.compareTo(b.filename));
          final sourceRecordKey = syncRecordKey('source', [key]);
          final localSourceRecord = localScan.records[sourceRecordKey];
          final localScript = localSourceRecord?['script'];
          final candidateScripts =
              localScan.sourceVariants[sourceRecordKey] ??
              (localScript is Map
                  ? [Map<String, Object?>.from(localScript)]
                  : const <Map<String, Object?>>[]);
          final localRevisionNames = <String, String>{};
          for (final script in candidateScripts) {
            final content = script['content'];
            final filename = script['filename'];
            if (content is String && filename is String) {
              localRevisionNames.putIfAbsent(
                SourceFileMetadata.digest(content),
                () => filename,
              );
            }
          }
          final hasCanonicalGroup =
              localFiles.length > 1 &&
              localFiles.any(
                (sourceFile) =>
                    sourceFile.filename == SourceFileMetadata.physicalName(key),
              );
          for (final sourceFile in localFiles) {
            final logicalName =
                localRevisionNames[sourceFile.contentDigest] ??
                _logicalSourceName(
                  key,
                  sourceFile.filename,
                  sourceFile.content,
                  sourceNames,
                  hasCanonicalGroup: hasCanonicalGroup,
                );
            // Each content revision has one causal script value even when it
            // exists at several physical aliases. Persist the scanner's chosen
            // logical name so a restart sees that same value, not a new alias.
            revisions[sourceFile.contentDigest] = logicalName;
            for (final alias in [sourceFile.filename, logicalName]) {
              if (!aliases.contains(alias)) aliases.add(alias);
            }
          }

          final incomingDigest = SourceFileMetadata.digest(incoming.content);
          revisions[incomingDigest] = incoming.filename;
          for (final alias in [
            SourceFileMetadata.physicalName(key),
            incoming.filename,
          ]) {
            if (!aliases.contains(alias)) aliases.add(alias);
          }

          final physicalName = SourceFileMetadata.physicalName(key);
          final canonicalFile = File(
            p.join(targetSourceDir.path, physicalName),
          );
          final physicalFiles = <String, String>{physicalName: incomingDigest};
          final priorPublicationId = prior?['publicationId'] as String?;
          nextSourceNames[key] = {
            'filename': incoming.filename,
            'revisions': revisions,
            'files': physicalFiles,
            'aliases': aliases,
            if (priorPublicationId != null) 'publicationId': priorPublicationId,
          };
          metadataFileProofs[canonicalFile] = incomingDigest;
        }

        final metadataContent = jsonEncode(nextSourceNames);
        await _validateSourceMetadataContent(targetSourceDir, metadataContent);
        final stagedMetadata = _siblingStage(sourceNamesTarget);
        sourceNamesStaged = stagedMetadata;
        stagedArtifacts.add(stagedMetadata);
        await stagedMetadata.writeAsString(metadataContent, flush: true);
        final metadataDigest = SourceFileMetadata.digest(metadataContent);
        sourceNamesStagedDigest = metadataDigest;
        if (await _digestExistingFile(stagedMetadata) != metadataDigest) {
          throw const FileSystemException(
            'Staged source metadata verification failed',
          );
        }

        if (sourceNamesCurrentDigest != null) {
          final previousMetadataBytes = await sourceNamesTarget.readAsBytes();
          if (sha256.convert(previousMetadataBytes).toString() !=
              sourceNamesCurrentDigest) {
            throw StateError('Source metadata changed while apply was staged');
          }
          final stagedBackup = _siblingStage(sourceNamesBackupTarget);
          sourceNamesBackupStaged = stagedBackup;
          sourceNamesBackupStagedDigest = sourceNamesCurrentDigest;
          stagedArtifacts.add(stagedBackup);
          await stagedBackup.writeAsBytes(previousMetadataBytes, flush: true);
          if (await _digestExistingFile(stagedBackup) !=
              sourceNamesCurrentDigest) {
            throw const FileSystemException(
              'Staged source metadata backup verification failed',
            );
          }
        }
      }

      final stagedSessionMoves = <_StagedFileMove>[];
      final updatedSessionKeys = <String>{};
      if (applySessions) {
        for (final entry in incomingSessions.entries) {
          final key = entry.key;
          final sessionData = entry.value;
          _validateRecordKey(key);

          final targetFile = File(p.join(targetSourceDir.path, '$key.data'));
          _assertPathContained(targetSourceDir, targetFile);
          final scannedSession = localScan.sessionsByKey[key];
          final expectedTargetDigest = scannedSession?.contentDigest;
          final currentDigest = await _digestExistingFile(targetFile);
          if (currentDigest != expectedTargetDigest) {
            throw StateError('Source session changed while apply was staged');
          }

          final encoded = jsonEncode(sessionData);
          final needsWrite =
              scannedSession == null ||
              !syncValuesEqual(scannedSession.data, sessionData);
          if (needsWrite) {
            final staged = _siblingStage(targetFile);
            stagedArtifacts.add(staged);
            await staged.writeAsString(encoded, flush: true);
            final incomingDigest = SourceFileMetadata.digest(encoded);
            if (await _digestExistingFile(staged) != incomingDigest) {
              throw const FileSystemException(
                'Staged source session verification failed',
              );
            }
            stagedSessionMoves.add(
              _StagedFileMove(
                staged: staged,
                target: targetFile,
                expectedStagedDigest: incomingDigest,
                expectedTargetDigest: expectedTargetDigest,
              ),
            );
            updatedSessionKeys.add(key);
          }
        }
      }
      final filesToDeleteMap = <String, _FileDeletion>{};

      if (applySources) {
        for (final entry in localScan.filesByKey.entries) {
          final key = entry.key;
          final localFiles = entry.value;
          final sourceKey = syncRecordKey('source', [key]);
          final incomingContent = incomingSources[key]?.content;
          final candidateScripts =
              localScan.sourceVariants[sourceKey] ??
              (localScan.records.containsKey(sourceKey)
                  ? [
                      localScan.records[sourceKey]!['script']
                          as Map<String, Object?>,
                    ]
                  : const <Map<String, Object?>>[]);

          for (final script in candidateScripts) {
            final scriptContent = script['content'] as String;
            if (scriptContent == incomingContent) continue;
            if (checkPreserved?.call(sourceKey, script) != true) {
              throw StateError(
                'Cannot discard source candidate for "$key" without durable merge proof.',
              );
            }
          }

          final canonicalPhysicalName = SourceFileMetadata.physicalName(key);
          final isIncoming = incomingSources.containsKey(key);
          for (final sourceFile in localFiles) {
            if (isIncoming && sourceFile.filename == canonicalPhysicalName) {
              continue;
            }
            _assertPathContained(targetSourceDir, sourceFile.file);
            final canonicalPath = p.canonicalize(sourceFile.file.path);
            filesToDeleteMap[canonicalPath] = _FileDeletion(
              target: sourceFile.file,
              expectedDigest: sourceFile.contentDigest,
            );
          }
        }
      }

      if (applySessions) {
        for (final session in localScan.sessionsByKey.values) {
          if (incomingSessions.containsKey(session.key)) continue;
          _assertPathContained(targetSourceDir, session.file);
          final canonicalPath = p.canonicalize(session.file.path);
          filesToDeleteMap[canonicalPath] = _FileDeletion(
            target: session.file,
            expectedDigest: session.contentDigest,
          );
          updatedSessionKeys.add(session.key);
        }
      }

      final filesToDelete = filesToDeleteMap.values.toList();
      if (applySources &&
          (stagedSourceMoves.isNotEmpty ||
              filesToDelete.any((file) => file.target.path.endsWith('.js')))) {
        _reloadSourcesPending = true;
      }
      _reloadSessionsPending.addAll(updatedSessionKeys);

      // -----------------------------------------------------------------------
      // Phase 2: Short Commit Section (Strictly Synchronous, NO Awaits)
      // -----------------------------------------------------------------------
      _executeSynchronousCommit(
        beforeCommit: beforeCommit,
        stagedSourceMoves: stagedSourceMoves,
        stagedSessionMoves: stagedSessionMoves,
        filesToDelete: filesToDelete,
        incomingCookies: incomingCookies,
        reconstructedSettings: reconstructedSettings,
        searchHistory: newSearchHistory,
        searchOrders: incomingSearch,
        sourceNamesStaged: sourceNamesStaged,
        sourceNamesBackupStaged: sourceNamesBackupStaged,
        sourceNamesTarget: sourceNamesTarget,
        sourceNamesBackupTarget: sourceNamesBackupTarget,
        expectedSourceNamesStagedDigest: sourceNamesStagedDigest,
        expectedSourceNamesBackupStagedDigest: sourceNamesBackupStagedDigest,
        expectedSourceNamesDigest: sourceNamesCurrentDigest,
        expectedSourceNamesBackupDigest: sourceNamesBackupCurrentDigest,
        metadataFileProofs: metadataFileProofs,
        applySources: applySources,
        applySessions: applySessions,
        applyCookies: applyCookies,
        applySettings: applySettings,
        applySearch: applySearch,
      );
      if (applySettings || applySearch) {
        await _appdata.saveData(false);
      }
    } finally {
      for (final staged in stagedArtifacts) {
        if (await staged.exists()) await staged.delete();
      }
    }
  }

  /// Runs only after the caller has completed its durable apply journal.
  /// Session reloads use revision checks; source replacements share live data.
  Future<void> finishApply() async {
    await _reloadRuntimeSafely(
      scriptsChanged: _reloadSourcesPending,
      updatedSessionKeys: _reloadSessionsPending,
    );
    _reloadSourcesPending = false;
    _reloadSessionsPending.clear();
  }

  /// Reconstructs root settings map from per-leaf records.
  Map<String, dynamic> _reconstructSettingsFromLeaves(
    Map<List<String>, Object?> leaves,
  ) {
    final result = <String, dynamic>{};
    final ordered = leaves.entries.toList()
      ..sort((a, b) => a.key.length.compareTo(b.key.length));
    for (final entry in ordered) {
      final path = entry.key;
      Map<String, dynamic> cursor = result;
      for (int i = 0; i < path.length - 1; i++) {
        final child = cursor.putIfAbsent(path[i], () => <String, dynamic>{});
        if (child is! Map<String, dynamic>) {
          throw const FormatException(
            'A primitive setting cannot contain child leaves',
          );
        }
        cursor = child;
      }
      cursor[path.last] = canonicalizeSyncValue(entry.value);
    }
    return result;
  }

  /// Synchronous commit section: atomic file swaps, SQLite transaction, in-memory settings.
  ///
  /// Any exception propagates without swallowing so the parent apply journal can recover.
  void _executeSynchronousCommit({
    required void Function()? beforeCommit,
    required List<_StagedFileMove> stagedSourceMoves,
    required List<_StagedFileMove> stagedSessionMoves,
    required List<_FileDeletion> filesToDelete,
    required Map<String, List<Map<String, Object?>>> incomingCookies,
    required Map<String, dynamic> reconstructedSettings,
    required List<String> searchHistory,
    required Map<String, num> searchOrders,
    required File? sourceNamesStaged,
    required File? sourceNamesBackupStaged,
    required File sourceNamesTarget,
    required File sourceNamesBackupTarget,
    required String? expectedSourceNamesStagedDigest,
    required String? expectedSourceNamesBackupStagedDigest,
    required String? expectedSourceNamesDigest,
    required String? expectedSourceNamesBackupDigest,
    required Map<File, String> metadataFileProofs,
    required bool applySources,
    required bool applySessions,
    required bool applyCookies,
    required bool applySettings,
    required bool applySearch,
  }) {
    void verifyDigest(File file, String? expectedDigest) {
      if (_digestExistingFileSync(file) != expectedDigest) {
        throw StateError('File changed during sync apply');
      }
    }

    // The coordinator's generation guard and synchronous domain commits run
    // immediately before the first destructive file or store mutation.
    beforeCommit?.call();

    for (final move in stagedSourceMoves) {
      verifyDigest(move.staged, move.expectedStagedDigest);
      verifyDigest(move.target, move.expectedTargetDigest);
    }
    for (final move in stagedSessionMoves) {
      verifyDigest(move.staged, move.expectedStagedDigest);
      verifyDigest(move.target, move.expectedTargetDigest);
    }
    for (final deletion in filesToDelete) {
      verifyDigest(deletion.target, deletion.expectedDigest);
    }
    if (applySources) {
      verifyDigest(sourceNamesTarget, expectedSourceNamesDigest);
      verifyDigest(sourceNamesBackupTarget, expectedSourceNamesBackupDigest);
      if (sourceNamesStaged != null) {
        verifyDigest(sourceNamesStaged, expectedSourceNamesStagedDigest);
      }
      if (sourceNamesBackupStaged != null) {
        verifyDigest(
          sourceNamesBackupStaged,
          expectedSourceNamesBackupStagedDigest,
        );
      }
    }

    if (applySources) {
      for (final move in stagedSourceMoves) {
        SourceFileMetadata.atomicReplaceSync(
          move.staged,
          move.target,
          beforeCommit: () {
            verifyDigest(move.staged, move.expectedStagedDigest);
            verifyDigest(move.target, move.expectedTargetDigest);
          },
        );
      }
    }

    if (applySessions) {
      for (final move in stagedSessionMoves) {
        SourceFileMetadata.atomicReplaceSync(
          move.staged,
          move.target,
          beforeCommit: () {
            verifyDigest(move.staged, move.expectedStagedDigest);
            verifyDigest(move.target, move.expectedTargetDigest);
          },
        );
      }
    }

    if (applySources && sourceNamesStaged != null) {
      var expectedBackupAfterCommit = expectedSourceNamesBackupDigest;
      if (sourceNamesBackupStaged != null) {
        SourceFileMetadata.atomicReplaceSync(
          sourceNamesBackupStaged,
          sourceNamesBackupTarget,
          beforeCommit: () {
            verifyDigest(
              sourceNamesBackupStaged,
              expectedSourceNamesBackupStagedDigest,
            );
            verifyDigest(sourceNamesTarget, expectedSourceNamesDigest);
            verifyDigest(
              sourceNamesBackupTarget,
              expectedSourceNamesBackupDigest,
            );
          },
        );
        expectedBackupAfterCommit = expectedSourceNamesDigest;
      }

      SourceFileMetadata.atomicReplaceSync(
        sourceNamesStaged,
        sourceNamesTarget,
        beforeCommit: () {
          verifyDigest(sourceNamesStaged, expectedSourceNamesStagedDigest);
          verifyDigest(sourceNamesTarget, expectedSourceNamesDigest);
          verifyDigest(sourceNamesBackupTarget, expectedBackupAfterCommit);
          for (final proof in metadataFileProofs.entries) {
            verifyDigest(proof.key, proof.value);
          }
        },
      );
    }

    for (final deletion in filesToDelete) {
      verifyDigest(deletion.target, deletion.expectedDigest);
      deletion.target.deleteSync();
    }

    if (applyCookies) {
      final jar = _resolveCookieJar();
      try {
        jar.applyAllDomainCookies(incomingCookies);
      } finally {
        _closeOwnedCookieJar(jar);
      }
    }

    if (applySettings) {
      final currentAllowedKeys = _appdata.syncAllowedSettingKeys;
      for (final key in currentAllowedKeys) {
        if (!reconstructedSettings.containsKey(key)) {
          _appdata.removeSyncSetting(key);
        }
      }

      for (final entry in reconstructedSettings.entries) {
        _appdata.applySyncSetting(entry.key, entry.value);
      }
    }

    if (applySearch) {
      _appdata.setFullSearchHistory(searchHistory, orders: searchOrders);
    }
  }

  /// Required runtime finish; reload errors propagate so the apply journal stays pending.
  Future<void> _reloadRuntimeSafely({
    required bool scriptsChanged,
    required Set<String> updatedSessionKeys,
  }) async {
    if (_customDataPath == null) {
      if (scriptsChanged) {
        final sourceDir = Directory(p.join(_dataPath, 'comic_source'));
        final scan = await _scanSourceDirectory(
          sourceDir,
          isLiveDirectory: false,
          includeQuarantineJournal: false,
        );
        if (scan.unavailableDomains.contains('source') ||
            scan.unavailableDomains.contains('sourceSession')) {
          throw const SourceRepairPendingException(
            reason: 'runtimeReloadDeferred',
            fileCommitted: true,
          );
        }
      }
      for (final key in updatedSessionKeys) {
        final active = ComicSourceManager().find(key);
        if (active != null) await active.loadData();
      }
      if (scriptsChanged) await ComicSourceManager().reload();
    }
    await notifySettingsImported();
  }

  // ===========================================================================
  // Legacy Migration Reader
  // ===========================================================================

  /// Reads records from an extracted legacy directory without mutating live state.
  ///
  /// Reuses shared safety filtering, key probing, and domain normalization.
  Future<SyncLocalSnapshot> readLegacySnapshot(Directory extracted) async {
    final records = <String, Map<String, Object?>>{};

    // 1. Read appdata.json or syncdata.json
    final appdataFile = File(p.join(extracted.path, 'appdata.json'));
    final syncdataFile = File(p.join(extracted.path, 'syncdata.json'));
    final targetFile = appdataFile.existsSync()
        ? appdataFile
        : (syncdataFile.existsSync() ? syncdataFile : null);

    if (targetFile != null) {
      final content = await targetFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const FormatException('Legacy appdata root must be an object');
      }
      final rawSettings = decoded['settings'];
      if (decoded.containsKey('settings') && rawSettings is! Map) {
        throw const FormatException('Legacy settings must be an object');
      }
      if (rawSettings is Map) {
        final disabled = _appdata.getDisabledSyncFields(forExport: true);
        for (final entry in rawSettings.entries) {
          if (entry.key is! String) {
            throw const FormatException('Legacy setting keys must be strings');
          }
          final key = entry.key as String;
          if (disabled.contains(key)) continue;
          final val = key == 'initialPage'
              ? normalizeStartupPage(entry.value)
              : entry.value;
          _appdata.validateSyncSetting(key, val);
          if (val is Map) {
            _flattenMapLeaves([key], val, records);
          } else {
            records[syncRecordKey('setting', [key])] = {
              'value': canonicalizeSyncValue(val),
            };
          }
        }
      }
      final keywords = <String>[];
      for (final field in ['searchHistory', 'overflowSearchHistory']) {
        final rawKeywords = decoded[field];
        if (decoded.containsKey(field) &&
            (rawKeywords is! List ||
                rawKeywords.any((item) => item is! String))) {
          throw FormatException('Legacy $field must be a list of strings');
        }
        if (rawKeywords is List) {
          keywords.addAll(rawKeywords.cast<String>());
        }
      }
      final orders = Appdata.decodeSearchHistoryOrder(decoded, keywords).orders;
      for (final keyword in keywords) {
        records[syncRecordKey('search', [keyword])] = {
          'order': orders[keyword],
        };
      }
    }

    // 2. Read isolated cookie.db
    final cookieDbFile = File(p.join(extracted.path, 'cookie.db'));
    if (cookieDbFile.existsSync()) {
      Database? isolatedDb;
      try {
        isolatedDb = sqlite3.open(cookieDbFile.path);
        final rows = isolatedDb.select('''
          SELECT name, value, domain, path, expires, secure, httpOnly
          FROM cookies;
        ''');
        final grouped = <String, List<Map<String, Object?>>>{};
        for (final row in rows) {
          final domain = row['domain'] as String;
          final normalized = normalizeCookieDomain(domain);
          final item = <String, Object?>{
            'name': row['name'] as String,
            'value': row['value'] as String,
            'domain': domain,
            'path': row['path'] as String? ?? '/',
            'expires': row['expires'] as int?,
            'secure': (row['secure'] == 1),
            'httpOnly': (row['httpOnly'] == 1),
          };
          grouped.putIfAbsent(normalized, () => []).add(item);
        }

        for (final entry in grouped.entries) {
          entry.value.sort((a, b) {
            final c1 = (a['name'] as String).compareTo(b['name'] as String);
            if (c1 != 0) return c1;
            final c2 = ((a['path'] as String?) ?? '').compareTo(
              (b['path'] as String?) ?? '',
            );
            if (c2 != 0) return c2;
            return ((a['domain'] as String?) ?? '').compareTo(
              (b['domain'] as String?) ?? '',
            );
          });
          records[syncRecordKey('cookies', [entry.key])] = {
            'cookies': entry.value,
          };
        }
      } finally {
        isolatedDb?.dispose();
      }
    }

    // 3. Read isolated comic_source directory
    final sourceDir = Directory(p.join(extracted.path, 'comic_source'));
    var sourceVariants = const <String, List<Map<String, Object?>>>{};
    var needsSourceNormalization = false;
    var sourceIssues = const <SyncSourceIssue>[];
    var unavailableDomains = const <String>{};
    if (sourceDir.existsSync()) {
      final scanResult = await _scanSourceDirectory(
        sourceDir,
        isLiveDirectory: false,
      );
      records.addAll(scanResult.records);
      sourceVariants = scanResult.sourceVariants;
      needsSourceNormalization = scanResult.needsSourceNormalization;
      sourceIssues = scanResult.sourceIssues;
      unavailableDomains = scanResult.unavailableDomains;
    }

    return SyncLocalSnapshot(
      records: records,
      sourceVariants: sourceVariants,
      needsSourceNormalization: needsSourceNormalization,
      sourceIssues: sourceIssues,
      unavailableDomains: unavailableDomains,
    );
  }
}
