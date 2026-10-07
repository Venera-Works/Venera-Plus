import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

/// Seed data produced by reading a legacy `.venera` remote snapshot archive.
class LegacyMergeSeed {
  final String id;
  final SyncRecords records;

  const LegacyMergeSeed(this.id, this.records);

  @override
  String toString() => 'LegacyMergeSeed(id: $id, records: ${records.length})';
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
  LegacySyncReader(this.client, this.scratch, {required this.preferences});

  final dav.Client client;
  final Directory scratch;
  final SyncPreferencesAdapter preferences;

  // Fail the entire migration, never truncate a business snapshot. ZIPs contain
  // databases/preferences/scripts, not comic image libraries.
  static const _maxDownloadBytes = 512 * 1024 * 1024;
  static const _maxExpandedBytes = 1024 * 1024 * 1024;
  static const _maxDatabaseBytes = 256 * 1024 * 1024;
  static const _maxTextBytes = 16 * 1024 * 1024;
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

      final preferenceRecords = await preferences.readLegacyRecords(extractDir);

      final combinedRecords = <String, Map<String, Object?>>{};
      combinedRecords.addAll(favoriteRecords);
      combinedRecords.addAll(historyRecords);
      combinedRecords.addAll(preferenceRecords);

      return LegacyMergeSeed(archiveSha256, combinedRecords);
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
      _checkZipDirectoryBudget(input);
      // archive 4.3.0 comments out ZipDecoder's verify:true CRC branch.
      // Read its lazy directory directly: ZipDecoder also eagerly decompresses
      // symlink payloads before callers can reject them.
      final directory = ZipDirectory()..read(input);
      if (directory.filePosition < 0 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0 ||
          directory.fileHeaders.length !=
              directory.totalCentralDirectoryEntries ||
          directory.fileHeaders.isEmpty ||
          directory.fileHeaders.length > _maxMembers) {
        throw const FormatException(
          'Invalid or oversized legacy ZIP directory',
        );
      }
      final names = <String>{};
      var expandedBytes = 0;
      for (final header in directory.fileHeaders) {
        final entry = header.file;
        if (entry == null ||
            entry.filename != header.filename ||
            entry.compressedSize != header.compressedSize ||
            entry.uncompressedSize != header.uncompressedSize ||
            entry.crc32 != header.crc32 ||
            entry.flags != header.generalPurposeBitFlag ||
            header.diskNumberStart != 0 ||
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
        final name = entry.filename.replaceAll('\\', '/');
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

      for (final header in directory.fileHeaders) {
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
          final compressed = header.file!.getStream(decompress: false);
          switch (header.compressionMethod) {
            case 0:
              output.writeStream(compressed);
            case 8:
              // archive's native decodeStream uses withCallback, accumulating
              // ALL output chunks. A direct sink enforces limits as they arrive.
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

  // Bound metadata before archive allocates member objects, including ZIP64.
  static void _checkZipDirectoryBudget(InputFileStream input) {
    final fileSize = input.length;
    final tailStart = max(0, fileSize - 65557);
    final tail = input.subset(position: tailStart).toUint8List();
    final data = ByteData.sublistView(tail);
    for (var i = tail.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) != ZipDirectory.eocdSignature ||
          i + 22 + data.getUint16(i + 20, Endian.little) != tail.length) {
        continue;
      }
      var count = data.getUint16(i + 10, Endian.little);
      var directorySize = data.getUint32(i + 12, Endian.little);
      var directoryOffset = data.getUint32(i + 16, Endian.little);
      if (count == 0xffff ||
          directorySize == 0xffffffff ||
          directoryOffset == 0xffffffff) {
        final locatorPosition = tailStart + i - 20;
        if (locatorPosition < 0) break;
        final locator = input.subset(position: locatorPosition, length: 20);
        if (locator.readUint32() != ZipDirectory.zip64EocdLocatorSignature)
          break;
        locator.readUint32();
        final zip64Offset = locator.readUint64();
        if (zip64Offset < 0 || zip64Offset + 56 > fileSize) break;
        final zip64 = input.subset(position: zip64Offset, length: 56);
        if (zip64.readUint32() != ZipDirectory.zip64EocdSignature) break;
        zip64.skip(28);
        count = zip64.readUint64();
        directorySize = zip64.readUint64();
        directoryOffset = zip64.readUint64();
      }
      if (count > _maxMembers ||
          directorySize > 8 * 1024 * 1024 ||
          directoryOffset < 0 ||
          directorySize < 0 ||
          directoryOffset + directorySize > tailStart + i) {
        throw const FormatException(
          'Legacy ZIP directory exceeds resource limits',
        );
      }
      input.reset();
      return;
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
