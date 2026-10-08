import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' as dav;

import 'merge_engine.dart';
import 'merge_snapshot.dart';
import 'sync_device_name.dart';

/// Helper to determine whether an HTTP ETag is a legitimate quoted strong validator.
///
/// In HTTP/1.1 (RFC 9110 § 8.8.3), a strong entity tag must be enclosed in double
/// quotes (`"..."`) and must not carry a weak validator prefix (`W/`).
///
/// Weak validators (`W/"..."`), unquoted strings (`strong-raw`), empty strings,
/// and null return `null` and MUST NOT be used for conditional operations.
String? strongEtag(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.length < 3 ||
      trimmed.startsWith('W/') ||
      trimmed.startsWith('w/')) {
    return null;
  }
  if (!trimmed.startsWith('"') || !trimmed.endsWith('"')) {
    return null;
  }
  // Content inside quotes must not be empty (i.e. `""` is rejected)
  if (trimmed.length <= 2) {
    return null;
  }
  return trimmed;
}

/// Convenience predicate for [strongEtag].
bool isStrongEtag(String? value) => strongEtag(value) != null;

/// Base exception for remote sync operations.
class MergeRemoteException implements Exception {
  final String message;
  final int? statusCode;
  final Object? cause;

  const MergeRemoteException(this.message, {this.statusCode, this.cause});

  @override
  String toString() =>
      'MergeRemoteException($message${statusCode != null ? ', status: $statusCode' : ''})';
}

/// Thrown when remote data is corrupt, incomplete, or fails integrity checks.
class MergeRemoteCorruptException extends MergeRemoteException {
  const MergeRemoteCorruptException(
    super.message, {
    super.statusCode,
    super.cause,
  });

  @override
  String toString() =>
      'MergeRemoteCorruptException($message${statusCode != null ? ', status: $statusCode' : ''})';
}

/// Thrown when an upload or write precondition conflicts with remote state.
class MergeRemoteConflictException extends MergeRemoteException {
  const MergeRemoteConflictException(
    super.message, {
    super.statusCode,
    super.cause,
  });

  @override
  String toString() =>
      'MergeRemoteConflictException($message${statusCode != null ? ', status: $statusCode' : ''})';
}

enum MergeRemoteLayout { legacyCheckpoint, snapshotCommit }

/// Metadata representation of a remote causal checkpoint candidate file.
class MergeRemoteEntry {
  /// Full relative path below the WebDAV endpoint.
  final String filename;

  /// Actor read from the owning device directory's `device.json`.
  final String actor;

  /// The monotonic publication counter for [actor].
  final int counter;

  /// Lowercase 64-character SHA-256 digest of checkpoint/manifest bytes.
  final String digest;

  /// Optional remote HTTP ETag returned by directory listing or HEAD/GET.
  final String? eTag;

  /// Explicit wire layout; old entries are never parsed as v4 commits.
  final MergeRemoteLayout layout;

  const MergeRemoteEntry({
    required this.filename,
    required this.actor,
    required this.counter,
    required this.digest,
    this.eTag,
    this.layout = MergeRemoteLayout.legacyCheckpoint,
  });

  /// Regex validating safe actor identifiers used in checkpoint payloads.
  static final RegExp _actorRegex = RegExp(r'^[a-zA-Z0-9_\-]+$');

  /// Regex matching `<counter>-<sha256>.json`.
  static final RegExp _entryRegex = RegExp(r'^(\d+)-([0-9a-fA-F]{64})\.json$');

  /// Parses the read-only legacy `VeneraPlus/<device>/<counter>-<digest>.json`.
  static MergeRemoteEntry? tryParse(
    String fullPath, {
    required String actor,
    String? eTag,
  }) {
    final segments = fullPath.split('/');
    if (segments.length != 3 ||
        segments[0] != 'VeneraPlus' ||
        !_isSafeDeviceDirectoryName(segments[1]) ||
        !_actorIsSafe(actor)) {
      return null;
    }

    final match = _entryRegex.firstMatch(segments[2]);
    if (match == null || match.group(0) != segments[2]) return null;
    final counter = int.tryParse(match.group(1)!);
    final digest = match.group(2)!.toLowerCase();
    if (counter == null || counter < 0) return null;

    return MergeRemoteEntry(
      filename: fullPath,
      actor: actor,
      counter: counter,
      digest: digest,
      eTag: eTag,
      layout: MergeRemoteLayout.legacyCheckpoint,
    );
  }

  /// Parses a v4 `VeneraPlus/sync-v4/<device>/commits/<counter>-<hash>.json`.
  static MergeRemoteEntry? tryParseSnapshot(
    String fullPath, {
    required String actor,
    String? eTag,
  }) {
    final segments = fullPath.split('/');
    if (segments.length != 5 ||
        segments[0] != 'VeneraPlus' ||
        segments[1] != 'sync-v4' ||
        !_isSafeDeviceDirectoryName(segments[2]) ||
        segments[3] != 'commits' ||
        !_actorIsSafe(actor)) {
      return null;
    }
    final match = _entryRegex.firstMatch(segments[4]);
    if (match == null || match.group(0) != segments[4]) return null;
    final counter = int.tryParse(match.group(1)!);
    final digest = match.group(2)!.toLowerCase();
    if (counter == null || counter <= 0) return null;
    return MergeRemoteEntry(
      filename: fullPath,
      actor: actor,
      counter: counter,
      digest: digest,
      eTag: eTag,
      layout: MergeRemoteLayout.snapshotCommit,
    );
  }

  /// True if this entry possesses a legitimate quoted strong HTTP validator.
  bool get hasStrongEtag => isStrongEtag(eTag);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MergeRemoteEntry &&
          filename == other.filename &&
          actor == other.actor &&
          counter == other.counter &&
          digest == other.digest &&
          eTag == other.eTag &&
          layout == other.layout;

  @override
  int get hashCode =>
      Object.hash(filename, actor, counter, digest, eTag, layout);

  @override
  String toString() =>
      'MergeRemoteEntry(filename: $filename, actor: $actor, counter: $counter, digest: $digest, eTag: $eTag, layout: $layout)';
}

bool _isSafeDeviceDirectoryName(String value) {
  try {
    return normalizeSyncDeviceName(value) == value;
  } on FormatException {
    return false;
  }
}

bool _actorIsSafe(String actor) =>
    MergeRemoteEntry._actorRegex.firstMatch(actor)?.group(0) == actor;

class _DeviceOwnership {
  const _DeviceOwnership({required this.actor, required this.name});

  final String actor;
  final String name;
}

/// Remote WebDAV transport for VeneraPlus multi-device merge sync.
///
/// New publications use immutable v4 manifests and content-addressed objects;
/// the older checkpoint layout remains an explicit read-only migration API.
class MergeRemote {
  MergeRemote(
    this._client, {
    String deviceName = 'Device',
    this.onWarning,
    Directory? cacheDirectory,
  }) : deviceName = normalizeSyncDeviceName(deviceName),
       _cacheDirectory = cacheDirectory;

  static const String _namespace = 'VeneraPlus';
  static const String _snapshotNamespace = 'VeneraPlus/sync-v4';
  static const String _markerName = 'device.json';
  static const int _maxVerifiedObjectCacheBytes = 64 * 1024 * 1024;

  final dav.Client _client;
  final Directory? _cacheDirectory;
  int _cacheTempSequence = 0;
  final String deviceName;

  /// Optional callback to observe non-fatal warnings (e.g. compaction skips).
  final void Function(String warning)? onWarning;

  /// Observable record of non-fatal operational warnings.
  final List<String> warnings = [];
  final Map<String, String> _deviceNames = {};
  final Map<String, Uint8List> _verifiedObjects = {};
  int _verifiedObjectCacheBytes = 0;
  int? _persistentObjectCacheBytes;
  int _uploadedBytes = 0;
  int _downloadedBytes = 0;
  int _uploadedObjects = 0;
  int _downloadedObjects = 0;

  dav.Client get client => _client;
  Map<String, String> get deviceNames => Map.unmodifiable(_deviceNames);

  /// Bytes successfully written/downloaded, including verification read-backs.
  int get uploadedBytes => _uploadedBytes;
  int get downloadedBytes => _downloadedBytes;

  /// Content objects actually sent or fetched; manifests are excluded.
  int get uploadedObjects => _uploadedObjects;
  int get downloadedObjects => _downloadedObjects;

  /// Resets transfer counters without clearing verified content-address cache.
  void resetTransferStats() {
    _uploadedBytes = 0;
    _downloadedBytes = 0;
    _uploadedObjects = 0;
    _downloadedObjects = 0;
  }

  void _recordWarning(String message) {
    warnings.add(message);
    onWarning?.call(message);
  }

  String _deviceDirectoryPath(String name, {String namespace = _namespace}) =>
      '$namespace/$name';

  String _markerPath(String name, {String namespace = _namespace}) =>
      '${_deviceDirectoryPath(name, namespace: namespace)}/$_markerName';

  /// Validates a complete checkpoint/commit path rather than silently rebasing it.
  String _resolvePath(MergeRemoteEntry entry) {
    final parsed = entry.layout == MergeRemoteLayout.snapshotCommit
        ? MergeRemoteEntry.tryParseSnapshot(entry.filename, actor: entry.actor)
        : MergeRemoteEntry.tryParse(entry.filename, actor: entry.actor);
    if (parsed == null ||
        parsed.layout != entry.layout ||
        parsed.counter != entry.counter ||
        parsed.digest != entry.digest.toLowerCase()) {
      throw FormatException(
        'Invalid checkpoint path for actor ${entry.actor}: ${entry.filename}',
      );
    }
    return parsed.filename;
  }

  Future<void> _verifyEntryOwnership(MergeRemoteEntry entry) async {
    final segments = entry.filename.split('/');
    final isSnapshot = entry.layout == MergeRemoteLayout.snapshotCommit;
    final directoryName = segments[isSnapshot ? 2 : 1];
    final owner = await _readDeviceOwnership(
      directoryName,
      namespace: isSnapshot ? _snapshotNamespace : _namespace,
    );
    if (owner == null || owner.actor != entry.actor) {
      throw MergeRemoteCorruptException(
        'Checkpoint ownership metadata does not match ${entry.filename}',
      );
    }
  }

  Future<void> _ensureCollection(String path) async {
    try {
      await _client.mkdir(path);
    } on DioException catch (e) {
      if (e.response?.statusCode != 405) rethrow;
    }
    try {
      await _client.readDir(path);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw MergeRemoteException(
          'Failed to verify WebDAV collection $path',
          statusCode: 404,
          cause: e,
        );
      }
      rethrow;
    }
  }

  Future<void> _ensureNamespaceDirectory({
    String namespace = _namespace,
  }) async {
    if (namespace == _snapshotNamespace) {
      await _ensureCollection(_namespace);
    }
    await _ensureCollection(namespace);
  }

  Future<_DeviceOwnership?> _readDeviceOwnership(
    String directoryName, {
    String namespace = _namespace,
    bool ignoreInvalid = false,
  }) async {
    final path = _markerPath(directoryName, namespace: namespace);
    final Uint8List bytes;
    try {
      bytes = await _downloadRawBytes(path, maxBytes: 4096);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      throw MergeRemoteException(
        'Failed to read device ownership marker',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on MergeRemoteCorruptException {
      if (!ignoreInvalid) rethrow;
      _recordWarning(
        'Ignoring device directory with invalid ownership metadata',
      );
      return null;
    } on MergeRemoteException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }

    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic> || decoded.length != 2) {
        throw const FormatException('Invalid device ownership marker schema');
      }
      final actor = decoded['actor'];
      final name = decoded['name'];
      if (actor is! String ||
          !_actorIsSafe(actor) ||
          name is! String ||
          name != directoryName ||
          !_isSafeDeviceDirectoryName(name)) {
        throw const FormatException('Invalid device ownership marker values');
      }
      return _DeviceOwnership(actor: actor, name: name);
    } on FormatException catch (error) {
      final corrupt = MergeRemoteCorruptException(
        'Invalid ownership metadata in $path',
        cause: error,
      );
      if (ignoreInvalid) {
        _recordWarning(
          'Ignoring device directory with invalid ownership metadata',
        );
        return null;
      }
      throw corrupt;
    }
  }

  Future<_DeviceOwnership> _claimDeviceOwnership(
    String directoryName,
    String actor, {
    String namespace = _namespace,
  }) async {
    final markerBytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'actor': actor, 'name': directoryName})),
    );
    Response? response;
    try {
      response = await _client.c.req(
        _client,
        'PUT',
        _markerPath(directoryName, namespace: namespace),
        data: _streamBytes(markerBytes),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['If-None-Match'] = '*';
          options.headers!['content-length'] = markerBytes.length;
          options.headers!['content-type'] = 'application/json; charset=utf-8';
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 412) {
        response = e.response;
      } else {
        rethrow;
      }
    }

    final statusCode = response?.statusCode;
    if (statusCode != 412 &&
        statusCode != 200 &&
        statusCode != 201 &&
        statusCode != 204) {
      throw MergeRemoteException(
        'WebDAV ownership claim failed',
        statusCode: statusCode,
      );
    }

    // Read-after-write also resolves a concurrent claim that won the precondition race.
    final owner = await _readDeviceOwnership(
      directoryName,
      namespace: namespace,
    );
    if (owner == null) {
      throw const MergeRemoteConflictException(
        'Device ownership marker was not visible after claim',
      );
    }
    return owner;
  }

  Future<String> _ensureDeviceDirectory(
    String actor, {
    String namespace = _namespace,
  }) async {
    await _ensureNamespaceDirectory(namespace: namespace);

    var directoryName = deviceName;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _ensureCollection(
        _deviceDirectoryPath(directoryName, namespace: namespace),
      );
      var owner = await _readDeviceOwnership(
        directoryName,
        namespace: namespace,
      );
      owner ??= await _claimDeviceOwnership(
        directoryName,
        actor,
        namespace: namespace,
      );
      if (owner.actor == actor && owner.name == directoryName) {
        return directoryName;
      }
      if (attempt == 0) {
        final suffix = sha256
            .convert(utf8.encode(actor))
            .toString()
            .substring(0, 8);
        final fallbackName = normalizeSyncDeviceName('$deviceName-$suffix');
        if (fallbackName == deviceName ||
            !_isSafeDeviceDirectoryName(fallbackName) ||
            !fallbackName.endsWith('-$suffix')) {
          throw const MergeRemoteConflictException(
            'Unable to resolve device directory ownership collision',
          );
        }
        directoryName = fallbackName;
        continue;
      }
      throw MergeRemoteConflictException(
        'Device directory ownership collision at $directoryName',
      );
    }
    throw const MergeRemoteConflictException(
      'Unable to resolve device directory ownership collision',
    );
  }

  /// Lists remote checkpoint candidates in immediate `VeneraPlus` device directories.
  ///
  /// Important:
  /// Entries discovered from directory listings are unverified *candidate* checkpoints.
  /// A filename adhering to the naming scheme or possessing non-zero size does NOT prove
  /// its content is valid or non-corrupt until cryptographically verified via [download].
  ///
  /// By default ([latestOnly] = false), this returns all candidate checkpoint entries
  /// sorted by actor and counter descending. Returning all candidates guarantees that if
  /// a newer non-zero candidate fails download or payload integrity checks, the caller
  /// retains access to older valid predecessor checkpoints and is not blinded by a
  /// torn/incomplete latest candidate.
  ///
  /// When [latestOnly] is true, returns only the highest-counter candidate entries per actor
  /// (preserving multiple entries with the same highest counter to expose collisions).
  Future<List<MergeRemoteEntry>> _listLegacyCheckpoints({
    bool latestOnly = false,
  }) async {
    List<dav.File> deviceDirectories;
    try {
      deviceDirectories = await _client.readDir(_namespace);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }

    final parsedEntries = <MergeRemoteEntry>[];
    for (final directory in deviceDirectories) {
      if (directory.isDir != true) continue;
      final directoryName = directory.name;
      if (directoryName == null || !_isSafeDeviceDirectoryName(directoryName)) {
        continue;
      }

      final owner = await _readDeviceOwnership(
        directoryName,
        ignoreInvalid: true,
      );
      if (owner == null) continue;

      final List<dav.File> checkpointFiles;
      try {
        checkpointFiles = await _client.readDir(
          _deviceDirectoryPath(directoryName),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) continue;
        rethrow;
      }

      for (final file in checkpointFiles) {
        if (file.isDir == true) continue;
        final name = file.name;
        if (name == null || name.isEmpty || (file.size == 0)) continue;
        final entry = MergeRemoteEntry.tryParse(
          '$_namespace/$directoryName/$name',
          actor: owner.actor,
          eTag: file.eTag,
        );
        if (entry != null) parsedEntries.add(entry);
      }
    }

    if (!latestOnly) {
      parsedEntries.sort((a, b) {
        final actorComp = a.actor.compareTo(b.actor);
        if (actorComp != 0) return actorComp;
        final counterComp = b.counter.compareTo(a.counter); // descending
        if (counterComp != 0) return counterComp;
        return a.digest.compareTo(b.digest);
      });
      return parsedEntries;
    }

    // Group candidate entries by actor to identify the highest counter.
    final byActor = <String, List<MergeRemoteEntry>>{};
    for (final entry in parsedEntries) {
      byActor.putIfAbsent(entry.actor, () => []).add(entry);
    }

    final result = <MergeRemoteEntry>[];
    for (final entries in byActor.values) {
      final maxCounter = entries.map((e) => e.counter).reduce(math.max);
      // Retain all entries with counter == maxCounter (preserves same-counter hash collisions).
      for (final entry in entries) {
        if (entry.counter == maxCounter) {
          result.add(entry);
        }
      }
    }

    result.sort((a, b) {
      final actorComp = a.actor.compareTo(b.actor);
      if (actorComp != 0) return actorComp;
      final counterComp = b.counter.compareTo(a.counter);
      if (counterComp != 0) return counterComp;
      return a.digest.compareTo(b.digest);
    });

    return result;
  }

  /// Lists legacy checkpoints for the one-time migration reader only.
  Future<List<MergeRemoteEntry>> listLegacyCheckpoints() =>
      _listLegacyCheckpoints();

  /// Lists v4 commit candidates. Legacy checkpoint paths are never returned here.
  Future<List<MergeRemoteEntry>> list({bool latestOnly = false}) async {
    _deviceNames.clear();
    List<dav.File> deviceDirectories;
    try {
      deviceDirectories = await _client.readDir(_snapshotNamespace);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }

    final entries = <MergeRemoteEntry>[];
    for (final directory in deviceDirectories) {
      if (directory.isDir != true) continue;
      final directoryName = directory.name;
      if (directoryName == null || !_isSafeDeviceDirectoryName(directoryName)) {
        continue;
      }
      final owner = await _readDeviceOwnership(
        directoryName,
        namespace: _snapshotNamespace,
        ignoreInvalid: true,
      );
      if (owner == null) continue;
      _deviceNames[owner.actor] = owner.name;

      final List<dav.File> commitFiles;
      try {
        commitFiles = await _client.readDir(
          _deviceDirectoryPath(directoryName, namespace: _snapshotNamespace) +
              '/commits',
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) continue;
        rethrow;
      }
      for (final file in commitFiles) {
        if (file.isDir == true || file.name == null || file.size == 0) continue;
        final entry = MergeRemoteEntry.tryParseSnapshot(
          '$_snapshotNamespace/$directoryName/commits/${file.name}',
          actor: owner.actor,
          eTag: file.eTag,
        );
        if (entry != null) entries.add(entry);
      }
    }

    entries.sort((a, b) {
      final actorOrder = a.actor.compareTo(b.actor);
      if (actorOrder != 0) return actorOrder;
      final counterOrder = b.counter.compareTo(a.counter);
      if (counterOrder != 0) return counterOrder;
      return a.digest.compareTo(b.digest);
    });
    if (!latestOnly) return entries;
    final highestByActor = <String, int>{};
    for (final entry in entries) {
      final current = highestByActor[entry.actor];
      if (current == null || entry.counter > current) {
        highestByActor[entry.actor] = entry.counter;
      }
    }
    return entries
        .where((entry) => entry.counter == highestByActor[entry.actor])
        .toList(growable: false);
  }

  /// Convenience helper to list only the highest-counter v4 candidates.
  Future<List<MergeRemoteEntry>> listLatest() => list(latestOnly: true);

  /// Downloads and cryptographically verifies a remote causal checkpoint.
  ///
  /// Verification steps:
  /// 1. Download response bytes (follows redirects; does not require GET ETag).
  /// 2. Compute SHA-256 of received bytes and compare to [entry.digest].
  /// 3. Decode UTF-8 and parse JSON schema.
  /// 4. Verify payload `actor` and `counter` strictly match [entry.actor] and [entry.counter].
  /// 5. Validate `MergeBatch.fromJson` and verify `batch.id` matches [entry.digest].
  Future<MergeBatch> _downloadLegacyCheckpoint(MergeRemoteEntry entry) async {
    final remotePath = _resolvePath(entry);
    await _verifyEntryOwnership(entry);
    final Uint8List bytes;
    try {
      bytes = await _downloadRawBytes(
        remotePath,
        maxBytes: MergeSnapshot.maxTotalUncompressedBytes,
        countAsObject: true,
      );
    } on DioException catch (error) {
      throw MergeRemoteException(
        'HTTP GET failed for $remotePath: ${error.message}',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    }
    if (bytes.isEmpty) {
      throw MergeRemoteCorruptException(
        'Download returned empty body for $remotePath',
      );
    }
    // Independent of server redirect or missing ETag header, bind response bytes via SHA-256.
    final computedDigest = sha256.convert(bytes).toString().toLowerCase();
    if (computedDigest != entry.digest.toLowerCase()) {
      throw MergeRemoteCorruptException(
        'SHA256 digest mismatch for ${entry.filename}: '
        'expected ${entry.digest}, got $computedDigest',
      );
    }

    final String jsonString;
    try {
      jsonString = utf8.decode(bytes, allowMalformed: false);
    } catch (e) {
      throw MergeRemoteCorruptException(
        'Failed to decode UTF-8 for ${entry.filename}: $e',
        cause: e,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      throw MergeRemoteCorruptException(
        'Malformed JSON in ${entry.filename}: $e',
        cause: e,
      );
    }

    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        !decoded.keys.toSet().containsAll(const {
          'actor',
          'counter',
          'document',
        })) {
      throw const MergeRemoteCorruptException(
        'Invalid wire payload: expected only actor, counter, document',
      );
    }
    final jsonMap = decoded.cast<String, Object?>();
    final payloadActor = jsonMap['actor'];
    final payloadCounter = jsonMap['counter'];
    if (payloadActor is! String ||
        payloadCounter is! int ||
        jsonMap['document'] is! Map) {
      throw const MergeRemoteCorruptException(
        'Invalid wire payload field types',
      );
    }
    final counterVal = payloadCounter;
    if (payloadActor != entry.actor || counterVal != entry.counter) {
      throw MergeRemoteCorruptException(
        'Checkpoint metadata mismatch in ${entry.filename}: '
        'ownership marker and counter indicate (${entry.actor}, ${entry.counter}) '
        'but payload indicates ($payloadActor, $counterVal)',
      );
    }

    final MergeBatch batch;
    try {
      batch = MergeBatch.fromJson({...jsonMap, 'id': computedDigest});
    } catch (e) {
      throw MergeRemoteCorruptException(
        'Failed to construct MergeBatch for ${entry.filename}: $e',
        cause: e,
      );
    }

    if (batch.id.toLowerCase() != entry.digest.toLowerCase()) {
      throw MergeRemoteCorruptException(
        'Batch ID mismatch in ${entry.filename}: '
        'expected ${entry.digest}, got ${batch.id}',
      );
    }

    return batch;
  }

  /// Reads only an explicitly classified legacy checkpoint for migration.
  Future<MergeBatch> downloadLegacyCheckpoint(MergeRemoteEntry entry) {
    if (entry.layout != MergeRemoteLayout.legacyCheckpoint) {
      throw ArgumentError.value(
        entry.layout,
        'entry',
        'Expected a legacy checkpoint',
      );
    }
    return _downloadLegacyCheckpoint(entry);
  }

  /// Downloads one immutable snapshot commit and all of its referenced objects.
  Future<MergeBatch> download(MergeRemoteEntry entry) {
    return entry.layout == MergeRemoteLayout.snapshotCommit
        ? _downloadSnapshot(entry)
        : _downloadLegacyCheckpoint(entry);
  }

  Future<MergeBatch> _downloadSnapshot(MergeRemoteEntry entry) async {
    final remotePath = _resolvePath(entry);
    await _verifyEntryOwnership(entry);
    final Uint8List manifestBytes;
    try {
      manifestBytes = await _downloadRawBytes(
        remotePath,
        maxBytes: MergeSnapshot.maxManifestBytes,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        throw MergeRemoteCorruptException(
          'Snapshot manifest is missing: $remotePath',
          statusCode: 404,
          cause: error,
        );
      }
      throw MergeRemoteException(
        'Failed to download snapshot manifest $remotePath',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on MergeRemoteException catch (error) {
      if (error.statusCode == 404) {
        throw MergeRemoteCorruptException(
          'Snapshot manifest is missing: $remotePath',
          statusCode: 404,
          cause: error,
        );
      }
      rethrow;
    }
    if (manifestBytes.isEmpty ||
        manifestBytes.length > MergeSnapshot.maxManifestBytes ||
        sha256.convert(manifestBytes).toString() != entry.digest) {
      throw MergeRemoteCorruptException(
        'Snapshot manifest is empty, oversized, or has an invalid digest: $remotePath',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'Snapshot manifest JSON is invalid: $remotePath',
        cause: error,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['objects'] is! List ||
        (decoded['objects'] as List).length > MergeSnapshot.maxObjectCount) {
      throw MergeRemoteCorruptException(
        'Snapshot manifest has an invalid object list: $remotePath',
      );
    }

    final objectRefs = decoded['objects'] as List;
    final objectPaths = <String>{};
    var totalCompressed = 0;
    final basePath = remotePath.substring(
      0,
      remotePath.lastIndexOf('/commits/'),
    );
    final objectBytes = <String, Uint8List>{};
    final fetchedObjects = <String, Uint8List>{};
    for (final refValue in objectRefs) {
      if (refValue is! Map ||
          refValue['path'] is! String ||
          refValue['sha256'] is! String ||
          refValue['compressedSize'] is! int ||
          refValue['compressedSize'] <= 0 ||
          refValue['compressedSize'] > MergeSnapshot.maxCompressedObjectBytes) {
        throw MergeRemoteCorruptException(
          'Snapshot manifest contains an invalid object reference: $remotePath',
        );
      }
      final objectPath = refValue['path'] as String;
      final digest = refValue['sha256'] as String;
      final compressedSize = refValue['compressedSize'] as int;
      if (!RegExp(
            r'^[A-Za-z][A-Za-z0-9]*/[0-9a-f]{64}[.]json[.]gz$',
          ).hasMatch(objectPath) ||
          objectPath != '${objectPath.split('/').first}/$digest.json.gz' ||
          objectPath.split('/').length != 2 ||
          !objectPaths.add(objectPath)) {
        throw MergeRemoteCorruptException(
          'Snapshot manifest contains an unsafe or duplicate object path: $objectPath',
        );
      }
      totalCompressed += compressedSize;
      if (totalCompressed > MergeSnapshot.maxTotalCompressedBytes) {
        throw MergeRemoteCorruptException(
          'Snapshot compressed size exceeds transport limit: $remotePath',
        );
      }

      final cacheKey = '$basePath/objects/$objectPath';
      var bytes = _verifiedObjects[cacheKey];
      if (bytes != null &&
          (bytes.length != compressedSize ||
              sha256.convert(bytes).toString() != digest)) {
        _forgetVerifiedObject(cacheKey);
        bytes = null;
      }
      if (bytes == null) {
        bytes = await _readPersistentObject(
          cacheKey,
          expectedSize: compressedSize,
          expectedDigest: digest,
        );
      }

      if (bytes == null) {
        try {
          bytes = await _downloadRawBytes(
            cacheKey,
            maxBytes: compressedSize,
            countAsObject: true,
          );
        } on DioException catch (error) {
          if (error.response?.statusCode == 404) {
            throw MergeRemoteCorruptException(
              'Snapshot object is missing: $objectPath',
              statusCode: 404,
              cause: error,
            );
          }
          throw MergeRemoteException(
            'Failed to download snapshot object $objectPath',
            statusCode: error.response?.statusCode,
            cause: error,
          );
        } on MergeRemoteException catch (error) {
          if (error.statusCode == 404) {
            throw MergeRemoteCorruptException(
              'Snapshot object is missing: $objectPath',
              statusCode: 404,
              cause: error,
            );
          }
          rethrow;
        }
        if (bytes.length != compressedSize ||
            sha256.convert(bytes).toString() != digest) {
          throw MergeRemoteCorruptException(
            'Snapshot object failed content verification: $objectPath',
          );
        }
        fetchedObjects[cacheKey] = bytes;
      }
      objectBytes[objectPath] = bytes;
    }

    final MergeBatch batch;
    try {
      batch = MergeSnapshot.decode(manifestBytes, objectBytes);
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'Snapshot manifest or objects failed schema validation: $remotePath',
        cause: error,
      );
    }
    if (batch.actor != entry.actor ||
        batch.counter != entry.counter ||
        batch.id != (decoded['batchId'] as String?)) {
      throw MergeRemoteCorruptException(
        'Snapshot commit metadata does not match its owner or filename: $remotePath',
      );
    }
    for (final entry in fetchedObjects.entries) {
      _rememberVerifiedObject(entry.key, entry.value);
      await _writePersistentObject(entry.key, entry.value);
    }
    return batch;
  }

  /// Downloads the latest valid checkpoint for [actor] from [candidates].
  ///
  /// Iterates through candidates for [actor] in descending counter order.
  /// If a candidate fails cryptographic or schema verification (e.g. truncated
  /// or corrupt upload left on the server), it is safely skipped with a warning
  /// to [onCorruptCandidate] without contaminating local business records,
  /// and the next older valid predecessor checkpoint is downloaded.
  ///
  /// Returns `null` if no valid candidate exists for [actor].
  Future<MergeBatch?> downloadLatestValid(
    String actor,
    List<MergeRemoteEntry> candidates, {
    void Function(MergeRemoteEntry candidate, Object error)? onCorruptCandidate,
  }) async {
    final actorCandidates = candidates.where((e) => e.actor == actor).toList();
    actorCandidates.sort((a, b) => b.counter.compareTo(a.counter));

    for (final candidate in actorCandidates) {
      try {
        final batch = await download(candidate);
        return batch;
      } on MergeRemoteCorruptException catch (e) {
        _recordWarning(
          'Skipping corrupt remote checkpoint candidate ${candidate.filename}: ${e.message}',
        );
        onCorruptCandidate?.call(candidate, e);
      }
    }
    return null;
  }

  /// Downloads raw payload bytes without allowing an oversized response body.
  Future<Uint8List> _downloadRawBytes(
    String remotePath, {
    required int maxBytes,
    bool countAsObject = false,
  }) async {
    final Response<ResponseBody> response = await _client.c.req<ResponseBody>(
      _client,
      'GET',
      remotePath,
      optionsHandler: (options) {
        options.responseType = ResponseType.stream;
      },
    );
    if (response.statusCode != 200 || response.data == null) {
      throw MergeRemoteException(
        'Failed to download raw bytes for $remotePath: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final declaredLength = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    if (declaredLength != null && declaredLength > maxBytes) {
      throw MergeRemoteCorruptException(
        'Remote payload exceeds size limit: $remotePath',
      );
    }
    if (countAsObject) _downloadedObjects++;

    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.data!.stream) {
      _downloadedBytes += chunk.length;
      if (chunk.length > maxBytes - received) {
        throw MergeRemoteCorruptException(
          'Remote payload exceeds size limit: $remotePath',
        );
      }
      received += chunk.length;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Generates a chunked zero-copy stream from [bytes].
  Stream<List<int>> _streamBytes(
    Uint8List bytes, {
    int chunkSize = 64 * 1024,
  }) async* {
    if (bytes.length <= chunkSize) {
      yield bytes;
      return;
    }
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      yield Uint8List.sublistView(bytes, i, end);
    }
  }

  /// Uploads all missing immutable objects first, then conditionally publishes the
  /// manifest as the sole visible commit point.
  Future<String> upload(MergeBatch batch) async {
    return uploadSnapshot(MergeSnapshot.fromBatch(batch));
  }

  /// Uploads an already encoded snapshot without re-compressing its objects.
  Future<String> uploadSnapshot(MergeSnapshot snapshot) async {
    final manifest = snapshot.manifest;
    final actor = manifest['actor'];
    final counter = manifest['counter'];
    final batchId = manifest['batchId'];
    if (actor is! String ||
        !_actorIsSafe(actor) ||
        counter is! int ||
        counter <= 0 ||
        batchId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(batchId) ||
        manifest['schema'] != 1 ||
        manifest['documentSchema'] != 3) {
      throw const FormatException('Invalid snapshot publication metadata');
    }
    final manifestBytes = snapshot.serializeManifest();
    final manifestDigest = snapshot.digest;

    await _client.ping();
    final directoryName = await _ensureDeviceDirectory(
      actor,
      namespace: _snapshotNamespace,
    );
    final basePath = '$_snapshotNamespace/$directoryName';
    await _ensureCollection('$basePath/commits');
    await _ensureCollection('$basePath/objects');

    for (final object in snapshot.objects.entries) {
      final segments = object.key.split('/');
      if (segments.length != 2) {
        throw FormatException('Invalid snapshot object key: ${object.key}');
      }
      final domain = segments.first;
      final objectDigest = sha256.convert(object.value).toString();
      if (object.key != '$domain/$objectDigest.json.gz') {
        throw FormatException(
          'Snapshot object path/hash mismatch: ${object.key}',
        );
      }
      await _ensureCollection('$basePath/objects/$domain');
      await _publishImmutable(
        '$basePath/objects/${object.key}',
        object.value,
        objectDigest,
        objectCacheKey: '$basePath/objects/${object.key}',
      );
    }

    // Manifest-last is the atomic visibility boundary for a checkpoint.
    final commitPath = '$basePath/commits/$counter-$manifestDigest.json';
    await _publishImmutable(commitPath, manifestBytes, manifestDigest);
    return commitPath;
  }

  Future<void> _publishImmutable(
    String path,
    Uint8List bytes,
    String expectedDigest, {
    String? objectCacheKey,
  }) async {
    if (bytes.isEmpty || sha256.convert(bytes).toString() != expectedDigest) {
      throw FormatException('Local immutable payload digest mismatch: $path');
    }
    final maxReadbackBytes = path.endsWith('.gz')
        ? MergeSnapshot.maxCompressedObjectBytes
        : MergeSnapshot.maxManifestBytes;
    if (objectCacheKey != null) {
      var cached = _verifiedObjects[objectCacheKey];
      if (cached != null) {
        if (_bytesEqual(cached, bytes) &&
            await _remoteObjectExists(path, bytes.length)) {
          return;
        }
        _forgetVerifiedObject(objectCacheKey);
      }
      cached = await _readPersistentObject(
        objectCacheKey,
        expectedSize: bytes.length,
        expectedDigest: expectedDigest,
      );
      if (cached != null) {
        if (_bytesEqual(cached, bytes) &&
            await _remoteObjectExists(path, bytes.length)) {
          return;
        }
        _forgetVerifiedObject(objectCacheKey);
      }
    }

    Response? response;
    try {
      response = await _client.c.req(
        _client,
        'PUT',
        path,
        data: _streamBytes(bytes),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['If-None-Match'] = '*';
          options.headers!['content-length'] = bytes.length;
          options.headers!['content-type'] = path.endsWith('.gz')
              ? 'application/gzip'
              : 'application/json; charset=utf-8';
        },
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 412) {
        response = error.response;
      } else {
        rethrow;
      }
    }
    final status = response?.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      _uploadedBytes += bytes.length;
      if (objectCacheKey != null) _uploadedObjects++;
      final readBack = await _downloadRawBytes(
        path,
        maxBytes: maxReadbackBytes,
        countAsObject: objectCacheKey != null,
      );
      if (!_bytesEqual(readBack, bytes) ||
          sha256.convert(readBack).toString() != expectedDigest) {
        throw MergeRemoteCorruptException(
          'Uploaded immutable payload failed read-back verification: $path',
          statusCode: status,
        );
      }
      if (objectCacheKey != null) {
        _rememberVerifiedObject(objectCacheKey, bytes);
        await _writePersistentObject(objectCacheKey, bytes);
      }
      return;
    }
    if (status != 412) {
      throw MergeRemoteException(
        'WebDAV immutable PUT failed for $path: HTTP $status',
        statusCode: status,
      );
    }

    final existing = await _downloadRawBytes(
      path,
      maxBytes: maxReadbackBytes,
      countAsObject: objectCacheKey != null,
    );
    if (_bytesEqual(existing, bytes) &&
        sha256.convert(existing).toString() == expectedDigest) {
      if (objectCacheKey != null) {
        _rememberVerifiedObject(objectCacheKey, existing);
        await _writePersistentObject(objectCacheKey, existing);
      }
      return;
    }

    // Only recover a torn retry after a strong validator proves which object is
    // being replaced; never accept a hash collision or unverified truncation.
    try {
      final head = await _client.c.req(_client, 'HEAD', path);
      final validator = strongEtag(head.headers.value('etag'));
      if (validator != null) {
        final replacement = await _client.c.req(
          _client,
          'PUT',
          path,
          data: _streamBytes(bytes),
          optionsHandler: (options) {
            options.headers ??= {};
            options.headers!['If-Match'] = validator;
            options.headers!['content-length'] = bytes.length;
            options.headers!['content-type'] = path.endsWith('.gz')
                ? 'application/gzip'
                : 'application/json; charset=utf-8';
          },
        );
        if ([200, 201, 204].contains(replacement.statusCode)) {
          _uploadedBytes += bytes.length;
          if (objectCacheKey != null) _uploadedObjects++;
          final verified = await _downloadRawBytes(
            path,
            maxBytes: maxReadbackBytes,
            countAsObject: objectCacheKey != null,
          );
          if (_bytesEqual(verified, bytes) &&
              sha256.convert(verified).toString() == expectedDigest) {
            if (objectCacheKey != null) {
              _rememberVerifiedObject(objectCacheKey, verified);
              await _writePersistentObject(objectCacheKey, verified);
            }
            return;
          }
          throw MergeRemoteCorruptException(
            'Conditionally repaired immutable payload failed verification: $path',
          );
        }
      }
    } on DioException catch (error) {
      if (error.response?.statusCode != 412) rethrow;
    }
    throw MergeRemoteConflictException(
      'Remote immutable payload differs at $path; refusing unproven replacement',
      statusCode: 412,
    );
  }

  Future<bool> _remoteObjectExists(String path, int expectedSize) async {
    try {
      final response = await _client.c.req(_client, 'HEAD', path);
      final status = response.statusCode;
      if (status == 404 || status == 405 || status == 501) return false;
      if (status != 200) {
        throw MergeRemoteException(
          'Failed to verify cached remote object $path',
          statusCode: status,
        );
      }
      final contentLength = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      return contentLength == null || contentLength == expectedSize;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 404 || status == 405 || status == 501) return false;
      rethrow;
    }
  }

  bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _forgetVerifiedObject(String key) {
    final previous = _verifiedObjects.remove(key);
    if (previous != null) _verifiedObjectCacheBytes -= previous.length;
  }

  void _rememberVerifiedObject(String key, Uint8List bytes) {
    _forgetVerifiedObject(key);
    if (bytes.length > _maxVerifiedObjectCacheBytes) return;
    while (_verifiedObjectCacheBytes >
        _maxVerifiedObjectCacheBytes - bytes.length) {
      final oldestKey = _verifiedObjects.keys.first;
      _forgetVerifiedObject(oldestKey);
    }
    _verifiedObjects[key] = bytes;
    _verifiedObjectCacheBytes += bytes.length;
  }

  Directory? get _objectCacheRoot {
    final root = _cacheDirectory;
    if (root == null) return null;
    return Directory(p.join(root.path, 'sync-v4-verified-objects'));
  }

  File _persistentObjectFile(String remotePath) {
    final root = _objectCacheRoot!;
    final pathDigest = sha256.convert(utf8.encode(remotePath)).toString();
    return File(
      p.join(root.path, pathDigest.substring(0, 2), '$pathDigest.obj'),
    );
  }

  Future<Uint8List?> _readPersistentObject(
    String remotePath, {
    required int expectedSize,
    required String expectedDigest,
  }) async {
    if (_cacheDirectory == null) return null;
    final file = _persistentObjectFile(remotePath);
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.file) {
        await _removePersistentFile(file);
        return null;
      }
      final stat = await file.stat();
      if (stat.size != expectedSize ||
          stat.size > MergeSnapshot.maxCompressedObjectBytes) {
        await _removePersistentFile(file);
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != expectedSize ||
          sha256.convert(bytes).toString() != expectedDigest) {
        await _removePersistentFile(file);
        return null;
      }
      _rememberVerifiedObject(remotePath, bytes);
      try {
        await file.setLastModified(DateTime.now());
      } on FileSystemException {
        // Cache timestamp maintenance must not affect a verified read.
      }
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writePersistentObject(
    String remotePath,
    Uint8List bytes,
  ) async {
    final root = _objectCacheRoot;
    if (root == null || bytes.length > _maxVerifiedObjectCacheBytes) return;
    final target = _persistentObjectFile(remotePath);
    File? temporary;
    try {
      await target.parent.create(recursive: true);
      await _trimPersistentObjectCache(bytes.length, target);
      temporary = File(
        '${target.path}.tmp-${identityHashCode(this)}-${_cacheTempSequence++}',
      );
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      _persistentObjectCacheBytes =
          (_persistentObjectCacheBytes ?? 0) + bytes.length;
    } on FileSystemException {
      // A cache failure is a miss on a later attempt, never a network success.
    } finally {
      if (temporary != null) await _removePersistentFile(temporary);
    }
  }

  Future<void> _trimPersistentObjectCache(
    int incomingBytes,
    File target,
  ) async {
    final root = _objectCacheRoot!;
    await root.create(recursive: true);
    var cachedBytes =
        _persistentObjectCacheBytes ?? await _scanPersistentObjectCache(root);

    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      final stat = await target.stat();
      await target.delete();
      cachedBytes -= stat.size;
    } else if (targetType == FileSystemEntityType.link) {
      await target.delete();
    }

    if (cachedBytes + incomingBytes > _maxVerifiedObjectCacheBytes) {
      final files = <({File file, int size, DateTime modified})>[];
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File ||
            !p.basename(entity.path).endsWith('.obj') ||
            (await FileSystemEntity.type(entity.path, followLinks: false)) !=
                FileSystemEntityType.file) {
          continue;
        }
        final stat = await entity.stat();
        files.add((file: entity, size: stat.size, modified: stat.modified));
      }
      files.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in files) {
        if (cachedBytes + incomingBytes <= _maxVerifiedObjectCacheBytes) break;
        try {
          await entry.file.delete();
          cachedBytes -= entry.size;
        } on FileSystemException {
          // Preserve accounting when an older cache file cannot be evicted.
        }
      }
    }
    if (cachedBytes + incomingBytes > _maxVerifiedObjectCacheBytes) {
      throw FileSystemException(
        'Cannot make room in verified-object cache',
        root.path,
      );
    }
    _persistentObjectCacheBytes = cachedBytes;
  }

  Future<int> _scanPersistentObjectCache(Directory root) async {
    var cachedBytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (name.contains('.tmp-')) {
        if (type == FileSystemEntityType.file) {
          final stat = await entity.stat();
          try {
            await entity.delete();
          } on FileSystemException {
            cachedBytes += stat.size;
          }
        }
        continue;
      }
      if (!name.endsWith('.obj') || type != FileSystemEntityType.file) continue;
      cachedBytes += (await entity.stat()).size;
    }
    return cachedBytes;
  }

  Future<void> _removePersistentFile(File file) async {
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await file.delete();
        _persistentObjectCacheBytes = null;
      }
    } on FileSystemException {
      // A stale or unremovable cache file is treated as unavailable.
    }
  }

  /// Compacts predecessor checkpoints for the owning actor.
  ///
  /// Compaction rules:
  /// - Only inspects candidates present in [priorEntries] before publication.
  /// - Only deletes files belonging to [uploaded.actor] (never other actors).
  /// - Retains the newest fully verified predecessor as a fallback after a corrupt publication.
  /// - Deletes another predecessor only when [uploaded.document.dominates] covers all its
  ///   fields, candidates, and tombstones. Counter checks alone are insufficient.
  /// - Requires a legitimate quoted strong ETag validator (`isStrongEtag(entry.eTag)`);
  ///   missing, unquoted, or weak validators are retained.
  /// - Sends conditional DELETE with `If-Match: strongEtag`.
  /// - Never modifies or removes legacy `.venera` files or files outside namespace.
  /// - Emits non-fatal warnings for corrupt/undominated candidates; remote service failures
  ///   are reported as warnings so a successful publication remains successful.
  Future<void> compact(
    MergeBatch uploaded,
    List<MergeRemoteEntry> priorEntries,
  ) async {
    final candidatesByPath = <String, MergeRemoteEntry>{};
    for (final entry in priorEntries) {
      if (entry.layout == MergeRemoteLayout.snapshotCommit &&
          entry.actor == uploaded.actor &&
          entry.counter < uploaded.counter &&
          entry.filename.endsWith('.json')) {
        candidatesByPath.putIfAbsent(entry.filename, () => entry);
      }
    }
    final candidates = candidatesByPath.values.toList()
      ..sort((a, b) {
        final counterOrder = b.counter.compareTo(a.counter);
        if (counterOrder != 0) return counterOrder;
        final digestOrder = a.digest.compareTo(b.digest);
        if (digestOrder != 0) return digestOrder;
        return a.filename.compareTo(b.filename);
      });

    var retainedValidPredecessor = false;
    for (final prior in candidates) {
      final MergeBatch oldBatch;
      try {
        oldBatch = await download(prior);
      } on MergeRemoteCorruptException catch (error) {
        _recordWarning(
          'Retaining predecessor ${prior.filename}: ${error.message}',
        );
        continue;
      } on MergeRemoteException catch (error) {
        if (error.statusCode == 404) continue;
        _recordWarning(
          'Retaining predecessor ${prior.filename}: ${error.message}',
        );
        continue;
      } on FormatException catch (error) {
        _recordWarning(
          'Retaining invalid predecessor ${prior.filename}: $error',
        );
        continue;
      }

      // Keep the newest valid predecessor so a corrupt new manifest can fall
      // back even when this old commit has a strong validator.
      if (!retainedValidPredecessor) {
        retainedValidPredecessor = true;
        continue;
      }
      if (!uploaded.document.dominates(oldBatch.document)) {
        _recordWarning(
          'Retaining predecessor ${prior.filename}: not fully dominated by published checkpoint',
        );
        continue;
      }
      final strong = strongEtag(prior.eTag);
      if (strong == null) continue;

      final remotePath = _resolvePath(prior);
      try {
        final response = await _client.c.req(
          _client,
          'DELETE',
          remotePath,
          optionsHandler: (options) {
            options.headers ??= {};
            options.headers!['If-Match'] = strong;
          },
        );
        if (![200, 204, 404, 412].contains(response.statusCode)) {
          _recordWarning(
            'Compaction DELETE failed for $remotePath: HTTP ${response.statusCode}',
          );
        }
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status != 404 && status != 412) {
          _recordWarning(
            'Compaction DELETE failed for $remotePath: ${error.message}',
          );
        }
      }
    }
    // Immutable content objects are retained because WebDAV offers no atomic
    // concurrency guard proving that an apparently unused object stays unused.
  }
}
