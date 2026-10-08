import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:venera_plus/features/comic_source/comic_source.dart';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/sync_records.dart';

/// Seed data produced by reading a legacy `.venera` remote snapshot archive.
class LegacyMergeSeed {
  final String id;
  final SyncRecords records;
  final Map<String, List<Map<String, Object?>>> sourceVariants;
  final List<SyncSourceIssue> sourceIssues;
  final Set<String> unavailableDomains;

  const LegacyMergeSeed(
    this.id,
    this.records, {
    this.sourceVariants = const {},
    this.sourceIssues = const [],
    this.unavailableDomains = const {},
  });

  @override
  String toString() =>
      'LegacyMergeSeed(id: $id, records: ${records.length}, variants: ${sourceVariants.length}, issues: ${sourceIssues.length}, unavailable: ${unavailableDomains.length})';
}

/// Parsed metadata for a remote numeric day-version `.venera` archive snapshot.
class _LegacyRemoteSnapshot {
  final dav.File file;
  final String name;
  final int day;
  final int version;
  final String? eTag;

  _LegacyRemoteSnapshot({
    required this.file,
    required this.name,
    required this.day,
    required this.version,
    required this.eTag,
  });

  static _LegacyRemoteSnapshot? tryParse(dav.File file) {
    if (file.isDir == true) return null;
    final rawName = file.name ?? file.path;
    if (rawName == null || rawName.isEmpty) return null;
    final name =
        rawName.split('/').where((s) => s.isNotEmpty).lastOrNull ?? rawName;
    if (!name.endsWith('.venera')) return null;

    final base = name.substring(0, name.length - '.venera'.length);
    final parts = base.split('-');
    if (parts.length != 2) return null;

    final day = int.tryParse(parts[0]);
    final version = int.tryParse(parts[1]);
    if (day == null || version == null || day < 0 || version < 0) return null;

    return _LegacyRemoteSnapshot(
      file: file,
      name: name,
      day: day,
      version: version,
      eTag: file.eTag,
    );
  }
}

/// One-time legacy WebDAV `.venera` snapshot lossless seed reader.
///
/// Discovers newest remote numeric day-version `.venera` snapshots without
/// modifying live local databases. Supports same-version collision files by
/// reading both as distinct seeds. Enforces strict content hashing, ZIP
/// integrity verification, path traversal rejection, symlink rejection, and
/// isolated whitelist extraction.
///
/// Network, download, verification, or schema failures throw explicitly to
/// abort migration and avoid marking legacy data as completed with partial data.
class LegacySyncReader {
  LegacySyncReader(
    this.client,
    this.scratch, {
    required this.preferences,
    this.verifiedSourceBackupDirectory,
    this.legacyOverrideDirectory,
  });

  final dav.Client client;
  final Directory scratch;
  final SyncPreferencesAdapter preferences;
  final Directory? verifiedSourceBackupDirectory;
  final Directory? legacyOverrideDirectory;

  static final RegExp _validSha256 = RegExp(r'^[a-fA-F0-9]{64}$');
  static final RegExp _validSourceKey = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');

  static void _validateSafeBasename(String filename) {
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.startsWith('.') ||
        filename.contains('..') ||
        filename.contains('/') ||
        filename.contains(r'\') ||
        filename.contains(':') ||
        filename.contains('\u0000') ||
        p.basename(filename) != filename ||
        p.isAbsolute(filename)) {
      throw FormatException('Invalid or unsafe filename: $filename');
    }
  }

  static void _validateOverrideKey(String key) {
    if (!_validSourceKey.hasMatch(key)) {
      throw const FormatException('Invalid legacy override source key');
    }
  }

  static Future<Uint8List> _readBoundedFile(
    File file, {
    required int maxBytes,
    required String failureMessage,
  }) async {
    final builder = BytesBuilder(copy: false);
    var totalBytes = 0;
    await for (final chunk in file.openRead()) {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        throw FormatException(failureMessage);
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<void> _createOverrideGenesis({
    required Directory overrideDirectory,
    required Directory archiveDirectory,
    required String archiveSha256,
  }) async {
    await overrideDirectory.create(recursive: true);
    if (await FileSystemEntity.type(
          overrideDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Invalid legacy override directory');
    }

    final bootstrapDirectory = Directory(
      p.join(
        overrideDirectory.path,
        '.legacy_override_bootstrap_${archiveSha256}_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}',
      ),
    );
    try {
      await bootstrapDirectory.create();
      final filesDirectory = Directory(
        p.join(bootstrapDirectory.path, 'files'),
      );
      await filesDirectory.create();

      final genesisBytes = utf8.encode(
        jsonEncode({
          'archiveSha256': archiveSha256,
          'entries': <String, Object?>{},
          'state': 'genesis',
        }),
      );
      if (genesisBytes.length > _maxOverrideManifestBytes) {
        throw const FormatException(
          'Legacy override genesis exceeds size limit',
        );
      }
      final stagedManifest = File(
        p.join(bootstrapDirectory.path, 'manifest.json'),
      );
      await stagedManifest.writeAsBytes(genesisBytes, flush: true);
      final stagedBytes = await _readBoundedFile(
        stagedManifest,
        maxBytes: _maxOverrideManifestBytes,
        failureMessage: 'Legacy override genesis exceeds size limit',
      );
      if (stagedBytes.length != genesisBytes.length ||
          sha256.convert(stagedBytes).toString() !=
              sha256.convert(genesisBytes).toString() ||
          await FileSystemEntity.type(
                filesDirectory.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.directory) {
        throw StateError('Legacy override genesis verification failed');
      }

      final destinationType = await FileSystemEntity.type(
        archiveDirectory.path,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.notFound) {
        await bootstrapDirectory.rename(archiveDirectory.path);
      } else if (destinationType != FileSystemEntityType.directory) {
        throw const FormatException(
          'Invalid legacy override archive directory',
        );
      }
    } finally {
      try {
        if (await bootstrapDirectory.exists()) {
          await bootstrapDirectory.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  static Future<Map<String, Object?>> _readValidatedOverrideManifest({
    required Directory archiveDir,
    required String archiveSha256,
    bool allowMissing = false,
  }) async {
    final archiveType = await FileSystemEntity.type(
      archiveDir.path,
      followLinks: false,
    );
    if (archiveType == FileSystemEntityType.notFound && allowMissing) {
      return {'archiveSha256': archiveSha256, 'entries': <String, Object?>{}};
    }
    if (archiveType != FileSystemEntityType.directory) {
      throw const FormatException('Invalid legacy override archive directory');
    }

    final manifestFile = File(p.join(archiveDir.path, 'manifest.json'));
    final manifestType = await FileSystemEntity.type(
      manifestFile.path,
      followLinks: false,
    );
    if (manifestType != FileSystemEntityType.file) {
      throw const FormatException(
        'Missing or invalid legacy override manifest',
      );
    }

    if (await manifestFile.length() > _maxOverrideManifestBytes) {
      throw const FormatException(
        'Legacy override manifest exceeds size limit',
      );
    }
    final manifestBytes = await _readBoundedFile(
      manifestFile,
      maxBytes: _maxOverrideManifestBytes,
      failureMessage: 'Legacy override manifest exceeds size limit',
    );

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
    } catch (_) {
      throw const FormatException('Corrupted legacy override manifest JSON');
    }
    if (decoded is! Map ||
        decoded['archiveSha256'] != archiveSha256 ||
        decoded['entries'] is! Map) {
      throw const FormatException(
        'Corrupted or forged legacy override manifest',
      );
    }

    final entries = decoded['entries'] as Map;
    final isGenesis = decoded.length == 3 && decoded['state'] == 'genesis';
    final isCommitted = decoded.length == 2;
    if ((!isGenesis && !isCommitted) ||
        (isGenesis && entries.isNotEmpty) ||
        (isCommitted && entries.isEmpty) ||
        entries.length > _maxMembers) {
      throw const FormatException('Invalid legacy override manifest state');
    }
    final filenames = <String>{};
    final filesDir = Directory(p.join(archiveDir.path, 'files'));
    if (await FileSystemEntity.type(filesDir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'Missing or invalid legacy override files directory',
      );
    }

    const requiredEntryFields = {
      'filename',
      'entryPath',
      'contentSha256',
      'type',
      'expectedKey',
      'relativeFilePath',
    };
    for (final manifestEntry in entries.entries) {
      if (manifestEntry.key is! String ||
          manifestEntry.value is! Map<String, dynamic>) {
        throw const FormatException('Invalid legacy override manifest entry');
      }
      final filename = manifestEntry.key as String;
      final entry = manifestEntry.value as Map<String, dynamic>;
      if (entry.length != requiredEntryFields.length ||
          !entry.keys.toSet().containsAll(requiredEntryFields) ||
          !requiredEntryFields.containsAll(entry.keys)) {
        throw const FormatException('Invalid legacy override entry schema');
      }
      if (entry['filename'] is! String ||
          entry['entryPath'] is! String ||
          entry['contentSha256'] is! String ||
          entry['type'] is! String ||
          entry['expectedKey'] is! String ||
          entry['relativeFilePath'] is! String) {
        throw const FormatException('Invalid legacy override entry schema');
      }

      _validateSafeBasename(filename);
      if (entry['filename'] != filename ||
          !filenames.add(filename.toLowerCase())) {
        throw const FormatException(
          'Duplicate or mismatched legacy override filename',
        );
      }
      final entryPath = entry['entryPath'] as String;
      if (entryPath != 'comic_source/$filename') {
        throw const FormatException('Invalid legacy override entry path');
      }

      final contentSha = entry['contentSha256'] as String;
      if (!_validSha256.hasMatch(contentSha) ||
          contentSha != contentSha.toLowerCase()) {
        throw const FormatException('Invalid legacy override content SHA256');
      }
      final relativePath = entry['relativeFilePath'] as String;
      if (relativePath != 'files/$contentSha') {
        throw const FormatException('Invalid legacy override content path');
      }

      final type = entry['type'] as String;
      final expectedKey = entry['expectedKey'] as String;
      _validateOverrideKey(expectedKey);
      if (type == 'script') {
        if (!filename.endsWith('.js')) {
          throw const FormatException(
            'Script override must use a .js filename',
          );
        }
      } else if (type == 'session') {
        if (!filename.endsWith('.data') ||
            filename.substring(0, filename.length - 5) != expectedKey) {
          throw const FormatException(
            'Session override key or filename mismatch',
          );
        }
      } else {
        throw const FormatException('Invalid legacy override type');
      }

      final contentFile = File(p.join(archiveDir.path, relativePath));
      if (await FileSystemEntity.type(contentFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException(
          'Missing or invalid legacy override content',
        );
      }
      final contentLength = await contentFile.length();
      if (contentLength > _maxTextBytes) {
        throw const FormatException(
          'Legacy override content exceeds text limit',
        );
      }
      final contentBytes = await _readBoundedFile(
        contentFile,
        maxBytes: _maxTextBytes,
        failureMessage: 'Legacy override content exceeds text limit',
      );
      if (contentBytes.length > _maxTextBytes ||
          sha256.convert(contentBytes).toString() != contentSha) {
        throw const FormatException('Legacy override content hash mismatch');
      }

      final String content;
      try {
        content = utf8.decode(contentBytes, allowMalformed: false);
      } catch (_) {
        throw const FormatException(
          'Legacy override content is not valid UTF-8',
        );
      }
      if (type == 'script') {
        final probe = await ComicSourceParser.probeKey(content);
        if (!probe.isSuccess || probe.key != expectedKey) {
          throw const FormatException('Legacy override script key mismatch');
        }
      } else {
        final dynamic session;
        try {
          session = jsonDecode(content);
        } catch (_) {
          throw const FormatException('Invalid legacy override session JSON');
        }
        if (session is! Map) {
          throw const FormatException(
            'Legacy override session must be a JSON object',
          );
        }
      }
    }

    return Map<String, Object?>.from(decoded);
  }

  /// Registers a durable validated repair override for a legacy archive entry.
  /// Validates script key / session JSON before storing, persists an atomic manifest
  /// into `[overrideDirectory]/<archiveSha256>/`, and never touches original archives.
  static Future<bool> registerLegacyOverride({
    required Directory overrideDirectory,
    required String archiveSha256,
    required String entryFilename,
    required String replacementContent,
    String? expectedKey,
  }) async {
    final cleanSha = archiveSha256.trim().toLowerCase();
    if (!_validSha256.hasMatch(cleanSha)) {
      throw FormatException('Invalid archive SHA256: $archiveSha256');
    }

    if (entryFilename.contains('\u0000') ||
        entryFilename.contains(r'\') ||
        entryFilename.contains(':') ||
        entryFilename.startsWith('/') ||
        p.isAbsolute(entryFilename)) {
      throw FormatException('Illegal entry path: $entryFilename');
    }
    final parts = entryFilename.split('/');
    final String basename;
    if (parts.length == 1 && parts.single.isNotEmpty) {
      basename = parts.single;
    } else if (parts.length == 2 &&
        parts.first == 'comic_source' &&
        parts.last.isNotEmpty) {
      basename = parts.last;
    } else {
      throw FormatException('Entry must be in comic_source: $entryFilename');
    }
    _validateSafeBasename(basename);

    final contentBytes = utf8.encode(replacementContent);
    if (contentBytes.length > _maxTextBytes) {
      throw FormatException(
        'Replacement content exceeds text budget (${contentBytes.length} > $_maxTextBytes)',
      );
    }

    final String type;
    final String resolvedKey;
    if (basename.endsWith('.js')) {
      type = 'script';
      final probe = await ComicSourceParser.probeKey(replacementContent);
      if (!probe.isSuccess || probe.key == null) {
        throw FormatException(
          'Replacement script failed key probe: ${probe.failure?.name ?? "unknown"}',
        );
      }
      resolvedKey = probe.key!;
      _validateOverrideKey(resolvedKey);
      if (expectedKey != null && resolvedKey != expectedKey) {
        throw const FormatException('Probed key does not match expected key');
      }
    } else if (basename.endsWith('.data')) {
      type = 'session';
      final dynamic decoded;
      try {
        decoded = jsonDecode(replacementContent);
      } catch (_) {
        throw const FormatException('Invalid session JSON: malformed payload');
      }
      if (decoded is! Map) {
        throw const FormatException(
          'Replacement session must be a JSON object',
        );
      }
      resolvedKey = basename.substring(0, basename.length - 5);
      _validateOverrideKey(resolvedKey);
      if (expectedKey != null && resolvedKey != expectedKey) {
        throw const FormatException(
          'Session filename does not match expected key',
        );
      }
    } else {
      throw FormatException(
        'Disallowed legacy override file type: $entryFilename',
      );
    }

    final archiveDir = Directory(p.join(overrideDirectory.path, cleanSha));
    // Validate a prior commit before mutation. If this is the first repair,
    // atomically install a valid empty genesis pointer before writing blobs.
    final archiveType = await FileSystemEntity.type(
      archiveDir.path,
      followLinks: false,
    );
    var manifestMap = await _readValidatedOverrideManifest(
      archiveDir: archiveDir,
      archiveSha256: cleanSha,
      allowMissing: true,
    );
    if (archiveType == FileSystemEntityType.notFound) {
      await _createOverrideGenesis(
        overrideDirectory: overrideDirectory,
        archiveDirectory: archiveDir,
        archiveSha256: cleanSha,
      );
      manifestMap = await _readValidatedOverrideManifest(
        archiveDir: archiveDir,
        archiveSha256: cleanSha,
      );
    }

    final entries = Map<String, Object?>.from(manifestMap['entries'] as Map);
    if (entries.keys.any(
      (existing) =>
          existing.toLowerCase() == basename.toLowerCase() &&
          existing != basename,
    )) {
      throw const FormatException(
        'Legacy override filename collides with an existing entry',
      );
    }
    if (!entries.containsKey(basename) && entries.length >= _maxMembers) {
      throw const FormatException('Too many legacy override entries');
    }

    final contentSha = sha256.convert(contentBytes).toString();
    entries[basename] = {
      'filename': basename,
      'entryPath': 'comic_source/$basename',
      'contentSha256': contentSha,
      'type': type,
      'expectedKey': resolvedKey,
      'relativeFilePath': 'files/$contentSha',
    };
    manifestMap.remove('state');
    manifestMap['entries'] = entries;
    final manifestBytes = utf8.encode(jsonEncode(manifestMap));
    if (manifestBytes.length > _maxOverrideManifestBytes) {
      throw const FormatException(
        'Legacy override manifest exceeds size limit',
      );
    }

    final filesDir = Directory(p.join(archiveDir.path, 'files'));
    if (await FileSystemEntity.type(filesDir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Invalid legacy override files directory');
    }
    final targetFile = File(p.join(filesDir.path, contentSha));
    final targetType = await FileSystemEntity.type(
      targetFile.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      if (await targetFile.length() != contentBytes.length) {
        throw const FormatException('Immutable legacy override hash collision');
      }
      final existingBytes = await _readBoundedFile(
        targetFile,
        maxBytes: _maxTextBytes,
        failureMessage: 'Corrupted immutable legacy override file',
      );
      if (existingBytes.length != contentBytes.length ||
          sha256.convert(existingBytes).toString() != contentSha) {
        throw const FormatException('Corrupted immutable legacy override file');
      }
    } else if (targetType == FileSystemEntityType.notFound) {
      final stageTarget = File(
        p.join(
          filesDir.path,
          '.stage_${contentSha}_${DateTime.now().microsecondsSinceEpoch}_$pid',
        ),
      );
      try {
        await stageTarget.writeAsBytes(contentBytes, flush: true);
        final stagedBytes = await _readBoundedFile(
          stageTarget,
          maxBytes: _maxTextBytes,
          failureMessage: 'Staged override replacement exceeds text limit',
        );
        if (stagedBytes.length != contentBytes.length ||
            sha256.convert(stagedBytes).toString() != contentSha) {
          throw StateError('Staged override replacement verification failed');
        }
        final racedType = await FileSystemEntity.type(
          targetFile.path,
          followLinks: false,
        );
        if (racedType == FileSystemEntityType.notFound) {
          await stageTarget.rename(targetFile.path);
        } else {
          throw const FormatException(
            'Immutable legacy override file appeared during publication',
          );
        }
      } finally {
        try {
          if (await stageTarget.exists()) {
            await stageTarget.delete();
          }
        } catch (_) {}
      }
    } else {
      throw const FormatException('Invalid immutable legacy override file');
    }

    final manifestFile = File(p.join(archiveDir.path, 'manifest.json'));
    final stageManifest = File(
      p.join(
        archiveDir.path,
        '.stage_manifest_${DateTime.now().microsecondsSinceEpoch}_$pid.json',
      ),
    );
    try {
      await stageManifest.writeAsBytes(manifestBytes, flush: true);
      final stagedBytes = await _readBoundedFile(
        stageManifest,
        maxBytes: _maxOverrideManifestBytes,
        failureMessage: 'Staged manifest exceeds size limit',
      );
      if (stagedBytes.length != manifestBytes.length ||
          sha256.convert(stagedBytes).toString() !=
              sha256.convert(manifestBytes).toString()) {
        throw StateError('Staged manifest verification failed');
      }
      // Publish through the shared platform atomic primitive, preserving the
      // previous pointer if Windows denies replacement.
      await SourceFileMetadata.atomicReplace(stageManifest, manifestFile);
    } finally {
      try {
        if (await stageManifest.exists()) {
          await stageManifest.delete();
        }
      } catch (_) {}
    }

    return true;
  }

  Future<void> _applyLegacyOverrides(
    String archiveSha256,
    Directory extractDir,
  ) async {
    final overrideDir = legacyOverrideDirectory;
    if (overrideDir == null) return;

    final overrideDirType = await FileSystemEntity.type(
      overrideDir.path,
      followLinks: false,
    );
    if (overrideDirType == FileSystemEntityType.notFound) return;
    if (overrideDirType != FileSystemEntityType.directory) {
      throw const FormatException('Invalid legacy override directory');
    }

    final cleanSha = archiveSha256.trim().toLowerCase();
    if (!_validSha256.hasMatch(cleanSha)) {
      throw FormatException('Invalid archive SHA256: $archiveSha256');
    }

    final archiveDir = Directory(p.join(overrideDir.path, cleanSha));
    if (await FileSystemEntity.type(archiveDir.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final manifestMap = await _readValidatedOverrideManifest(
      archiveDir: archiveDir,
      archiveSha256: cleanSha,
    );
    final entries = manifestMap['entries'] as Map;
    // A genesis pointer records an initialized, empty override set only. The
    // original archive still flows through normal source validation/import.
    if (entries.isEmpty) return;
    final originalTargetDir = Directory(
      p.join(extractDir.path, 'comic_source'),
    );
    if (await FileSystemEntity.type(
          originalTargetDir.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'Override entries have no original comic_source directory',
      );
    }

    // Prove all destinations are original regular archive files before writing
    // any replacement into the isolated extraction tree.
    for (final entryValue in entries.values) {
      final entry = entryValue as Map<String, dynamic>;
      final filename = entry['filename'] as String;
      final originalFile = File(p.join(originalTargetDir.path, filename));
      if (await FileSystemEntity.type(originalFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FormatException(
          'Override entry not present as an original file: $filename',
        );
      }
    }

    for (final entryValue in entries.values) {
      final entry = entryValue as Map<String, dynamic>;
      final filename = entry['filename'] as String;
      final contentSha = entry['contentSha256'] as String;
      final relativePath = entry['relativeFilePath'] as String;
      final sourceFile = File(p.join(archiveDir.path, relativePath));
      if (await FileSystemEntity.type(sourceFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FormatException('Missing legacy override replacement: $filename');
      }
      final bytes = await _readBoundedFile(
        sourceFile,
        maxBytes: _maxTextBytes,
        failureMessage: 'Legacy override replacement exceeds text limit',
      );
      if (sha256.convert(bytes).toString() != contentSha) {
        throw FormatException(
          'Legacy override content changed after validation: $filename',
        );
      }

      final originalFile = File(p.join(originalTargetDir.path, filename));
      final stageFile = File(
        p.join(
          originalTargetDir.path,
          '.stage_overlay_${DateTime.now().microsecondsSinceEpoch}_$pid',
        ),
      );
      try {
        stageFile.writeAsBytesSync(bytes, flush: true);
        final stagedBytes = await _readBoundedFile(
          stageFile,
          maxBytes: _maxTextBytes,
          failureMessage: 'Staged legacy override exceeds text limit',
        );
        if (stagedBytes.length != bytes.length ||
            sha256.convert(stagedBytes).toString() != contentSha) {
          throw StateError('Staged legacy override verification failed');
        }
        stageFile.renameSync(originalFile.path);
      } finally {
        try {
          if (stageFile.existsSync()) {
            stageFile.deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  // Fail the entire migration, never truncate a business snapshot. ZIPs contain
  // databases/preferences/scripts, not comic image libraries.
  static const _maxDownloadBytes = 512 * 1024 * 1024;
  static const _maxExpandedBytes = 1024 * 1024 * 1024;
  static const _maxDatabaseBytes = 256 * 1024 * 1024;
  static const _maxTextBytes = 16 * 1024 * 1024;
  static const _maxOverrideManifestBytes = 16 * 1024 * 1024;
  static const _maxMembers = 10000;

  /// Reads and parses newest legacy snapshots into merge seeds.
  ///
  /// Throws on connection, download, verification, or schema reading errors so
  /// callers abort migration rather than falsely marking it finished.
  Future<List<LegacyMergeSeed>> readSeeds() async {
    final scratchExisted = scratch.existsSync();
    if (!scratchExisted) {
      scratch.createSync(recursive: true);
    }

    final runId =
        '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
    final executionDir = Directory(
      p.join(scratch.path, 'legacy_sync_run_$runId'),
    )..createSync(recursive: true);

    try {
      return await _executeReadSeeds(executionDir);
    } finally {
      try {
        if (executionDir.existsSync()) {
          await executionDir.delete(recursive: true);
        }
      } catch (error) {
        Log.warning(
          'LegacySyncReader',
          'Failed to clean scratch execution directory: $error',
        );
      }
      try {
        if (!scratchExisted &&
            scratch.existsSync() &&
            scratch.listSync().isEmpty) {
          scratch.deleteSync();
        }
      } catch (_) {}
    }
  }

  Future<List<LegacyMergeSeed>> _executeReadSeeds(Directory runDir) async {
    // Listing root directory throws on network failure, 401, or timeout
    // rather than returning an empty list to avoid prematurely concluding migration.
    final rawFiles = await client.readDir('/');

    final snapshots = <_LegacyRemoteSnapshot>[];
    for (final file in rawFiles) {
      final parsed = _LegacyRemoteSnapshot.tryParse(file);
      if (parsed != null) {
        snapshots.add(parsed);
      }
    }

    if (snapshots.isEmpty) {
      return <LegacyMergeSeed>[];
    }

    // Identify the highest version available
    int maxVersion = snapshots.first.version;
    for (final s in snapshots) {
      if (s.version > maxVersion) {
        maxVersion = s.version;
      }
    }

    // Process all snapshots matching maxVersion (including same-version collisions)
    final targetSnapshots = snapshots
        .where((s) => s.version == maxVersion)
        .toList();

    // Deterministic ordering: higher day first, then alphabetical by filename
    targetSnapshots.sort((a, b) {
      final dayCmp = b.day.compareTo(a.day);
      if (dayCmp != 0) return dayCmp;
      return a.name.compareTo(b.name);
    });

    final seeds = <LegacyMergeSeed>[];
    for (final snapshot in targetSnapshots) {
      final seed = await _downloadAndExtractSeed(snapshot, runDir);
      seeds.add(seed);
    }

    return seeds;
  }

  Future<LegacyMergeSeed> _downloadAndExtractSeed(
    _LegacyRemoteSnapshot snapshot,
    Directory runDir,
  ) async {
    final strongPropfindEtag = _strongEtag(snapshot.eTag);
    final partFile = File(
      p.join(
        runDir.path,
        '${snapshot.name}_${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );

    try {
      // 1. Stream GET with auth and optional strong If-Match
      final Response<ResponseBody> response;
      try {
        response = await client.c.req<ResponseBody>(
          client,
          'GET',
          snapshot.name,
          optionsHandler: (options) {
            options.responseType = ResponseType.stream;
            if (strongPropfindEtag != null) {
              options.headers = {'If-Match': strongPropfindEtag};
            }
          },
        );
      } catch (err) {
        throw StateError('GET failed for ${snapshot.name}: $err');
      }

      if (response.statusCode == 412) {
        throw StateError(
          'HTTP 412 Precondition Failed for ${snapshot.name} - remote snapshot modified',
        );
      }

      if (response.statusCode != 200 || response.data == null) {
        throw StateError(
          'Unexpected HTTP ${response.statusCode} for ${snapshot.name}',
        );
      }

      // Check GET response ETag vs PROPFIND ETag:
      // Strong PROPFIND ETag with missing GET ETag MUST NOT be rejected.
      // If GET returns a different ETag than PROPFIND, abort and throw.
      final getEtagHeader = response.headers.value('etag');
      final strongGetEtag = _strongEtag(getEtagHeader);
      if (strongPropfindEtag != null &&
          strongGetEtag != null &&
          strongPropfindEtag != strongGetEtag) {
        try {
          await response.data!.stream.drain<void>();
        } catch (_) {}
        throw StateError(
          'ETag mismatch on GET for ${snapshot.name}: '
          'propfind=$strongPropfindEtag vs get=$strongGetEtag',
        );
      }

      // Bound actual streamed bytes, even without a Content-Length header.
      final sink = partFile.openWrite();
      var downloadedBytes = 0;
      try {
        await for (final chunk in response.data!.stream) {
          downloadedBytes += chunk.length;
          if (downloadedBytes > _maxDownloadBytes) {
            throw FormatException('Legacy archive exceeds download limit');
          }
          sink.add(chunk);
          // Flush each network chunk to apply disk backpressure.
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
      if (downloadedBytes == 0) {
        throw FormatException('Downloaded archive ${snapshot.name} is empty');
      }

      // 2. Post-download directory metadata verification:
      // If file disappeared or directory metadata changed, do not commit.
      final freshList = await client.readDir('/');

      final freshTarget = freshList
          .map(_LegacyRemoteSnapshot.tryParse)
          .whereType<_LegacyRemoteSnapshot>()
          .where((s) => s.name == snapshot.name)
          .firstOrNull;

      if (freshTarget == null) {
        throw StateError(
          'Snapshot ${snapshot.name} disappeared from remote directory after download',
        );
      }

      if (freshTarget.day != snapshot.day ||
          freshTarget.version != snapshot.version) {
        throw StateError(
          'Snapshot ${snapshot.name} day or version changed after download',
        );
      }

      if (freshTarget.file.size != snapshot.file.size ||
          freshTarget.file.mTime != snapshot.file.mTime ||
          freshTarget.eTag != snapshot.eTag) {
        throw StateError(
          'Snapshot ${snapshot.name} directory metadata changed after download',
        );
      }

      final archiveSha256 = (await sha256.bind(partFile.openRead()).first)
          .toString()
          .toLowerCase();
      final extractDir = Directory(
        p.join(runDir.path, 'extract_$archiveSha256'),
      )..createSync(recursive: true);
      _extractVerifiedArchive(partFile, extractDir);
      await _applyLegacyOverrides(archiveSha256, extractDir);

      // 6. Convert isolated databases and files to SyncRecords
      SyncRecords favoriteRecords = {};
      final favDbFile = File(p.join(extractDir.path, 'local_favorite.db'));
      if (favDbFile.existsSync()) {
        final db = sqlite3.open(favDbFile.path);
        try {
          _ensureIsolatedFavoriteSchema(db);
          favoriteRecords = FavoriteSyncData.readSyncRecords(db);
        } finally {
          db.dispose();
        }
      }

      SyncRecords historyRecords = {};
      final histDbFile = File(p.join(extractDir.path, 'history.db'));
      if (histDbFile.existsSync()) {
        final db = sqlite3.open(histDbFile.path);
        try {
          HistorySyncData.ensureSchema(db);
          historyRecords = HistorySyncData.readSyncRecords(db);
        } finally {
          db.dispose();
        }
      }

      final preferenceSnapshot = await preferences.readLegacySnapshot(
        extractDir,
      );

      final combinedRecords = <String, Map<String, Object?>>{};
      combinedRecords.addAll(favoriteRecords);
      combinedRecords.addAll(historyRecords);
      combinedRecords.addAll(preferenceSnapshot.records);

      List<SyncSourceIssue> annotatedIssues = preferenceSnapshot.sourceIssues;
      if (preferenceSnapshot.sourceIssues.isNotEmpty) {
        Directory? backupDir = verifiedSourceBackupDirectory;
        if (backupDir == null) {
          try {
            if (App.dataPath.isNotEmpty) {
              backupDir = Directory(p.join(App.dataPath, 'source_backups'));
            }
          } catch (_) {}
        }
        if (backupDir == null) {
          throw StateError(
            'Cannot preserve invalid legacy source archive without durable backup directory',
          );
        }
        if (!backupDir.existsSync()) {
          backupDir.createSync(recursive: true);
        }

        final expectedLength = partFile.lengthSync();
        final backupFileName = '$archiveSha256.venera';
        final backupFile = File(p.join(backupDir.path, backupFileName));

        var existingValid = false;
        if (backupFile.existsSync()) {
          try {
            if (backupFile.lengthSync() == expectedLength) {
              final existingHash =
                  (await sha256.bind(backupFile.openRead()).first)
                      .toString()
                      .toLowerCase();
              if (existingHash == archiveSha256) {
                existingValid = true;
              }
            }
          } catch (_) {
            existingValid = false;
          }
        }

        if (!existingValid) {
          final stageFile = File(
            p.join(
              backupDir.path,
              '.stage_${archiveSha256}_${DateTime.now().microsecondsSinceEpoch}_$pid',
            ),
          );
          try {
            if (stageFile.existsSync()) {
              stageFile.deleteSync();
            }
            final outSink = stageFile.openSync(mode: FileMode.writeOnly);
            try {
              final inStream = partFile.openSync(mode: FileMode.read);
              try {
                final buffer = Uint8List(64 * 1024);
                while (true) {
                  final readBytes = inStream.readIntoSync(buffer);
                  if (readBytes == 0) break;
                  outSink.writeFromSync(buffer, 0, readBytes);
                }
              } finally {
                inStream.closeSync();
              }
              outSink.flushSync();
            } finally {
              outSink.closeSync();
            }

            if (stageFile.lengthSync() != expectedLength) {
              throw StateError(
                'Staged backup length mismatch for $backupFileName',
              );
            }
            final stagedHash = (await sha256.bind(stageFile.openRead()).first)
                .toString()
                .toLowerCase();
            if (stagedHash != archiveSha256) {
              throw StateError(
                'Staged backup SHA256 mismatch for $backupFileName: expected $archiveSha256, got $stagedHash',
              );
            }

            stageFile.renameSync(backupFile.path);
          } finally {
            try {
              if (stageFile.existsSync()) {
                stageFile.deleteSync();
              }
            } catch (_) {}
          }
        }

        if (!backupFile.existsSync() ||
            backupFile.lengthSync() != expectedLength) {
          throw StateError(
            'Failed to establish durable backup for $backupFileName',
          );
        }
        final finalHash = (await sha256.bind(backupFile.openRead()).first)
            .toString()
            .toLowerCase();
        if (finalHash != archiveSha256) {
          throw StateError(
            'Final durable backup hash verification failed for $backupFileName',
          );
        }

        annotatedIssues = preferenceSnapshot.sourceIssues
            .map(
              (issue) => issue.copyWith(
                backupPath: backupFile.path,
                archiveName: snapshot.name,
              ),
            )
            .toList();
      }

      return LegacyMergeSeed(
        archiveSha256,
        combinedRecords,
        sourceVariants: preferenceSnapshot.sourceVariants,
        sourceIssues: annotatedIssues,
        unavailableDomains: preferenceSnapshot.unavailableDomains,
      );
    } finally {
      try {
        if (partFile.existsSync()) {
          partFile.deleteSync();
        }
      } catch (_) {}
    }
  }

  static void _extractVerifiedArchive(File partFile, Directory extractDir) {
    final input = InputFileStream(partFile.path);
    try {
      final dirInfo = _locateAndValidateCentralDirectory(input);
      final dirStream = input.subset(
        position: dirInfo.centralDirectoryOffset,
        length: dirInfo.centralDirectorySize,
      );
      final headers = <ZipFileHeader>[];
      final maxAllowedHeaders = min(dirInfo.totalEntries, _maxMembers);

      while (!dirStream.isEOS) {
        if (headers.length >= maxAllowedHeaders) {
          throw const FormatException(
            'Too many central directory entries or declared limit exceeded',
          );
        }
        final startPos = dirStream.position;
        if (startPos + 46 > dirInfo.centralDirectorySize) {
          throw const FormatException(
            'Central directory header truncated before fixed fields',
          );
        }
        final sig = dirStream.readUint32();
        if (sig != ZipFileHeader.signature) {
          throw const FormatException(
            'Invalid central directory header signature',
          );
        }
        dirStream.setPosition(startPos + 28);
        final fnameLen = dirStream.readUint16();
        final extraLen = dirStream.readUint16();
        final commentLen = dirStream.readUint16();
        if (startPos + 46 + fnameLen + extraLen + commentLen >
            dirInfo.centralDirectorySize) {
          throw const FormatException(
            'Central directory header fields exceed central directory window',
          );
        }
        dirStream.setPosition(startPos + 4);

        final header = ZipFileHeader()..read(dirStream);
        headers.add(header);
      }

      if (headers.length != dirInfo.totalEntries || headers.isEmpty) {
        throw const FormatException(
          'Invalid or oversized legacy ZIP directory',
        );
      }

      final names = <String>{};
      var expandedBytes = 0;
      for (final header in headers) {
        if (header.diskNumberStart != 0 ||
            (header.generalPurposeBitFlag & 1) != 0 ||
            (header.compressionMethod != 0 &&
                header.compressionMethod != 8 &&
                header.compressionMethod != 12)) {
          throw const FormatException(
            'Inconsistent or unsupported legacy ZIP member',
          );
        }
        final fileType = (header.externalFileAttributes >> 16) & 0xf000;
        if (fileType != 0 && fileType != 0x8000 && fileType != 0x4000) {
          throw FormatException('Forbidden ZIP file type: ${header.filename}');
        }
        final name = header.filename.replaceAll('\\', '/');
        if (name.contains('..') ||
            name.contains(':') ||
            name.startsWith('/') ||
            p.isAbsolute(name) ||
            p.normalize(name).startsWith('..') ||
            !names.add(name.toLowerCase())) {
          throw FormatException('Forbidden or duplicate ZIP path: $name');
        }
        final isDirectory = name.endsWith('/');
        if (isDirectory) {
          if (name != 'comic_source/' ||
              header.uncompressedSize != 0 ||
              header.crc32 != 0) {
            throw FormatException('Disallowed ZIP directory: $name');
          }
        } else if (!_isAllowedArchiveFile(name)) {
          throw FormatException('Non-whitelisted ZIP file: $name');
        }
        final maxBytes = name.endsWith('.db')
            ? _maxDatabaseBytes
            : _maxTextBytes;
        expandedBytes += header.uncompressedSize;
        if (header.uncompressedSize < 0 ||
            header.uncompressedSize > maxBytes ||
            expandedBytes > _maxExpandedBytes) {
          throw FormatException('Legacy ZIP expansion limit exceeded: $name');
        }
      }

      final sortedHeaders = List<ZipFileHeader>.from(headers)
        ..sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));

      final verifiedMembers = <_VerifiedZipMember>[];
      var currentOffset = 0;
      for (var i = 0; i < sortedHeaders.length; i++) {
        final header = sortedHeaders[i];
        final nextBoundary = (i + 1 < sortedHeaders.length)
            ? sortedHeaders[i + 1].localHeaderOffset
            : dirInfo.centralDirectoryOffset;

        if (header.localHeaderOffset < currentOffset ||
            header.localHeaderOffset + 30 > nextBoundary ||
            header.localHeaderOffset + 30 > dirInfo.centralDirectoryOffset) {
          throw FormatException(
            'Invalid or out-of-bounds local header offset: ${header.filename}',
          );
        }

        final localHeaderStream = input.subset(
          position: header.localHeaderOffset,
          length: min(nextBoundary - header.localHeaderOffset, 65536 + 30),
        );
        final localSig = localHeaderStream.readUint32();
        if (localSig != 0x04034b50) {
          throw FormatException(
            'Invalid local header signature: ${header.filename}',
          );
        }

        localHeaderStream.readUint16(); // versionNeeded
        final localFlags = localHeaderStream.readUint16();
        final localMethod = localHeaderStream.readUint16();
        localHeaderStream.readUint16(); // localModTime
        localHeaderStream.readUint16(); // localModDate
        final localCrc = localHeaderStream.readUint32();
        final localCompSize = localHeaderStream.readUint32();
        final localUncompSize = localHeaderStream.readUint32();
        final fileNameLen = localHeaderStream.readUint16();
        final extraLen = localHeaderStream.readUint16();

        if (localFlags != header.generalPurposeBitFlag) {
          throw FormatException(
            'Flags mismatch between local and central header: ${header.filename}',
          );
        }
        if (localMethod != header.compressionMethod) {
          throw FormatException(
            'Compression method mismatch between local and central header: ${header.filename}',
          );
        }
        if ((localFlags & 1) != 0) {
          throw FormatException(
            'Encrypted ZIP entry unsupported: ${header.filename}',
          );
        }

        final headerSize = 30 + fileNameLen + extraLen;
        if (header.localHeaderOffset + headerSize > nextBoundary) {
          throw FormatException(
            'Local header exceeds entry boundary: ${header.filename}',
          );
        }

        if (localHeaderStream.length < fileNameLen) {
          throw FormatException(
            'Truncated local header filename: ${header.filename}',
          );
        }
        final localNameBytes = localHeaderStream
            .readBytes(fileNameLen)
            .toUint8List();
        final localName = utf8.decode(localNameBytes, allowMalformed: true);
        if (localName.replaceAll('\\', '/') !=
            header.filename.replaceAll('\\', '/')) {
          throw FormatException(
            'Filename mismatch between local and central header: $localName vs ${header.filename}',
          );
        }

        if (localHeaderStream.length < extraLen) {
          throw FormatException(
            'Truncated local header extra field: ${header.filename}',
          );
        }
        final localExtraBytes = localHeaderStream
            .readBytes(extraLen)
            .toUint8List();

        final dataOffset = header.localHeaderOffset + headerSize;
        if (header.compressedSize < 0) {
          throw FormatException(
            'Invalid negative compressed size: ${header.filename}',
          );
        }
        final dataEndOffset = dataOffset + header.compressedSize;
        if (dataEndOffset > nextBoundary) {
          throw FormatException(
            'Compressed data exceeds entry boundary: ${header.filename}',
          );
        }

        int entryEndOffset;
        if ((localFlags & 0x08) != 0) {
          if (localCrc != 0 && localCrc != header.crc32) {
            throw FormatException(
              'Local header CRC contradicts central header for ${header.filename}',
            );
          }
          if (localCompSize != 0 &&
              localCompSize != 0xffffffff &&
              localCompSize != header.compressedSize) {
            throw FormatException(
              'Local header compressed size contradicts central header for ${header.filename}',
            );
          }
          if (localUncompSize != 0 &&
              localUncompSize != 0xffffffff &&
              localUncompSize != header.uncompressedSize) {
            throw FormatException(
              'Local header uncompressed size contradicts central header for ${header.filename}',
            );
          }

          final descOffset = dataEndOffset;
          final availableDescBytes = nextBoundary - descOffset;
          if (availableDescBytes < 12) {
            throw FormatException(
              'Truncated data descriptor for ${header.filename}',
            );
          }

          final descStream = input.subset(
            position: descOffset,
            length: min(availableDescBytes, 24),
          );
          final descBytes = descStream.toUint8List();
          final descData = ByteData.sublistView(descBytes);

          final candidates = <int>[];

          bool isValidBoundary(int size) {
            final end = descOffset + size;
            if (end > nextBoundary) return false;
            final gap = nextBoundary - end;
            if (gap > 3) return false;
            if (gap > 0) {
              final pad = input
                  .subset(position: end, length: gap)
                  .toUint8List();
              if (pad.any((b) => b != 0)) return false;
            }
            if (nextBoundary < dirInfo.centralDirectoryOffset) {
              final nextSig = input
                  .subset(position: nextBoundary, length: 4)
                  .readUint32();
              if (nextSig != 0x04034b50) return false;
            } else if (nextBoundary == dirInfo.centralDirectoryOffset) {
              final nextSig = input
                  .subset(position: nextBoundary, length: 4)
                  .readUint32();
              if (nextSig != ZipFileHeader.signature) return false;
            }
            return true;
          }

          if (descBytes.length >= 24 &&
              descData.getUint32(0, Endian.little) == 0x08074b50 &&
              descData.getUint32(4, Endian.little) == header.crc32 &&
              descData.getUint64(8, Endian.little) == header.compressedSize &&
              descData.getUint64(16, Endian.little) ==
                  header.uncompressedSize &&
              isValidBoundary(24)) {
            candidates.add(24);
          }

          if (descBytes.length >= 16 &&
              descData.getUint32(0, Endian.little) == 0x08074b50 &&
              descData.getUint32(4, Endian.little) == header.crc32 &&
              descData.getUint32(8, Endian.little) == header.compressedSize &&
              descData.getUint32(12, Endian.little) ==
                  header.uncompressedSize &&
              isValidBoundary(16)) {
            candidates.add(16);
          }

          if (descBytes.length >= 20 &&
              descData.getUint32(0, Endian.little) == header.crc32 &&
              descData.getUint64(4, Endian.little) == header.compressedSize &&
              descData.getUint64(12, Endian.little) ==
                  header.uncompressedSize &&
              isValidBoundary(20)) {
            candidates.add(20);
          }

          if (descBytes.length >= 12 &&
              descData.getUint32(0, Endian.little) == header.crc32 &&
              descData.getUint32(4, Endian.little) == header.compressedSize &&
              descData.getUint32(8, Endian.little) == header.uncompressedSize &&
              isValidBoundary(12)) {
            candidates.add(12);
          }

          if (candidates.isEmpty) {
            throw FormatException(
              'Invalid, mismatched, or corrupted data descriptor for ${header.filename}',
            );
          }

          int selectedSize;
          if (candidates.length == 1) {
            selectedSize = candidates.first;
          } else {
            final exact = candidates
                .where((s) => descOffset + s == nextBoundary)
                .toList();
            final pool = exact.isNotEmpty ? exact : candidates;
            if (pool.contains(24)) {
              selectedSize = 24;
            } else if (pool.contains(16)) {
              selectedSize = 16;
            } else if (pool.contains(20)) {
              selectedSize = 20;
            } else {
              selectedSize = pool.first;
            }
          }

          entryEndOffset = descOffset + selectedSize;
        } else {
          if (localCrc != header.crc32) {
            throw FormatException(
              'CRC mismatch between local and central header: ${header.filename}',
            );
          }
          if (localCompSize != 0xffffffff &&
              localCompSize != header.compressedSize) {
            throw FormatException(
              'Compressed size mismatch between local and central header: ${header.filename}',
            );
          }
          if (localUncompSize != 0xffffffff &&
              localUncompSize != header.uncompressedSize) {
            throw FormatException(
              'Uncompressed size mismatch between local and central header: ${header.filename}',
            );
          }

          if (localCompSize == 0xffffffff || localUncompSize == 0xffffffff) {
            var extraPos = 0;
            var foundZip64 = false;
            int? localZip64Uncomp;
            int? localZip64Comp;
            final extraData = ByteData.sublistView(localExtraBytes);
            while (extraPos + 4 <= localExtraBytes.length) {
              final extraId = extraData.getUint16(extraPos, Endian.little);
              final extraBlockSize = extraData.getUint16(
                extraPos + 2,
                Endian.little,
              );
              extraPos += 4;
              if (extraPos + extraBlockSize > localExtraBytes.length) {
                throw FormatException(
                  'Malformed local extra field for ${header.filename}',
                );
              }
              if (extraId == 0x0001) {
                foundZip64 = true;
                var blockPos = extraPos;
                var remaining = extraBlockSize;
                if (localUncompSize == 0xffffffff) {
                  if (remaining < 8) {
                    throw FormatException(
                      'Truncated ZIP64 extra field for ${header.filename}',
                    );
                  }
                  localZip64Uncomp = extraData.getUint64(
                    blockPos,
                    Endian.little,
                  );
                  blockPos += 8;
                  remaining -= 8;
                }
                if (localCompSize == 0xffffffff) {
                  if (remaining < 8) {
                    throw FormatException(
                      'Truncated ZIP64 extra field for ${header.filename}',
                    );
                  }
                  localZip64Comp = extraData.getUint64(blockPos, Endian.little);
                  blockPos += 8;
                  remaining -= 8;
                }
                break;
              }
              extraPos += extraBlockSize;
            }
            if (!foundZip64) {
              throw FormatException(
                'Missing ZIP64 extra field for 0xffffffff size in ${header.filename}',
              );
            }
            if (localUncompSize == 0xffffffff &&
                localZip64Uncomp != header.uncompressedSize) {
              throw FormatException(
                'Local ZIP64 uncompressed size mismatch for ${header.filename}',
              );
            }
            if (localCompSize == 0xffffffff &&
                localZip64Comp != header.compressedSize) {
              throw FormatException(
                'Local ZIP64 compressed size mismatch for ${header.filename}',
              );
            }
          }

          entryEndOffset = dataEndOffset;
          final gap = nextBoundary - entryEndOffset;
          if (gap > 3) {
            throw FormatException(
              'Unexpected data between entry and next boundary: ${header.filename}',
            );
          }
          if (gap > 0) {
            final pad = input
                .subset(position: entryEndOffset, length: gap)
                .toUint8List();
            if (pad.any((b) => b != 0)) {
              throw FormatException(
                'Non-zero padding after entry: ${header.filename}',
              );
            }
          }
        }

        if (entryEndOffset > nextBoundary) {
          throw FormatException(
            'Entry exceeds boundary or overlaps next entry: ${header.filename}',
          );
        }

        currentOffset = entryEndOffset;
        verifiedMembers.add(
          _VerifiedZipMember(
            header: header,
            localHeaderOffset: header.localHeaderOffset,
            dataOffset: dataOffset,
            entryEndOffset: entryEndOffset,
          ),
        );
      }

      for (final member in verifiedMembers) {
        final header = member.header;
        final name = header.filename.replaceAll('\\', '/');
        final isDirectory = name.endsWith('/');
        final target = File(
          p.join(
            extractDir.path,
            isDirectory ? '.legacy_directory_check' : name,
          ),
        );
        target.parent.createSync(recursive: true);
        final output = _VerifiedLegacyOutput(
          target.path,
          header.uncompressedSize,
        );
        try {
          final compressed = input.subset(
            position: member.dataOffset,
            length: header.compressedSize,
          );
          switch (header.compressionMethod) {
            case 0:
              output.writeStream(compressed);
            case 8:
              final decoder = ZLibCodec(
                raw: true,
              ).decoder.startChunkedConversion(_LegacyInflateSink(output));
              while (!compressed.isEOS) {
                decoder.add(
                  compressed
                      .readBytes(min(1024, compressed.length))
                      .toUint8List(),
                );
              }
              decoder.close();
            case 12:
              BZip2Decoder().decodeStream(compressed, output);
          }
          if (output.length != header.uncompressedSize ||
              output.crc32 != header.crc32) {
            throw FormatException(
              'ZIP CRC32 or size mismatch: ${header.filename}',
            );
          }
        } finally {
          output.closeSync();
        }
        if (isDirectory) target.deleteSync();
      }
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Legacy ZIP extraction failed: $error');
    } finally {
      input.closeSync();
    }
  }

  static _ZipDirectoryInfo _locateAndValidateCentralDirectory(
    InputFileStream input,
  ) {
    final fileSize = input.length;
    if (fileSize < 22) {
      throw const FormatException('Legacy ZIP archive too small');
    }

    final tailStart = max(0, fileSize - 65557);
    final tail = input.subset(position: tailStart).toUint8List();
    final data = ByteData.sublistView(tail);

    for (var i = tail.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) != ZipDirectory.eocdSignature) {
        continue;
      }
      final commentLength = data.getUint16(i + 20, Endian.little);
      if (i + 22 + commentLength != tail.length) {
        continue;
      }

      final eocdOffset = tailStart + i;
      final diskNum = data.getUint16(i + 4, Endian.little);
      final diskStart = data.getUint16(i + 6, Endian.little);
      final countOnDisk = data.getUint16(i + 8, Endian.little);
      var count = data.getUint16(i + 10, Endian.little);
      var directorySize = data.getUint32(i + 12, Endian.little);
      var directoryOffset = data.getUint32(i + 16, Endian.little);
      var directoryBoundary = eocdOffset;

      // Check for ZIP64 EOCD Locator immediately preceding EOCD (20 bytes)
      final locatorPosition = eocdOffset - 20;
      if (locatorPosition >= 0) {
        final locator = input.subset(position: locatorPosition, length: 20);
        if (locator.readUint32() == ZipDirectory.zip64EocdLocatorSignature) {
          final zip64Disk = locator.readUint32();
          final zip64Offset = locator.readUint64();
          final totalDisks = locator.readUint32();
          if (zip64Disk != 0 || totalDisks != 1) {
            throw const FormatException('Multi-disk ZIP64 archive unsupported');
          }
          if (zip64Offset < 0 || zip64Offset + 56 > locatorPosition) {
            throw const FormatException('Invalid ZIP64 EOCD offset');
          }
          final zip64 = input.subset(position: zip64Offset, length: 56);
          if (zip64.readUint32() != ZipDirectory.zip64EocdSignature) {
            throw const FormatException('Invalid ZIP64 EOCD signature');
          }
          final recordSize = zip64.readUint64();
          if (recordSize < 44 ||
              zip64Offset + 12 + recordSize > locatorPosition) {
            throw const FormatException(
              'Invalid ZIP64 EOCD record size or out of bounds',
            );
          }
          zip64.readUint16(); // versionMadeBy
          zip64.readUint16(); // versionNeeded
          final z64Disk = zip64.readUint32();
          final z64DiskStart = zip64.readUint32();
          final z64EntriesDisk = zip64.readUint64();
          final z64EntriesTotal = zip64.readUint64();
          final z64DirSize = zip64.readUint64();
          final z64DirOffset = zip64.readUint64();

          if (z64Disk != 0 ||
              z64DiskStart != 0 ||
              z64EntriesDisk != z64EntriesTotal) {
            throw const FormatException('Multi-disk ZIP64 archive unsupported');
          }

          if (diskNum != 0xffff && diskNum != 0) {
            throw const FormatException(
              'Inconsistent disk number between ordinary and ZIP64 EOCD',
            );
          }
          if (diskStart != 0xffff && diskStart != 0) {
            throw const FormatException(
              'Inconsistent start disk between ordinary and ZIP64 EOCD',
            );
          }
          if (count != 0xffff && count != (z64EntriesTotal & 0xffff)) {
            throw const FormatException(
              'Inconsistent entry count between ordinary and ZIP64 EOCD',
            );
          }
          if (countOnDisk != 0xffff &&
              countOnDisk != (z64EntriesDisk & 0xffff)) {
            throw const FormatException(
              'Inconsistent on-disk entry count between ordinary and ZIP64 EOCD',
            );
          }
          if (directorySize != 0xffffffff &&
              directorySize != (z64DirSize & 0xffffffff)) {
            throw const FormatException(
              'Inconsistent directory size between ordinary and ZIP64 EOCD',
            );
          }
          if (directoryOffset != 0xffffffff &&
              directoryOffset != (z64DirOffset & 0xffffffff)) {
            throw const FormatException(
              'Inconsistent directory offset between ordinary and ZIP64 EOCD',
            );
          }

          count = z64EntriesTotal;
          directorySize = z64DirSize;
          directoryOffset = z64DirOffset;
          directoryBoundary = zip64Offset;
        } else if (count == 0xffff ||
            directorySize == 0xffffffff ||
            directoryOffset == 0xffffffff) {
          throw const FormatException(
            'Missing ZIP64 locator for ZIP64 archive',
          );
        } else if (diskNum != 0 || diskStart != 0 || countOnDisk != count) {
          throw const FormatException('Multi-disk ZIP archive unsupported');
        }
      } else {
        if (count == 0xffff ||
            directorySize == 0xffffffff ||
            directoryOffset == 0xffffffff) {
          throw const FormatException(
            'Missing ZIP64 locator for ZIP64 archive',
          );
        }
        if (diskNum != 0 || diskStart != 0 || countOnDisk != count) {
          throw const FormatException('Multi-disk ZIP archive unsupported');
        }
      }

      if (count <= 0 ||
          count > _maxMembers ||
          directorySize <= 0 ||
          directorySize > 8 * 1024 * 1024 ||
          directoryOffset < 0 ||
          directorySize < 0 ||
          directoryOffset + directorySize > directoryBoundary) {
        throw const FormatException(
          'Legacy ZIP directory exceeds resource limits',
        );
      }

      return _ZipDirectoryInfo(
        totalEntries: count,
        centralDirectorySize: directorySize,
        centralDirectoryOffset: directoryOffset,
        directoryBoundary: directoryBoundary,
      );
    }

    throw const FormatException('Invalid legacy ZIP end of directory');
  }

  /// Migrates missing columns on legacy folder tables in the isolated database
  /// so that older database schemas from past Venera versions read successfully.
  static void _ensureIsolatedFavoriteSchema(Database db) {
    FavoriteSyncData.ensureFolderMetadataTable(db);

    final tableRows = db.select(
      "SELECT name FROM sqlite_master WHERE type='table';",
    );
    for (final row in tableRows) {
      final name = row['name'] as String;
      if (isInternalFavoriteTable(name)) continue;

      final colRows = db.select('PRAGMA table_info("$name");');
      final existingCols = colRows
          .map((r) => (r['name'] as String).toLowerCase())
          .toSet();

      if (!existingCols.contains('display_order')) {
        db.execute(
          'ALTER TABLE "$name" ADD COLUMN display_order INT DEFAULT 0;',
        );
      }
      if (!existingCols.contains('last_update_time')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN last_update_time TEXT;');
      }
      if (!existingCols.contains('has_new_update')) {
        db.execute(
          'ALTER TABLE "$name" ADD COLUMN has_new_update INT DEFAULT 0;',
        );
      }
      if (!existingCols.contains('last_check_time')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN last_check_time INT;');
      }
      if (!existingCols.contains('translated_tags')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN translated_tags TEXT;');
      }
      if (!existingCols.contains('cover_path')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN cover_path TEXT;');
      }
      if (!existingCols.contains('author')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN author TEXT;');
      }
      if (!existingCols.contains('tags')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN tags TEXT;');
      }
      if (!existingCols.contains('time')) {
        db.execute('ALTER TABLE "$name" ADD COLUMN time TEXT;');
      }
    }
  }

  static bool _isAllowedArchiveFile(String normalizedName) {
    if (normalizedName == 'history.db' ||
        normalizedName == 'local_favorite.db' ||
        normalizedName == 'cookie.db' ||
        normalizedName == 'appdata.json' ||
        normalizedName == 'syncdata.json' ||
        normalizedName == 'comic_source/.sync_source_names.json') {
      return true;
    }
    if (normalizedName.startsWith('comic_source/')) {
      final remainder = normalizedName.substring('comic_source/'.length);
      if (!remainder.contains('/') &&
          (remainder.endsWith('.js') || remainder.endsWith('.data'))) {
        return true;
      }
    }
    return false;
  }

  /// Validates that an ETag is a syntactically valid strong entity tag (RFC 7232 section 2.3).
  ///
  /// Must not be weak (prefixed with `W/`) and must be enclosed in double quotes.
  static String? _strongEtag(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.startsWith('W/')) {
      return null;
    }
    if (trimmed.length >= 2 &&
        trimmed.startsWith('"') &&
        trimmed.endsWith('"')) {
      return trimmed;
    }
    return null;
  }
}

class _ZipDirectoryInfo {
  final int totalEntries;
  final int centralDirectorySize;
  final int centralDirectoryOffset;
  final int directoryBoundary;

  _ZipDirectoryInfo({
    required this.totalEntries,
    required this.centralDirectorySize,
    required this.centralDirectoryOffset,
    required this.directoryBoundary,
  });
}

class _VerifiedZipMember {
  final ZipFileHeader header;
  final int localHeaderOffset;
  final int dataOffset;
  final int entryEndOffset;

  _VerifiedZipMember({
    required this.header,
    required this.localHeaderOffset,
    required this.dataOffset,
    required this.entryEndOffset,
  });
}

/// Counts actual expanded bytes before disk writes, and hashes those same bytes.
class _VerifiedLegacyOutput extends OutputStream {
  _VerifiedLegacyOutput(String path, this.expectedSize)
    : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  final OutputFileStream _output;

  @override
  int get length => _output.length;

  @override
  void flush() => _output.flush();

  @override
  void closeSync() => _output.closeSync();

  @override
  void clear() => throw UnsupportedError('Cannot clear a verified ZIP output');

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);

  final int expectedSize;
  int _crc = 0xffffffff;
  int get crc32 => _crc ^ 0xffffffff;

  void _checkSize(int count) {
    if (count < 0 || length + count > expectedSize) {
      throw const FormatException(
        'ZIP output exceeds declared uncompressed size',
      );
    }
  }

  @override
  void writeByte(int value) {
    _checkSize(1);
    _crc = getCrc32Byte(_crc, value);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _checkSize(count);
    for (var i = 0; i < count; i++) {
      _crc = getCrc32Byte(_crc, bytes[i]);
    }
    _output.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(stream.readBytes(min(64 * 1024, stream.length)).toUint8List());
    }
  }
}

class _LegacyInflateSink implements Sink<List<int>> {
  _LegacyInflateSink(this.output);
  final _VerifiedLegacyOutput output;

  @override
  void add(List<int> data) => output.writeBytes(data);

  @override
  void close() => output.flush();
}
