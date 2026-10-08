import 'dart:convert';
import 'dart:ffi';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/foundation/file_system.dart';

typedef _MoveFileExNative =
    Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32);
typedef _MoveFileExDart = int Function(Pointer<Uint16>, Pointer<Uint16>, int);
typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();
typedef _HeapAllocNative =
    Pointer<Void> Function(Pointer<Void>, Uint32, UintPtr);
typedef _HeapAllocDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

class _WindowsAtomicFileApi {
  final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  late final _GetProcessHeapDart _getProcessHeap = _kernel32
      .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
        'GetProcessHeap',
      );
  late final _HeapAllocDart _heapAlloc = _kernel32
      .lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
  late final _HeapFreeDart _heapFree = _kernel32
      .lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');
  late final _MoveFileExDart _moveFileEx = _kernel32
      .lookupFunction<_MoveFileExNative, _MoveFileExDart>('MoveFileExW');
  late final _GetLastErrorDart _getLastError = _kernel32
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

  void replace(String sourcePath, String targetPath) {
    final heap = _getProcessHeap();
    if (heap == nullptr) {
      throw const FileSystemException('Could not access Windows process heap');
    }
    final source = _nativePath(heap, _extendedWindowsPath(sourcePath));
    Pointer<Uint16> target = nullptr;
    try {
      target = _nativePath(heap, _extendedWindowsPath(targetPath));
      // MOVEFILE_REPLACE_EXISTING only. COPY_ALLOWED is intentionally absent.
      if (_moveFileEx(source, target, 0x1) == 0) {
        final code = _getLastError();
        throw FileSystemException(
          'Atomic source file replacement failed',
          targetPath,
          OSError('MoveFileExW failed', code),
        );
      }
    } finally {
      if (target != nullptr) _heapFree(heap, 0, target.cast<Void>());
      _heapFree(heap, 0, source.cast<Void>());
    }
  }

  String _extendedWindowsPath(String path) {
    final normalized = p.normalize(p.absolute(path)).replaceAll('/', r'\');
    if (normalized.startsWith(r'\\?\')) return normalized;
    if (normalized.startsWith(r'\\')) {
      return '\\\\?\\UNC\\${normalized.substring(2)}';
    }
    return '\\\\?\\$normalized';
  }

  Pointer<Uint16> _nativePath(Pointer<Void> heap, String path) {
    if (path.contains('\u0000')) {
      throw ArgumentError('File path contains a null character');
    }
    final units = path.codeUnits;
    final allocation = _heapAlloc(
      heap,
      0,
      (units.length + 1) * sizeOf<Uint16>(),
    );
    if (allocation == nullptr) {
      throw const FileSystemException('Could not allocate a Windows file path');
    }
    final pointer = allocation.cast<Uint16>();
    final output = pointer.asTypedList(units.length + 1);
    output.setRange(0, units.length, units);
    output[units.length] = 0;
    return pointer;
  }
}

/// Helper for managing comic source files and sidecar metadata (.sync_source_names.json).
class SourceFileMetadata {
  static final _WindowsAtomicFileApi _windowsAtomicFileApi =
      _WindowsAtomicFileApi();

  /// Atomically replaces [target] with the verified same-directory [staged] file.
  /// Windows uses MoveFileExW(REPLACE_EXISTING) without COPY_ALLOWED; POSIX uses
  /// the platform's atomic rename primitive. Locks and cross-directory moves fail.
  static Future<void> atomicReplace(
    File staged,
    File target, {
    void Function()? beforeCommit,
  }) async {
    final stagedPath = p.canonicalize(staged.path);
    final targetPath = p.canonicalize(target.path);
    if (stagedPath == targetPath ||
        !p.equals(p.dirname(stagedPath), p.dirname(targetPath))) {
      throw ArgumentError(
        'Atomic replacement requires distinct files in the same directory',
      );
    }
    if (!await staged.exists()) {
      throw FileSystemException(
        'Atomic replacement stage is missing',
        staged.path,
      );
    }
    beforeCommit?.call();
    if (Platform.isWindows) {
      _windowsAtomicFileApi.replace(staged.path, target.path);
    } else {
      await staged.rename(target.path);
    }
    if (await staged.exists() || !await target.exists()) {
      throw FileSystemException(
        'Atomic replacement did not commit',
        target.path,
      );
    }
  }

  /// Synchronous counterpart for no-await file commit sections.
  static void atomicReplaceSync(
    File staged,
    File target, {
    void Function()? beforeCommit,
  }) {
    final stagedPath = p.canonicalize(staged.path);
    final targetPath = p.canonicalize(target.path);
    if (stagedPath == targetPath ||
        !p.equals(p.dirname(stagedPath), p.dirname(targetPath))) {
      throw ArgumentError(
        'Atomic replacement requires distinct files in the same directory',
      );
    }
    if (!staged.existsSync()) {
      throw FileSystemException(
        'Atomic replacement stage is missing',
        staged.path,
      );
    }
    beforeCommit?.call();
    if (Platform.isWindows) {
      _windowsAtomicFileApi.replace(staged.path, target.path);
    } else {
      staged.renameSync(target.path);
    }
    if (staged.existsSync() || !target.existsSync()) {
      throw FileSystemException(
        'Atomic replacement did not commit',
        target.path,
      );
    }
  }

  static const String sidecarFileName = '.sync_source_names.json';

  static final RegExp _keyRegex = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static final RegExp _sha256Regex = RegExp(r'^[a-f0-9]{64}$');

  static bool isValidKey(String key) => _keyRegex.hasMatch(key);

  static void validateKey(String key) {
    if (!isValidKey(key)) {
      throw FormatException('Invalid comic source identity: $key');
    }
  }

  static void validateFileName(String filename) {
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.contains('/') ||
        filename.contains('\\') ||
        p.basename(filename) != filename) {
      throw FormatException('Invalid source filename: $filename');
    }
  }

  /// Maps a comic source key to its deterministic physical filename for sync.
  static String physicalName(String key) =>
      'sync_${sha256.convert(utf8.encode(key))}.js';

  /// Computes SHA-256 hex digest of source content.
  static String digest(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  /// Reads and parses the sidecar metadata from [directory].
  /// Returns empty map if file does not exist.
  /// Throws [FormatException] on corrupt or zero-byte metadata without valid backup.
  static Future<Map<String, Map<String, Object?>>> read(
    Directory directory,
  ) async {
    final sidecarFile = File(p.join(directory.path, sidecarFileName));
    final bakFile = File(p.join(directory.path, '$sidecarFileName.bak'));

    final hasSidecar = await sidecarFile.exists();
    if (!hasSidecar) {
      if (await bakFile.exists()) {
        throw const FormatException(
          'Source metadata primary is missing while a backup exists',
        );
      }
      return {};
    }
    if (await sidecarFile.length() == 0) {
      throw const FormatException('Empty source metadata primary');
    }
    final decoded = jsonDecode(await sidecarFile.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Source filename metadata must be an object');
    }

    final result = <String, Map<String, Object?>>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          value is! Map ||
          value['filename'] is! String ||
          value['revisions'] is! Map) {
        throw const FormatException('Invalid source filename metadata entry');
      }

      validateKey(key);
      validateFileName(value['filename'] as String);

      final revisions = <String, String>{};
      for (final revEntry in (value['revisions'] as Map).entries) {
        final revKey = revEntry.key;
        final revVal = revEntry.value;
        if (revKey is! String ||
            !_sha256Regex.hasMatch(revKey) ||
            revVal is! String) {
          throw const FormatException('Invalid source filename revision');
        }
        validateFileName(revVal);
        revisions[revKey] = revVal;
      }

      final files = <String, String>{};
      if (value.containsKey('files')) {
        final rawFiles = value['files'];
        if (rawFiles is! Map) {
          throw const FormatException(
            'Source physical-file evidence must be an object',
          );
        }
        for (final fileEntry in rawFiles.entries) {
          if (fileEntry.key is! String ||
              fileEntry.value is! String ||
              !_sha256Regex.hasMatch(fileEntry.value as String)) {
            throw const FormatException(
              'Invalid source physical-file evidence',
            );
          }
          validateFileName(fileEntry.key as String);
          files[fileEntry.key as String] = fileEntry.value as String;
        }
      }

      final aliases = <String>[];
      if (value.containsKey('aliases')) {
        final rawAliases = value['aliases'];
        if (rawAliases is! List) {
          throw const FormatException('Source aliases must be a list');
        }
        for (final alias in rawAliases) {
          if (alias is! String || alias.isEmpty) {
            throw const FormatException('Invalid source alias');
          }
          validateFileName(alias);
          if (!aliases.contains(alias)) aliases.add(alias);
        }
      }

      final publicationId = value['publicationId'];
      if (value.containsKey('publicationId') &&
          (publicationId is! String || publicationId.isEmpty)) {
        throw const FormatException('Invalid source publicationId');
      }

      result[key] = {
        'filename': value['filename'],
        'revisions': revisions,
        if (files.isNotEmpty) 'files': files,
        if (aliases.isNotEmpty) 'aliases': aliases,
        if (publicationId != null) 'publicationId': publicationId,
      };
    }
    return result;
  }

  /// Returns the exact validated primary sidecar bytes, or null if no primary exists.
  static Future<String?> readValidatedSnapshot(Directory directory) async {
    await read(directory);
    final sidecarFile = File(p.join(directory.path, sidecarFileName));
    if (!await sidecarFile.exists()) return null;
    return sidecarFile.readAsString();
  }

  /// Restores a previously validated metadata snapshot only while the current
  /// primary still has [expectedCurrentDigest]. The existing `.bak` is untouched.
  static Future<void> restoreSnapshot(
    Directory directory, {
    required String? originalContent,
    required String? expectedCurrentDigest,
    void Function()? beforeCommit,
  }) async {
    if (!await directory.exists()) {
      throw const FileSystemException('Source directory is unavailable');
    }
    final sidecarFile = File(p.join(directory.path, sidecarFileName));
    final originalBytes = originalContent == null
        ? null
        : utf8.encode(originalContent);
    final originalDigest = originalContent == null
        ? null
        : sha256.convert(originalBytes!).toString();
    if (originalContent != null) {
      final validationDir = Directory(
        p.join(
          directory.path,
          '.metadata_restore_validate_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        beforeCommit?.call();
        await validationDir.create();
        await File(
          p.join(validationDir.path, sidecarFileName),
        ).writeAsBytes(originalBytes!, flush: true);
        await read(validationDir);
      } finally {
        await validationDir.deleteIgnoreError(recursive: true);
      }
    }

    if (await _primaryDigest(sidecarFile) != expectedCurrentDigest) {
      throw StateError('Source metadata changed before rollback');
    }
    if (originalContent == null) {
      if (expectedCurrentDigest == null) return;
      beforeCommit?.call();
      if (_primaryDigestSync(sidecarFile) != expectedCurrentDigest) {
        throw StateError('Source metadata changed before rollback');
      }
      sidecarFile.deleteSync();
      return;
    }

    final tmpFile = File(
      p.join(
        directory.path,
        '.$sidecarFileName.restore_${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      beforeCommit?.call();
      await tmpFile.writeAsBytes(originalBytes!, flush: true);
      if (sha256.convert(await tmpFile.readAsBytes()).toString() !=
          originalDigest) {
        throw const FileSystemException(
          'Restored source metadata failed verification',
        );
      }
      await atomicReplace(
        tmpFile,
        sidecarFile,
        beforeCommit: () {
          beforeCommit?.call();
          if (_primaryDigestSync(sidecarFile) != expectedCurrentDigest) {
            throw StateError('Source metadata changed before rollback');
          }
        },
      );
    } finally {
      await tmpFile.deleteIgnoreError();
    }
  }

  /// Records validated file evidence for [key] in the sidecar metadata of [directory].
  /// The physical file must already contain the exact validated [content].
  /// Existing corrupt metadata is never overwritten or replaced by a stale backup.
  static Future<void> recordValidated(
    Directory directory, {
    required String key,
    required String filename,
    required String content,
    String? originFilename,
    String? publicationId,
    String? expectedMetadataDigest,
    void Function()? beforeCommit,
  }) async {
    validateKey(key);
    validateFileName(filename);
    if (originFilename != null && originFilename.isNotEmpty) {
      validateFileName(originFilename);
    }

    if (!await directory.exists()) {
      beforeCommit?.call();
      await directory.create(recursive: true);
    }

    final sidecarFile = File(p.join(directory.path, sidecarFileName));
    final bakFile = File(p.join(directory.path, '$sidecarFileName.bak'));
    final physicalFile = File(p.join(directory.path, filename));
    final originalBakDigest = await _primaryDigest(bakFile);
    final expectedContentDigest = digest(content);
    final expectedContentBytes = utf8.encode(content);
    if (!await physicalFile.exists() ||
        digest(utf8.decode(await physicalFile.readAsBytes())) !=
            expectedContentDigest) {
      throw const FileSystemException(
        'Validated source file is missing or its bytes changed',
      );
    }
    final physicalStat = await physicalFile.stat();

    List<int>? originalSidecarBytes;
    if (await sidecarFile.exists()) {
      originalSidecarBytes = await sidecarFile.readAsBytes();
    }
    final originalSidecarDigest = originalSidecarBytes == null
        ? null
        : sha256.convert(originalSidecarBytes).toString();
    if (expectedMetadataDigest != null &&
        originalSidecarDigest != expectedMetadataDigest) {
      throw StateError('Source metadata changed since it was inspected');
    }
    final current = await read(directory);
    if (await _primaryDigest(sidecarFile) != originalSidecarDigest) {
      throw StateError('Source metadata changed while it was inspected');
    }

    final existing = current[key] ?? <String, Object?>{};
    final logicalFilename =
        originFilename ?? existing['filename'] as String? ?? filename;
    final revisions = <String, String>{
      if (existing['revisions'] is Map)
        for (final e in (existing['revisions'] as Map).entries)
          e.key as String: e.value as String,
    };
    revisions[expectedContentDigest] = logicalFilename;

    final files = <String, String>{
      if (existing['files'] is Map)
        for (final e in (existing['files'] as Map).entries)
          e.key as String: e.value as String,
    };
    files[filename] = expectedContentDigest;

    final aliases = <String>[
      if (existing['aliases'] is List)
        ...(existing['aliases'] as List).cast<String>(),
    ];
    for (final alias in [
      filename,
      if (originFilename != null) originFilename,
    ]) {
      if (alias.isNotEmpty && !aliases.contains(alias)) aliases.add(alias);
    }

    final resolvedPublicationId =
        publicationId ?? (existing['publicationId'] as String?);
    current[key] = {
      'filename': logicalFilename,
      'revisions': revisions,
      'files': files,
      'aliases': aliases,
      if (resolvedPublicationId != null) 'publicationId': resolvedPublicationId,
    };

    final jsonBytes = utf8.encode(jsonEncode(current));
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tmpFile = File(
      p.join(directory.path, '.$sidecarFileName.$stamp.tmp'),
    );
    final tmpBak = File(p.join(directory.path, '.$sidecarFileName.$stamp.bak'));

    try {
      beforeCommit?.call();
      await tmpFile.writeAsBytes(jsonBytes, flush: true);
      if (sha256.convert(await tmpFile.readAsBytes()).toString() !=
          sha256.convert(jsonBytes).toString()) {
        throw const FileSystemException(
          'Staged source metadata verification failed',
        );
      }

      if (originalSidecarBytes != null) {
        if (await _primaryDigest(sidecarFile) != originalSidecarDigest) {
          throw StateError('Source metadata changed before backup');
        }
        beforeCommit?.call();
        await tmpBak.writeAsBytes(originalSidecarBytes, flush: true);
        if (sha256.convert(await tmpBak.readAsBytes()).toString() !=
            originalSidecarDigest) {
          throw const FileSystemException(
            'Source metadata backup verification failed',
          );
        }
        if (await _primaryDigest(sidecarFile) != originalSidecarDigest) {
          throw StateError('Source metadata changed before backup commit');
        }
        await atomicReplace(
          tmpBak,
          bakFile,
          beforeCommit: () {
            beforeCommit?.call();
            if (_primaryDigestSync(sidecarFile) != originalSidecarDigest ||
                _primaryDigestSync(bakFile) != originalBakDigest ||
                _primaryDigestSync(physicalFile) != expectedContentDigest ||
                physicalFile.statSync().size != physicalStat.size ||
                physicalFile.statSync().modified != physicalStat.modified) {
              throw StateError('Source files changed before metadata backup');
            }
          },
        );
      }

      if (await _primaryDigest(sidecarFile) != originalSidecarDigest) {
        throw StateError('Source metadata changed before commit');
      }
      if (!await physicalFile.exists() ||
          sha256.convert(await physicalFile.readAsBytes()).toString() !=
              sha256.convert(expectedContentBytes).toString()) {
        throw StateError(
          'Validated source file changed before metadata commit',
        );
      }
      await atomicReplace(
        tmpFile,
        sidecarFile,
        beforeCommit: () {
          beforeCommit?.call();
          final expectedBackupDigest = originalSidecarBytes == null
              ? originalBakDigest
              : originalSidecarDigest;
          if (_primaryDigestSync(sidecarFile) != originalSidecarDigest ||
              _primaryDigestSync(bakFile) != expectedBackupDigest ||
              _primaryDigestSync(physicalFile) != expectedContentDigest ||
              physicalFile.statSync().size != physicalStat.size ||
              physicalFile.statSync().modified != physicalStat.modified) {
            throw StateError('Source files changed before metadata commit');
          }
        },
      );
    } finally {
      await tmpFile.deleteIgnoreError();
      await tmpBak.deleteIgnoreError();
    }
  }

  static Future<String?> _primaryDigest(File sidecarFile) async {
    if (!await sidecarFile.exists()) return null;
    return sha256.convert(await sidecarFile.readAsBytes()).toString();
  }

  static String? _primaryDigestSync(File file) {
    if (!file.existsSync()) return null;
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  static bool bannedAlias(String name) =>
      name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\');
}

/// Represents a stage in the publication journal.
enum SourcePublicationStage { staged, renamed }

/// Durable publication journal entry to guarantee crash consistency and recoverability.
class SourcePublicationJournalEntry {
  final String publicationId;
  final String key;
  final String targetPath;
  final String stagePath;
  final String backupPath;
  final String? sessionBackupPath;
  final String? originalDigest;
  final String newDigest;
  final String? originalSessionDigest;
  final String? newSessionDigest;
  final bool hadOriginalSession;
  final bool? sessionWriteExpected;
  final Map<String, Object?>? originalPages;
  final Map<String, Object?>? newPages;
  final bool? hadOriginalOrigin;
  final Map<String, Object?>? originalOrigin;
  final bool? originChanges;
  final Map<String, Object?>? newOrigin;
  final SourcePublicationStage stage;
  final DateTime timestamp;
  const SourcePublicationJournalEntry({
    required this.publicationId,
    required this.key,
    required this.targetPath,
    required this.stagePath,
    required this.backupPath,
    this.sessionBackupPath,
    this.originalDigest,
    required this.newDigest,
    this.originalSessionDigest,
    this.newSessionDigest,
    this.hadOriginalSession = false,
    this.sessionWriteExpected,
    this.originalPages,
    this.newPages,
    this.hadOriginalOrigin,
    this.originalOrigin,
    this.originChanges,
    this.newOrigin,
    required this.stage,
    required this.timestamp,
  });

  Map<String, Object?> toJson() => {
    'publicationId': publicationId,
    'key': key,
    'targetPath': targetPath,
    'stagePath': stagePath,
    'backupPath': backupPath,
    if (sessionBackupPath != null) 'sessionBackupPath': sessionBackupPath,
    if (originalDigest != null) 'originalDigest': originalDigest,
    'newDigest': newDigest,
    if (originalSessionDigest != null)
      'originalSessionDigest': originalSessionDigest,
    if (newSessionDigest != null) 'newSessionDigest': newSessionDigest,
    'hadOriginalSession': hadOriginalSession,
    if (sessionWriteExpected != null)
      'sessionWriteExpected': sessionWriteExpected,
    if (originalPages != null) 'originalPages': originalPages,
    if (newPages != null) 'newPages': newPages,
    if (hadOriginalOrigin != null) ...{
      'hadOriginalOrigin': hadOriginalOrigin,
      'originalOrigin': originalOrigin,
    },
    if (originChanges != null) ...{
      'originChanges': originChanges,
      'newOrigin': newOrigin,
    },
    'stage': stage.name,
    'timestamp': timestamp.toIso8601String(),
  };
  static const Set<String> _pageKeys = {
    'explore_pages',
    'categories',
    'favorites',
    'searchSources',
  };

  static Map<String, Object?>? _parsePageSnapshot(Object? value, String field) {
    if (value is! Map) {
      throw FormatException('$field must be an object');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String || !_pageKeys.contains(entry.key as String)) {
        throw FormatException('Invalid key in $field');
      }
      final page = entry.value;
      if (page != null &&
          (page is! List || page.any((item) => item is! String))) {
        throw FormatException('Invalid page list in $field');
      }
      result[entry.key as String] = page == null
          ? null
          : List<String>.from(page as List);
    }
    return result;
  }

  static Map<String, Object?>? _parseOriginSnapshot(
    Object? value,
    String field,
  ) {
    if (value == null) return null;
    if (value is! Map) {
      throw FormatException('$field must be an object or null');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String || !_isJsonValue(entry.value)) {
        throw FormatException('Invalid JSON value in $field');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static bool _isJsonValue(Object? value) {
    if (value == null || value is String || value is bool) return true;
    if (value is num) return value.isFinite;
    if (value is List) return value.every(_isJsonValue);
    if (value is Map) {
      return value.entries.every(
        (entry) => entry.key is String && _isJsonValue(entry.value),
      );
    }
    return false;
  }

  factory SourcePublicationJournalEntry.fromJson(
    Map<String, Object?> json,
    Directory expectedDirectory,
  ) {
    final publicationId = json['publicationId'];
    if (publicationId is! String || publicationId.isEmpty) {
      throw const FormatException(
        'Invalid or missing publicationId in journal',
      );
    }

    final key = json['key'];
    if (key is! String) {
      throw const FormatException('Invalid or missing key in journal');
    }
    SourceFileMetadata.validateKey(key);

    String? readOptionalDigest(String field) {
      final value = json[field];
      if (value != null &&
          (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value))) {
        throw FormatException('Invalid $field format in journal');
      }
      return value as String?;
    }

    final originalDigest = readOptionalDigest('originalDigest');
    final newDigest = json['newDigest'];
    if (newDigest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(newDigest)) {
      throw const FormatException('Invalid newDigest format in journal');
    }
    final originalSessionDigest = readOptionalDigest('originalSessionDigest');
    final newSessionDigest = readOptionalDigest('newSessionDigest');

    final rawHadOriginalSession = json['hadOriginalSession'];
    if (rawHadOriginalSession != null && rawHadOriginalSession is! bool) {
      throw const FormatException('Invalid hadOriginalSession in journal');
    }
    final hadOriginalSession = rawHadOriginalSession as bool? ?? false;
    final rawSessionWriteExpected = json['sessionWriteExpected'];
    if (rawSessionWriteExpected != null && rawSessionWriteExpected is! bool) {
      throw const FormatException('Invalid sessionWriteExpected in journal');
    }
    final sessionWriteExpected = rawSessionWriteExpected as bool?;

    final originalPages = json.containsKey('originalPages')
        ? _parsePageSnapshot(json['originalPages'], 'originalPages')
        : null;
    final newPages = json.containsKey('newPages')
        ? _parsePageSnapshot(json['newPages'], 'newPages')
        : null;

    bool? hadOriginalOrigin;
    Map<String, Object?>? originalOrigin;
    if (json.containsKey('hadOriginalOrigin')) {
      final rawHadOriginalOrigin = json['hadOriginalOrigin'];
      if (rawHadOriginalOrigin is! bool ||
          !json.containsKey('originalOrigin')) {
        throw const FormatException(
          'Invalid original origin snapshot in journal',
        );
      }
      hadOriginalOrigin = rawHadOriginalOrigin;
      originalOrigin = _parseOriginSnapshot(
        json['originalOrigin'],
        'originalOrigin',
      );
      if (!hadOriginalOrigin && originalOrigin != null) {
        throw const FormatException('Absent original origin has a value');
      }
    } else if (json.containsKey('originalOrigin')) {
      throw const FormatException('Missing hadOriginalOrigin in journal');
    }

    bool? originChanges;
    Map<String, Object?>? newOrigin;
    if (json.containsKey('originChanges')) {
      final rawOriginChanges = json['originChanges'];
      if (rawOriginChanges is! bool || !json.containsKey('newOrigin')) {
        throw const FormatException('Invalid new origin snapshot in journal');
      }
      originChanges = rawOriginChanges;
      newOrigin = _parseOriginSnapshot(json['newOrigin'], 'newOrigin');
    } else if (json.containsKey('newOrigin')) {
      throw const FormatException('Missing originChanges in journal');
    }

    final targetPath = json['targetPath'];
    final stagePath = json['stagePath'];
    final backupPath = json['backupPath'];
    final rawSessionBackupPath = json['sessionBackupPath'];
    if (rawSessionBackupPath != null && rawSessionBackupPath is! String) {
      throw const FormatException('Invalid sessionBackupPath in journal');
    }
    final sessionBackupPath = rawSessionBackupPath as String?;

    if (targetPath is! String ||
        stagePath is! String ||
        backupPath is! String) {
      throw const FormatException('Missing path fields in journal');
    }

    // Constrain paths strictly to expectedDirectory and exact sibling patterns
    final expCanonical = p.canonicalize(expectedDirectory.path);
    final targetCanonical = p.canonicalize(targetPath);
    if (p.dirname(targetCanonical) != expCanonical ||
        !p.basename(targetCanonical).endsWith('.js')) {
      throw const FormatException(
        'targetPath is not contained in source directory',
      );
    }
    final stageCanonical = p.canonicalize(stagePath);
    final isLegacyStage = stageCanonical == '$targetCanonical.stage';
    final isUniqueStage =
        stageCanonical == '$targetCanonical.$publicationId.stage';
    if (!isLegacyStage && !isUniqueStage) {
      throw const FormatException('stagePath must be targetPath.stage sibling');
    }

    final backupCanonical = p.canonicalize(backupPath);
    final isLegacyBackup = backupCanonical == '$targetCanonical.bak';
    final isUniqueBackup =
        backupCanonical == '$targetCanonical.$publicationId.bak';
    if (!isLegacyBackup && !isUniqueBackup) {
      throw const FormatException('backupPath must be targetPath.bak sibling');
    }

    if (sessionBackupPath != null) {
      final sessCanonical = p.canonicalize(sessionBackupPath);
      final legacySessBak = p.canonicalize(
        p.join(expCanonical, '$key.data.bak'),
      );
      final uniqueSessBak = p.canonicalize(
        p.join(expCanonical, '$key.data.$publicationId.bak'),
      );
      if (sessCanonical != legacySessBak && sessCanonical != uniqueSessBak) {
        throw const FormatException(
          'sessionBackupPath must be <key>.data.bak sibling',
        );
      }
    }

    final stageName = json['stage'];
    final timestampStr = json['timestamp'];
    if (stageName is! String || timestampStr is! String) {
      throw const FormatException('Missing stage or timestamp in journal');
    }

    final stage = SourcePublicationStage.values.firstWhere(
      (s) => s.name == stageName,
      orElse: () => throw FormatException('Invalid journal stage: $stageName'),
    );
    final timestamp = DateTime.tryParse(timestampStr);
    if (timestamp == null) {
      throw const FormatException('Invalid timestamp in journal');
    }

    return SourcePublicationJournalEntry(
      publicationId: publicationId,
      key: key,
      targetPath: targetPath,
      stagePath: stagePath,
      backupPath: backupPath,
      sessionBackupPath: sessionBackupPath,
      originalDigest: originalDigest,
      newDigest: newDigest,
      originalSessionDigest: originalSessionDigest,
      newSessionDigest: newSessionDigest,
      hadOriginalSession: hadOriginalSession,
      sessionWriteExpected: sessionWriteExpected,
      originalPages: originalPages,
      newPages: newPages,
      hadOriginalOrigin: hadOriginalOrigin,
      originalOrigin: originalOrigin,
      originChanges: originChanges,
      newOrigin: newOrigin,
      stage: stage,
      timestamp: timestamp,
    );
  }
}

/// Manages the durable publication journal file in a comic source directory.
class SourcePublicationJournal {
  static const String journalFileName = '.publication_journal.json';

  final Directory directory;

  SourcePublicationJournal(this.directory);

  File get _journalFile => File(p.join(directory.path, journalFileName));
  File get _tmpFile => File(p.join(directory.path, '$journalFileName.tmp'));

  Future<SourcePublicationJournalEntry?> read() async {
    if (!await _journalFile.exists()) return null;
    final length = await _journalFile.length();
    if (length == 0) {
      throw const FormatException('Empty journal file is corrupted');
    }
    final raw = await _journalFile.readAsString();
    if (raw.trim().isEmpty) {
      throw const FormatException('Empty journal file is corrupted');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Publication journal must be a JSON object');
    }
    return SourcePublicationJournalEntry.fromJson(
      Map<String, Object?>.from(decoded),
      directory,
    );
  }

  Future<void> record(SourcePublicationJournalEntry entry) async {
    final jsonStr = jsonEncode(entry.toJson());
    await _tmpFile.writeAsString(jsonStr, flush: true);
    // Direct same-filesystem rename without deleting _journalFile beforehand
    await SourceFileMetadata.atomicReplace(_tmpFile, _journalFile);
  }

  Future<void> updateStage(SourcePublicationStage newStage) async {
    final current = await read();
    if (current == null) return;
    final updated = SourcePublicationJournalEntry(
      publicationId: current.publicationId,
      key: current.key,
      targetPath: current.targetPath,
      stagePath: current.stagePath,
      backupPath: current.backupPath,
      sessionBackupPath: current.sessionBackupPath,
      originalDigest: current.originalDigest,
      newDigest: current.newDigest,
      originalSessionDigest: current.originalSessionDigest,
      newSessionDigest: current.newSessionDigest,
      hadOriginalSession: current.hadOriginalSession,
      sessionWriteExpected: current.sessionWriteExpected,
      originalPages: current.originalPages,
      newPages: current.newPages,
      hadOriginalOrigin: current.hadOriginalOrigin,
      originalOrigin: current.originalOrigin,
      originChanges: current.originChanges,
      newOrigin: current.newOrigin,
      stage: newStage,
      timestamp: DateTime.now(),
    );
    await record(updated);
  }

  Future<void> clear() async {
    await _journalFile.deleteIgnoreError();
    await _tmpFile.deleteIgnoreError();
  }
}
