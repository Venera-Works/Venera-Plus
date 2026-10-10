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
import 'sync_pack.dart';
import 'sync_pack_cache.dart';

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

enum MergeRemoteLayout { packCommit }

/// Metadata representation of a remote Pack commit candidate file.
class MergeRemoteEntry {
  /// Full relative path below the WebDAV endpoint.
  final String filename;

  /// Actor read from the owning device directory's `device.json`.
  final String actor;

  /// The monotonic publication counter for [actor].
  final int counter;

  /// Lowercase 64-character SHA-256 digest of manifest bytes.
  final String digest;

  /// Optional remote HTTP ETag returned by directory listing or HEAD/GET.
  final String? eTag;

  /// Server publication time, used only to order concurrent cloud choices.
  final DateTime? modifiedAt;

  /// The only supported remote wire layout.
  final MergeRemoteLayout layout;

  const MergeRemoteEntry({
    required this.filename,
    required this.actor,
    required this.counter,
    required this.digest,
    this.eTag,
    this.modifiedAt,
    this.layout = MergeRemoteLayout.packCommit,
  });

  /// Regex validating safe actor identifiers used in commit payloads.
  static final RegExp _actorRegex = RegExp(r'^[a-zA-Z0-9_\-]+$');

  /// Regex matching `<counter>-<sha256>.json`.
  static final RegExp _entryRegex = RegExp(r'^(\d+)-([0-9a-fA-F]{64})\.json$');

  /// Parses a `VeneraPlus/<device>/commits/<counter>-<hash>.json` Pack commit.
  static MergeRemoteEntry? tryParsePackCommit(
    String fullPath, {
    required String actor,
    String? eTag,
    DateTime? modifiedAt,
  }) {
    final segments = fullPath.split('/');
    if (segments.length != 4 ||
        segments[0] != 'VeneraPlus' ||
        !_isSafeDeviceDirectoryName(segments[1]) ||
        segments[2] != 'commits' ||
        !_actorIsSafe(actor)) {
      return null;
    }
    final match = _entryRegex.firstMatch(segments[3]);
    if (match == null || match.group(0) != segments[3]) return null;
    final counter = int.tryParse(match.group(1)!);
    final digest = match.group(2)!.toLowerCase();
    if (counter == null || counter <= 0) return null;
    return MergeRemoteEntry(
      filename: fullPath,
      actor: actor,
      counter: counter,
      digest: digest,
      eTag: eTag,
      modifiedAt: modifiedAt,
      layout: MergeRemoteLayout.packCommit,
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
          modifiedAt == other.modifiedAt &&
          layout == other.layout;

  @override
  int get hashCode =>
      Object.hash(filename, actor, counter, digest, eTag, modifiedAt, layout);

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

class _RemoteOperation {
  final verifiedCollections = <String>{};
  final verifiedRemoteObjects = <String>{};
  final packChecks = <String, bool>{};
}

Future<void> _runBounded<T>(
  List<T> items,
  Future<void> Function(T item) action, {
  int concurrency = 4,
}) async {
  if (items.isEmpty) return;
  final workerCount = math.min(concurrency, items.length);
  var nextIndex = 0;
  Object? firstError;
  StackTrace? firstStack;

  Future<void> worker() async {
    while (firstError == null && nextIndex < items.length) {
      final item = items[nextIndex++];
      try {
        await action(item);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
  }

  await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
}

class _RequestMethodCounter extends Interceptor {
  final Map<String, int> counts = {};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final method = options.method.toUpperCase();
    counts.update(method, (count) => count + 1, ifAbsent: () => 1);
    handler.next(options);
  }

  Map<String, int> delta(Map<String, int> baseline) => Map.unmodifiable({
    for (final entry in counts.entries)
      if (entry.value > (baseline[entry.key] ?? 0))
        entry.key: entry.value - (baseline[entry.key] ?? 0),
  });
}

class _DeviceOwnership {
  const _DeviceOwnership({required this.actor, required this.name});

  final String actor;
  final String name;
}

/// Remote WebDAV transport for VeneraPlus multi-device merge sync.
///
/// Publications use immutable content-addressed Packs and four-segment commit paths.
class MergeRemote {
  MergeRemote(
    this._client, {
    String deviceName = 'Device',
    this.onWarning,
    Directory? cacheDirectory,
  }) : deviceName = normalizeSyncDeviceName(deviceName) {
    _requestCounter = _counterFor(_client.c);
    _requestCountBaseline = Map.of(_requestCounter.counts);
    final root = cacheDirectory;
    _packCache = root == null
        ? null
        : SyncPackCache(Directory(p.join(root.path, 'sync-v5-packs')));
    _packCacheHitBaseline = _packCache?.hits ?? 0;
    _packCacheInvalidationBaseline = _packCache?.invalidations ?? 0;
  }

  static const String _namespace = 'VeneraPlus';
  static const String _markerName = 'device.json';
  static const int _maxParallelTransfers = 4;
  static const int _maxCompactionCandidates = 64;
  static const Duration _maxCompactionDuration = Duration(seconds: 2);
  static final Expando<_RequestMethodCounter> _requestCounters = Expando();
  static _RequestMethodCounter _counterFor(Dio dio) {
    final existing = _requestCounters[dio];
    if (existing != null) return existing;
    final created = _RequestMethodCounter();
    _requestCounters[dio] = created;
    dio.interceptors.add(created);
    return created;
  }

  final dav.Client _client;
  late final SyncPackCache? _packCache;
  late final _RequestMethodCounter _requestCounter;
  late Map<String, int> _requestCountBaseline;
  int _packCacheHitBaseline = 0;
  int _packCacheInvalidationBaseline = 0;
  final String deviceName;

  /// Optional callback to observe non-fatal warnings (e.g. compaction skips).
  final void Function(String warning)? onWarning;

  /// Observable record of non-fatal operational warnings.
  final List<String> warnings = [];
  final Map<String, String> _deviceNames = {};
  static const int _maxInMemoryPublicationManifests = 4;
  final Map<String, SyncPackManifest> _publicationManifests = {};
  int _uploadedBytes = 0;
  int _downloadedBytes = 0;
  int _uploadedObjects = 0;
  int _downloadedObjects = 0;
  int _missingObjects = 0;
  int _directoryChecks = 0;
  int _retries = 0;
  int _deviceCount = 0;
  int _candidateCommits = 0;
  int _compressedBytes = 0;
  int _uncompressedBytes = 0;

  dav.Client get client => _client;
  Map<String, String> get deviceNames => Map.unmodifiable(_deviceNames);

  /// Bytes successfully written/downloaded, including verification read-backs.
  int get uploadedBytes => _uploadedBytes;
  int get downloadedBytes => _downloadedBytes;

  /// Content Packs/objects actually sent or fetched; manifests are excluded.
  int get uploadedObjects => _uploadedObjects;
  int get downloadedObjects => _downloadedObjects;

  /// Sanitized aggregate counters. No path, actor, headers, or payload is exposed.
  Map<String, Object?> get transferStats => Map.unmodifiable({
    'requestCounts': _requestCounter.delta(_requestCountBaseline),
    'cacheHits': (_packCache?.hits ?? 0) - _packCacheHitBaseline,
    'cacheInvalidations':
        (_packCache?.invalidations ?? 0) - _packCacheInvalidationBaseline,
    'missingObjects': _missingObjects,
    'directoryChecks': _directoryChecks,
    'retries': _retries,
    'deviceCount': _deviceCount,
    'candidateCommits': _candidateCommits,
    'compressedBytes': _compressedBytes,
    'uncompressedBytes': _uncompressedBytes,
    'uploadedBytes': _uploadedBytes,
    'downloadedBytes': _downloadedBytes,
    'uploadedObjects': _uploadedObjects,
    'downloadedObjects': _downloadedObjects,
  });

  /// Resets sync-run counters without clearing verified content-address cache.
  void resetTransferStats() {
    _uploadedBytes = 0;
    _downloadedBytes = 0;
    _uploadedObjects = 0;
    _downloadedObjects = 0;

    _missingObjects = 0;
    _directoryChecks = 0;
    _retries = 0;
    _deviceCount = 0;
    _candidateCommits = 0;
    _compressedBytes = 0;
    _uncompressedBytes = 0;
    _requestCountBaseline = Map.of(_requestCounter.counts);
    _packCacheHitBaseline = _packCache?.hits ?? 0;
    _packCacheInvalidationBaseline = _packCache?.invalidations ?? 0;
  }

  void _recordWarning(String message) {
    warnings.add(message);
    onWarning?.call(message);
  }

  String _deviceDirectoryPath(String name) => '$_namespace/$name';

  String _markerPath(String name) =>
      '${_deviceDirectoryPath(name)}/$_markerName';

  /// Validates a complete commit path rather than silently rebasing it.
  String _resolvePath(MergeRemoteEntry entry) {
    final parsed = MergeRemoteEntry.tryParsePackCommit(
      entry.filename,
      actor: entry.actor,
    );
    if (parsed == null ||
        parsed.counter != entry.counter ||
        parsed.digest != entry.digest.toLowerCase()) {
      throw const FormatException('Invalid remote commit path or metadata');
    }
    return parsed.filename;
  }

  Future<void> _verifyEntryOwnership(MergeRemoteEntry entry) async {
    final segments = entry.filename.split('/');
    final owner = await _readDeviceOwnership(segments[1]);
    if (owner == null || owner.actor != entry.actor) {
      throw const MergeRemoteCorruptException(
        'Remote commit ownership metadata mismatch',
      );
    }
  }

  Future<void> _ensureCollection(
    String path, {
    _RemoteOperation? operation,
  }) async {
    if (operation?.verifiedCollections.contains(path) ?? false) return;
    _directoryChecks++;
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
          'Failed to verify WebDAV collection',
          statusCode: 404,
          cause: e,
        );
      }
      rethrow;
    }
    operation?.verifiedCollections.add(path);
  }

  Future<void> _ensureNamespaceDirectory({_RemoteOperation? operation}) =>
      _ensureCollection(_namespace, operation: operation);

  Future<_DeviceOwnership?> _readDeviceOwnership(
    String directoryName, {
    bool ignoreInvalid = false,
  }) async {
    final path = _markerPath(directoryName);
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
    String actor,
  ) async {
    final markerBytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'actor': actor, 'name': directoryName})),
    );
    Response? response;
    try {
      response = await _client.c.req(
        _client,
        'PUT',
        _markerPath(directoryName),
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

    final owner = await _readDeviceOwnership(directoryName);
    if (owner == null) {
      throw const MergeRemoteConflictException(
        'Device ownership marker was not visible after claim',
      );
    }
    return owner;
  }

  Future<String> _ensureDeviceDirectory(
    String actor, {
    _RemoteOperation? operation,
  }) async {
    await _ensureNamespaceDirectory(operation: operation);

    var directoryName = deviceName;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _ensureCollection(
        _deviceDirectoryPath(directoryName),
        operation: operation,
      );
      var owner = await _readDeviceOwnership(directoryName);
      owner ??= await _claimDeviceOwnership(directoryName, actor);
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
      throw const MergeRemoteConflictException(
        'Device directory ownership collision',
      );
    }
    throw const MergeRemoteConflictException(
      'Unable to resolve device directory ownership collision',
    );
  }

  /// Lists all immutable Pack commits, retaining older candidates for recovery.
  Future<List<MergeRemoteEntry>> list({bool latestOnly = false}) async {
    _deviceNames.clear();
    List<dav.File> deviceDirectories;
    try {
      deviceDirectories = await _client.readDir(_namespace);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        _deviceCount = 0;
        _candidateCommits = 0;
        return const [];
      }
      rethrow;
    }

    final entries = <MergeRemoteEntry>[];
    _deviceCount = 0;
    for (final directory in deviceDirectories) {
      if (directory.isDir != true) continue;
      final directoryName = directory.name;
      if (directoryName == null ||
          const {'sync-v4', 'sync-v5'}.contains(directoryName.toLowerCase()) ||
          !_isSafeDeviceDirectoryName(directoryName)) {
        continue;
      }
      final owner = await _readDeviceOwnership(
        directoryName,
        ignoreInvalid: true,
      );
      if (owner == null) continue;
      _deviceCount++;
      _deviceNames[owner.actor] = owner.name;

      final List<dav.File> commitFiles;
      try {
        commitFiles = await _client.readDir(
          '${_deviceDirectoryPath(directoryName)}/commits',
        );
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) continue;
        rethrow;
      }
      for (final file in commitFiles) {
        if (file.isDir == true || file.name == null || file.size == 0) continue;
        final entry = MergeRemoteEntry.tryParsePackCommit(
          '$_namespace/$directoryName/commits/${file.name}',
          actor: owner.actor,
          eTag: file.eTag,
          modifiedAt: file.mTime,
        );
        if (entry != null) entries.add(entry);
      }
    }

    entries.sort((a, b) {
      final actorOrder = a.actor.compareTo(b.actor);
      if (actorOrder != 0) return actorOrder;
      final counterOrder = b.counter.compareTo(a.counter);
      if (counterOrder != 0) return counterOrder;
      final digestOrder = a.digest.compareTo(b.digest);
      if (digestOrder != 0) return digestOrder;
      return a.filename.compareTo(b.filename);
    });
    _candidateCommits = entries.length;
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

  /// Convenience helper to list only the highest-counter candidates.
  Future<List<MergeRemoteEntry>> listLatest() => list(latestOnly: true);

  /// Downloads one immutable Pack commit and all referenced Packs.
  Future<MergeBatch> download(MergeRemoteEntry entry) =>
      _downloadPackCommit(entry);

  Future<MergeBatch> _downloadPackCommit(MergeRemoteEntry entry) async {
    final remotePath = _resolvePath(entry);
    await _verifyEntryOwnership(entry);
    final Uint8List manifestBytes;
    try {
      manifestBytes = await _downloadRawBytes(
        remotePath,
        maxBytes: SyncPackManifest.maxManifestBytes,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        throw const MergeRemoteCorruptException(
          'Pack commit is missing',
          statusCode: 404,
        );
      }
      throw MergeRemoteException(
        'Failed to download Pack commit',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on MergeRemoteException catch (error) {
      if (error.statusCode == 404) {
        throw MergeRemoteCorruptException(
          'Pack commit is missing',
          statusCode: 404,
          cause: error,
        );
      }
      rethrow;
    }
    if (sha256.convert(manifestBytes).toString() != entry.digest) {
      throw const MergeRemoteCorruptException('Pack commit digest mismatch');
    }

    final SyncPackManifest manifest;
    try {
      manifest = SyncPackManifest.parse(manifestBytes);
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'Pack commit manifest is invalid',
        cause: error,
      );
    }
    if (manifest.actor != entry.actor ||
        manifest.counter != entry.counter ||
        manifest.digest != entry.digest) {
      throw const MergeRemoteCorruptException(
        'Pack commit metadata does not match its filename',
      );
    }

    final basePath = remotePath.substring(
      0,
      remotePath.lastIndexOf('/commits/'),
    );
    final packs = <String, SyncPack>{};
    await _runBounded<String>(manifest.packs.keys.toList(growable: false), (
      digest,
    ) async {
      final expectedSize = manifest.packs[digest]!;
      SyncPack? pack;
      try {
        pack = await _packCache?.read(digest, expectedSize: expectedSize);
      } on FileSystemException {
        pack = null;
      }
      if (pack != null) {
        packs[digest] = pack;
        return;
      }

      final packPath = '$basePath/packs/$digest.pack';
      final Uint8List bytes;
      try {
        bytes = await _downloadRawBytes(
          packPath,
          maxBytes: expectedSize,
          countAsObject: true,
        );
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) {
          _missingObjects++;
          throw MergeRemoteCorruptException(
            'Referenced Pack is missing',
            statusCode: 404,
            cause: error,
          );
        }
        throw MergeRemoteException(
          'Failed to download referenced Pack',
          statusCode: error.response?.statusCode,
          cause: error,
        );
      } on MergeRemoteException catch (error) {
        if (error.statusCode == 404) {
          _missingObjects++;
          throw MergeRemoteCorruptException(
            'Referenced Pack is missing',
            statusCode: 404,
            cause: error,
          );
        }
        rethrow;
      }
      if (bytes.length != expectedSize) {
        throw const MergeRemoteCorruptException(
          'Referenced Pack size mismatch',
        );
      }
      try {
        pack = SyncPack.decode(bytes, expectedDigest: digest);
      } on FormatException catch (error) {
        throw MergeRemoteCorruptException(
          'Referenced Pack is corrupt',
          cause: error,
        );
      }
      packs[digest] = pack;
      try {
        await _packCache?.write(pack);
      } on FileSystemException {
        // A verified network Pack remains usable when its cache is unwritable.
      }
    });

    final MergeBatch batch;
    try {
      batch = manifest.decode(packs);
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'Pack commit or Pack indexes failed validation',
        cause: error,
      );
    }
    if (batch.actor != entry.actor ||
        batch.counter != entry.counter ||
        batch.id != manifest.batchId) {
      throw const MergeRemoteCorruptException(
        'Pack commit document identity mismatch',
      );
    }
    for (final object in manifest.objects) {
      _compressedBytes += object['compressedSize']! as int;
      _uncompressedBytes += object['uncompressedSize']! as int;
    }

    return batch;
  }

  /// Downloads the latest valid Pack commit for [actor] from [candidates].
  ///
  /// Candidates are tried in descending counter order. A corrupt or incomplete
  /// candidate is skipped so an older verified predecessor remains available.
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
        _recordWarning('Skipping a corrupt remote Pack commit candidate');
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

  /// Uploads all missing immutable Packs first, then publishes the Pack commit.
  Future<String> upload(MergeBatch batch) async {
    return uploadSnapshot(MergeSnapshot.fromBatch(batch));
  }

  /// Publishes a logical causal snapshot as an immutable Pack commit.
  Future<String> uploadSnapshot(MergeSnapshot snapshot) async {
    final sourceManifest = snapshot.manifest;
    final actor = sourceManifest['actor'];
    final counter = sourceManifest['counter'];
    final batchId = sourceManifest['batchId'];
    if (actor is! String ||
        !_actorIsSafe(actor) ||
        counter is! int ||
        counter <= 0 ||
        batchId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(batchId) ||
        sourceManifest['schema'] != 1 ||
        sourceManifest['documentSchema'] != 3) {
      throw const FormatException('Invalid snapshot publication metadata');
    }

    await _client.ping();
    final operation = _RemoteOperation();
    final directoryName = await _ensureDeviceDirectory(
      actor,
      operation: operation,
    );
    final basePath = '$_namespace/$directoryName';
    await _ensureCollection('$basePath/commits', operation: operation);
    await _ensureCollection('$basePath/packs', operation: operation);

    final publicationKey = _publicationCacheKey(actor, directoryName);
    var previous = _publicationManifests.remove(publicationKey);
    if (previous != null) {
      _publicationManifests[publicationKey] = previous;
    } else {
      previous = await _packCache?.readManifest(publicationKey);
      if (previous != null) {
        _rememberPublicationManifest(publicationKey, previous);
      }
    }
    var packed = SyncPackSnapshot.fromSnapshot(snapshot, previous: previous);
    var packsToUpload = Map<String, SyncPack>.of(packed.packs);
    var repackAll = false;
    for (final packEntry in packed.manifest.packs.entries) {
      final digest = packEntry.key;
      if (packsToUpload.containsKey(digest)) continue;
      final cached = await _packCache?.read(
        digest,
        expectedSize: packEntry.value,
      );
      final remotePath = '$basePath/packs/$digest.pack';
      if (await _remotePackAvailable(
        remotePath,
        digest,
        packEntry.value,
        operation,
      )) {
        continue;
      }
      if (cached != null &&
          cached.digest == digest &&
          cached.bytes.length == packEntry.value) {
        packsToUpload[digest] = cached;
      } else {
        repackAll = true;
      }
    }
    if (repackAll) {
      packed = SyncPackSnapshot.fromSnapshot(snapshot);
      packsToUpload = Map<String, SyncPack>.of(packed.packs);
    }

    final manifest = packed.manifest;
    final manifestBytes = packed.serializeManifest();
    final manifestDigest = packed.digest;
    for (final object in manifest.objects) {
      _compressedBytes += object['compressedSize']! as int;
      _uncompressedBytes += object['uncompressedSize']! as int;
    }
    await _runBounded<SyncPack>(
      packsToUpload.values.toList(growable: false),
      (pack) async {
        final path = '$basePath/packs/${pack.digest}.pack';
        await _publishImmutable(
          path,
          pack.bytes,
          pack.digest,
          operation: operation,
          countAsObject: true,
        );
        try {
          await _packCache?.write(pack);
        } on FileSystemException {
          // Network publication remains authoritative if the hint cache fails.
        }
      },
      concurrency: _maxParallelTransfers,
    );

    // Manifest-last is the atomic visibility boundary for a Pack commit.
    final commitPath = '$basePath/commits/$counter-$manifestDigest.json';
    await _publishImmutable(
      commitPath,
      manifestBytes,
      manifestDigest,
      operation: operation,
    );
    _rememberPublicationManifest(publicationKey, manifest);
    try {
      await _packCache?.writeManifest(publicationKey, manifest);
    } on FileSystemException {
      // The persisted publication map is a rebuildable incremental hint.
    }
    return commitPath;
  }

  String _publicationCacheKey(String actor, String directoryName) {
    final endpoint = sha256
        .convert(utf8.encode(_client.c.options.baseUrl))
        .toString();
    return '$_namespace/$endpoint/$actor/$directoryName';
  }

  void _rememberPublicationManifest(String key, SyncPackManifest manifest) {
    _publicationManifests.remove(key);
    _publicationManifests[key] = manifest;
    while (_publicationManifests.length > _maxInMemoryPublicationManifests) {
      _publicationManifests.remove(_publicationManifests.keys.first);
    }
  }

  Future<bool> _remotePackAvailable(
    String path,
    String digest,
    int expectedSize,
    _RemoteOperation operation,
  ) async {
    final previous = operation.packChecks[path];
    if (previous != null) return previous;
    if (operation.verifiedRemoteObjects.contains(path)) {
      operation.packChecks[path] = true;
      return true;
    }
    bool available;
    try {
      final response = await _client.c.req(_client, 'HEAD', path);
      final status = response.statusCode;
      if (status == 404) {
        available = false;
      } else if (status == 405 || status == 501) {
        available = await _remotePayloadMatches(
          path,
          expectedSize,
          digest,
          operation: operation,
          countAsObject: true,
        );
      } else if (status != 200) {
        throw MergeRemoteException(
          'Failed to verify remote Pack',
          statusCode: status,
        );
      } else {
        available = await _remotePayloadMatches(
          path,
          expectedSize,
          digest,
          operation: operation,
          countAsObject: true,
        );
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 404) {
        available = false;
      } else if (status == 405 || status == 501) {
        available = await _remotePayloadMatches(
          path,
          expectedSize,
          digest,
          operation: operation,
          countAsObject: true,
        );
      } else {
        throw MergeRemoteException(
          'Failed to verify remote Pack',
          statusCode: status,
          cause: error,
        );
      }
    }
    operation.packChecks[path] = available;
    return available;
  }

  Future<bool> _remotePayloadMatches(
    String path,
    int expectedSize,
    String expectedDigest, {
    _RemoteOperation? operation,
    bool countAsObject = false,
  }) async {
    final bytes = await (() async {
      try {
        return await _downloadRawBytes(
          path,
          maxBytes: expectedSize,
          countAsObject: countAsObject,
        );
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) return null;
        throw MergeRemoteException(
          'Failed to verify remote immutable payload',
          statusCode: error.response?.statusCode,
          cause: error,
        );
      } on MergeRemoteException catch (error) {
        if (error.statusCode == 404) return null;
        if (error is MergeRemoteCorruptException) return null;
        rethrow;
      }
    })();
    if (bytes == null ||
        bytes.length != expectedSize ||
        sha256.convert(bytes).toString() != expectedDigest) {
      return false;
    }
    operation?.verifiedRemoteObjects.add(path);
    return true;
  }

  Future<void> _publishImmutable(
    String path,
    Uint8List bytes,
    String expectedDigest, {
    _RemoteOperation? operation,
    bool countAsObject = false,
  }) async {
    if (bytes.isEmpty || sha256.convert(bytes).toString() != expectedDigest) {
      throw const FormatException('Local immutable payload digest mismatch');
    }
    if (operation?.verifiedRemoteObjects.contains(path) ?? false) return;
    final isPack = path.endsWith('.pack');
    final maxReadbackBytes = isPack
        ? SyncPack.maxPackBytes
        : SyncPackManifest.maxManifestBytes;

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
          options.headers!['content-type'] = isPack
              ? 'application/octet-stream'
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
      if (countAsObject) _uploadedObjects++;
      final readBack = await _downloadRawBytes(
        path,
        maxBytes: maxReadbackBytes,
        countAsObject: countAsObject,
      );
      if (!_bytesEqual(readBack, bytes) ||
          sha256.convert(readBack).toString() != expectedDigest) {
        throw MergeRemoteCorruptException(
          'Uploaded immutable payload failed read-back verification',
          statusCode: status,
        );
      }
      operation?.verifiedRemoteObjects.add(path);
      return;
    }
    if (status != 412) {
      throw MergeRemoteException(
        'WebDAV immutable PUT failed',
        statusCode: status,
      );
    }

    _retries++;
    final existing = await _downloadRawBytes(
      path,
      maxBytes: maxReadbackBytes,
      countAsObject: countAsObject,
    );
    if (_bytesEqual(existing, bytes) &&
        sha256.convert(existing).toString() == expectedDigest) {
      operation?.verifiedRemoteObjects.add(path);
      return;
    }

    // Replacing a torn object is safe only with a strong validator.
    try {
      final head = await _client.c.req(_client, 'HEAD', path);
      final validator = strongEtag(head.headers.value('etag'));
      if (head.statusCode == 200 && validator != null) {
        final replacement = await _client.c.req(
          _client,
          'PUT',
          path,
          data: _streamBytes(bytes),
          optionsHandler: (options) {
            options.headers ??= {};
            options.headers!['If-Match'] = validator;
            options.headers!['content-length'] = bytes.length;
            options.headers!['content-type'] = isPack
                ? 'application/octet-stream'
                : 'application/json; charset=utf-8';
          },
        );
        if ([200, 201, 204].contains(replacement.statusCode)) {
          _uploadedBytes += bytes.length;
          if (countAsObject) _uploadedObjects++;
          final verified = await _downloadRawBytes(
            path,
            maxBytes: maxReadbackBytes,
            countAsObject: countAsObject,
          );
          if (_bytesEqual(verified, bytes) &&
              sha256.convert(verified).toString() == expectedDigest) {
            operation?.verifiedRemoteObjects.add(path);
            return;
          }
          throw const MergeRemoteCorruptException(
            'Conditionally repaired immutable payload failed verification',
          );
        }
      }
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      if (code != 412 && code != 404 && code != 405 && code != 501) rethrow;
    }
    throw const MergeRemoteConflictException(
      'Remote immutable payload differs; refusing unproven replacement',
      statusCode: 412,
    );
  }

  bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  /// Compacts bounded sets of own Pack commits after full causal verification.
  ///
  /// Weak/missing ETags are filtered before candidate downloads. Immutable Packs
  /// remain because commit enumeration cannot prove global liveness.
  Future<void> compact(
    MergeBatch uploaded,
    List<MergeRemoteEntry> priorEntries,
  ) async {
    final timer = Stopwatch()..start();
    final candidatesByPath = <String, MergeRemoteEntry>{};
    for (final entry in priorEntries) {
      if (entry.actor != uploaded.actor) continue;
      if (timer.elapsed >= _maxCompactionDuration) break;
      if (entry.layout != MergeRemoteLayout.packCommit ||
          entry.counter >= uploaded.counter ||
          !entry.filename.endsWith('.json') ||
          strongEtag(entry.eTag) == null) {
        continue;
      }
      if (candidatesByPath.length >= _maxCompactionCandidates &&
          !candidatesByPath.containsKey(entry.filename)) {
        continue;
      }
      candidatesByPath.putIfAbsent(entry.filename, () => entry);
    }
    final candidates = candidatesByPath.values.toList()
      ..sort((a, b) {
        final counterOrder = b.counter.compareTo(a.counter);
        if (counterOrder != 0) return counterOrder;
        final digestOrder = a.digest.compareTo(b.digest);
        if (digestOrder != 0) return digestOrder;
        return a.filename.compareTo(b.filename);
      });
    if (candidates.isEmpty || timer.elapsed >= _maxCompactionDuration) return;

    var retainedValidPredecessor = false;
    for (final prior in candidates) {
      if (timer.elapsed >= _maxCompactionDuration) break;
      final MergeBatch oldBatch;
      try {
        oldBatch = await download(prior);
      } on TimeoutException {
        _recordWarning('Compaction time budget exhausted');
        break;
      } on MergeRemoteCorruptException {
        _recordWarning('Retaining a corrupt predecessor Pack commit');
        continue;
      } on MergeRemoteException catch (error) {
        if (error.statusCode == 404) continue;
        _recordWarning('Compaction stopped after a remote service failure');
        break;
      } on FormatException {
        _recordWarning('Retaining an invalid predecessor Pack commit');
        continue;
      }
      if (timer.elapsed >= _maxCompactionDuration) {
        _recordWarning('Compaction time budget exhausted');
        break;
      }

      if (!retainedValidPredecessor) {
        retainedValidPredecessor = true;
        continue;
      }
      if (!uploaded.document.dominates(oldBatch.document)) {
        _recordWarning(
          'Retaining a predecessor not dominated by the checkpoint',
        );
        continue;
      }
      final strong = strongEtag(prior.eTag);
      if (strong == null) continue;

      final remotePath = _resolvePath(prior);
      try {
        if (timer.elapsed >= _maxCompactionDuration) break;
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
          _recordWarning('Compaction conditional delete failed');
        }
      } on TimeoutException {
        _recordWarning('Compaction time budget exhausted');
        break;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status != 404 && status != 412) {
          _recordWarning('Compaction conditional delete failed');
        }
      }
    }
  }
}
