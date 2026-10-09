import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' as dav;

import '../../foundation/sync_records.dart';
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

enum MergeRemoteLayout { legacyCheckpoint, snapshotCommit, packCommit }

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

  /// Parses a v5 `VeneraPlus/sync-v5/<device>/commits/<counter>-<hash>.json`.
  static MergeRemoteEntry? tryParsePackCommit(
    String fullPath, {
    required String actor,
    String? eTag,
  }) {
    final segments = fullPath.split('/');
    if (segments.length != 5 ||
        segments[0] != 'VeneraPlus' ||
        segments[1] != 'sync-v5' ||
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
          layout == other.layout;

  @override
  int get hashCode =>
      Object.hash(filename, actor, counter, digest, eTag, layout);

  @override
  String toString() =>
      'MergeRemoteEntry(filename: $filename, actor: $actor, counter: $counter, digest: $digest, eTag: $eTag, layout: $layout)';
}

/// Immutable record of a frozen v4 inventory and its independently verified
/// v5 publication proof. Import receipts contain cumulative inventories.
class MergeRemoteV4Archive {
  MergeRemoteV4Archive({
    required List<MergeRemoteEntry> inventory,
    required MergeRemoteEntry proof,
  }) : this._(inventory: inventory, proofs: [proof]);

  MergeRemoteV4Archive._({
    required List<MergeRemoteEntry> inventory,
    required List<MergeRemoteEntry> proofs,
  }) : inventory = _freezeV4Inventory(inventory),
       proofs = List.unmodifiable(proofs.map(_withoutEtag).toList()) {
    if (this.proofs.isEmpty ||
        this.proofs.any((entry) {
          final parsed = MergeRemoteEntry.tryParsePackCommit(
            entry.filename,
            actor: entry.actor,
          );
          return entry.layout != MergeRemoteLayout.packCommit ||
              parsed == null ||
              parsed.counter != entry.counter ||
              parsed.digest != entry.digest.toLowerCase();
        })) {
      throw ArgumentError('V4 archive requires valid v5 proof commits');
    }
  }

  final List<MergeRemoteEntry> inventory;
  final List<MergeRemoteEntry> proofs;

  /// Most recently enumerated accepted proof; [proofs] preserves all receipts.
  MergeRemoteEntry get proof => proofs.last;

  static MergeRemoteV4Archive fromValidatedReceipts(
    Iterable<MergeRemoteV4Archive> receipts,
  ) {
    final inventoryByPath = <String, MergeRemoteEntry>{};
    final proofsByPath = <String, MergeRemoteEntry>{};
    for (final receipt in receipts) {
      for (final entry in receipt.inventory) {
        final previous = inventoryByPath[entry.filename];
        if (previous != null && !_sameArchiveEntry(previous, entry)) {
          throw const FormatException(
            'Conflicting entries in frozen v4 archive inventory',
          );
        }
        inventoryByPath[entry.filename] = entry;
      }
      for (final proof in receipt.proofs) {
        proofsByPath[proof.filename] = proof;
      }
    }
    if (proofsByPath.isEmpty) {
      throw ArgumentError('Cannot build an archive without verified proofs');
    }
    final orderedProofs = proofsByPath.values.toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));
    return MergeRemoteV4Archive._(
      inventory: inventoryByPath.values.toList(),
      proofs: orderedProofs,
    );
  }

  static List<MergeRemoteEntry> _freezeV4Inventory(
    List<MergeRemoteEntry> entries,
  ) {
    final byPath = <String, MergeRemoteEntry>{};
    for (final entry in entries) {
      final parsed = MergeRemoteEntry.tryParseSnapshot(
        entry.filename,
        actor: entry.actor,
      );
      if (entry.layout != MergeRemoteLayout.snapshotCommit ||
          parsed == null ||
          parsed.counter != entry.counter ||
          parsed.digest != entry.digest.toLowerCase()) {
        throw ArgumentError.value(
          entry,
          'inventory',
          'Expected valid v4 commits',
        );
      }
      final normalized = _withoutEtag(entry);
      final previous = byPath[entry.filename];
      if (previous != null && !_sameArchiveEntry(previous, normalized)) {
        throw ArgumentError.value(entry, 'inventory', 'Conflicting v4 path');
      }
      byPath[entry.filename] = normalized;
    }
    final result = byPath.values.toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));
    return List.unmodifiable(result);
  }

  static MergeRemoteEntry _withoutEtag(MergeRemoteEntry entry) =>
      MergeRemoteEntry(
        filename: entry.filename,
        actor: entry.actor,
        counter: entry.counter,
        digest: entry.digest,
        layout: entry.layout,
      );

  static bool _sameArchiveEntry(
    MergeRemoteEntry left,
    MergeRemoteEntry right,
  ) =>
      left.filename == right.filename &&
      left.actor == right.actor &&
      left.counter == right.counter &&
      left.digest == right.digest &&
      left.layout == right.layout;
}

bool _sameV4Inventories(
  List<MergeRemoteEntry> left,
  List<MergeRemoteEntry> right,
) {
  final normalizedLeft = MergeRemoteV4Archive._freezeV4Inventory(left);
  final normalizedRight = MergeRemoteV4Archive._freezeV4Inventory(right);
  if (normalizedLeft.length != normalizedRight.length) return false;
  for (var index = 0; index < normalizedLeft.length; index++) {
    if (!MergeRemoteV4Archive._sameArchiveEntry(
      normalizedLeft[index],
      normalizedRight[index],
    )) {
      return false;
    }
  }
  return true;
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
  final validatedArchiveProofs = <String>{};
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
/// New publications use immutable sync-v5 content-addressed Packs. The v4
/// snapshot and legacy checkpoint layouts remain explicit read-only paths.
class MergeRemote {
  MergeRemote(
    this._client, {
    String deviceName = 'Device',
    this.onWarning,
    Directory? cacheDirectory,
  }) : deviceName = normalizeSyncDeviceName(deviceName),
       _cacheDirectory = cacheDirectory {
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
  static const String _v4Namespace = 'VeneraPlus/sync-v4';
  static const String _snapshotNamespace = 'VeneraPlus/sync-v5';
  static const String _markerName = 'device.json';
  static const String _v4ArchiveName = 'archive-v4.json';
  static const String _v4ImportDirectory = 'archive-v4-imports';
  static const int _maxVerifiedObjectCacheBytes = 64 * 1024 * 1024;
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
  final Directory? _cacheDirectory;
  late final SyncPackCache? _packCache;
  late final _RequestMethodCounter _requestCounter;
  late Map<String, int> _requestCountBaseline;
  int _packCacheHitBaseline = 0;
  int _packCacheInvalidationBaseline = 0;
  int _cacheTempSequence = 0;
  final String deviceName;

  /// Optional callback to observe non-fatal warnings (e.g. compaction skips).
  final void Function(String warning)? onWarning;

  /// Observable record of non-fatal operational warnings.
  final List<String> warnings = [];
  final Map<String, String> _deviceNames = {};
  static const int _maxInMemoryPublicationManifests = 4;
  final Map<String, SyncPackManifest> _publicationManifests = {};
  final Map<String, Uint8List> _verifiedObjects = {};
  int _verifiedObjectCacheBytes = 0;
  int? _persistentObjectCacheBytes;
  int _uploadedBytes = 0;
  int _downloadedBytes = 0;
  int _uploadedObjects = 0;
  int _downloadedObjects = 0;
  int _cacheHits = 0;
  int _cacheInvalidations = 0;
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
    'cacheHits': _cacheHits + (_packCache?.hits ?? 0) - _packCacheHitBaseline,
    'cacheInvalidations':
        _cacheInvalidations +
        (_packCache?.invalidations ?? 0) -
        _packCacheInvalidationBaseline,
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
    _cacheHits = 0;
    _cacheInvalidations = 0;
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

  String _deviceDirectoryPath(String name, {String namespace = _namespace}) =>
      '$namespace/$name';

  String _markerPath(String name, {String namespace = _namespace}) =>
      '${_deviceDirectoryPath(name, namespace: namespace)}/$_markerName';

  /// Validates a complete checkpoint/commit path rather than silently rebasing it.
  String _resolvePath(MergeRemoteEntry entry) {
    final parsed = switch (entry.layout) {
      MergeRemoteLayout.legacyCheckpoint => MergeRemoteEntry.tryParse(
        entry.filename,
        actor: entry.actor,
      ),
      MergeRemoteLayout.snapshotCommit => MergeRemoteEntry.tryParseSnapshot(
        entry.filename,
        actor: entry.actor,
      ),
      MergeRemoteLayout.packCommit => MergeRemoteEntry.tryParsePackCommit(
        entry.filename,
        actor: entry.actor,
      ),
    };
    if (parsed == null ||
        parsed.layout != entry.layout ||
        parsed.counter != entry.counter ||
        parsed.digest != entry.digest.toLowerCase()) {
      throw const FormatException('Invalid remote commit path or metadata');
    }
    return parsed.filename;
  }

  Future<void> _verifyEntryOwnership(MergeRemoteEntry entry) async {
    final segments = entry.filename.split('/');
    final namespace = switch (entry.layout) {
      MergeRemoteLayout.legacyCheckpoint => _namespace,
      MergeRemoteLayout.snapshotCommit => _v4Namespace,
      MergeRemoteLayout.packCommit => _snapshotNamespace,
    };
    final directoryName = segments[namespace == _namespace ? 1 : 2];
    final owner = await _readDeviceOwnership(
      directoryName,
      namespace: namespace,
    );
    if (owner == null || owner.actor != entry.actor) {
      throw const MergeRemoteCorruptException(
        'Remote checkpoint ownership metadata mismatch',
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

  Future<void> _ensureNamespaceDirectory({
    String namespace = _namespace,
    _RemoteOperation? operation,
  }) async {
    if (namespace != _namespace) {
      await _ensureCollection(_namespace, operation: operation);
    }
    await _ensureCollection(namespace, operation: operation);
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
    _RemoteOperation? operation,
  }) async {
    await _ensureNamespaceDirectory(namespace: namespace, operation: operation);

    var directoryName = deviceName;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _ensureCollection(
        _deviceDirectoryPath(directoryName, namespace: namespace),
        operation: operation,
      );
      // Ownership is read on every operation even when collection checks are
      // task-local cached.
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
      throw const MergeRemoteConflictException(
        'Device directory ownership collision',
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

  /// Lists v5 Pack commits. v4 candidates are available only through [listV4].
  Future<List<MergeRemoteEntry>> list({bool latestOnly = false}) =>
      _listCommits(namespace: _snapshotNamespace, latestOnly: latestOnly);

  /// Lists all v4 commits for explicit migration and frozen-inventory checks.
  Future<List<MergeRemoteEntry>> listV4({bool latestOnly = false}) =>
      _listCommits(namespace: _v4Namespace, latestOnly: latestOnly);

  Future<List<MergeRemoteEntry>> _listCommits({
    required String namespace,
    required bool latestOnly,
  }) async {
    _deviceNames.clear();
    List<dav.File> deviceDirectories;
    try {
      deviceDirectories = await _client.readDir(namespace);
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
      if (directoryName == null || !_isSafeDeviceDirectoryName(directoryName)) {
        continue;
      }
      final owner = await _readDeviceOwnership(
        directoryName,
        namespace: namespace,
        ignoreInvalid: true,
      );
      if (owner == null) continue;
      _deviceCount++;
      _deviceNames[owner.actor] = owner.name;

      final List<dav.File> commitFiles;
      try {
        commitFiles = await _client.readDir(
          '${_deviceDirectoryPath(directoryName, namespace: namespace)}/commits',
        );
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) continue;
        rethrow;
      }
      for (final file in commitFiles) {
        if (file.isDir == true || file.name == null || file.size == 0) continue;
        final path = '$namespace/$directoryName/commits/${file.name}';
        final entry = namespace == _v4Namespace
            ? MergeRemoteEntry.tryParseSnapshot(
                path,
                actor: owner.actor,
                eTag: file.eTag,
              )
            : MergeRemoteEntry.tryParsePackCommit(
                path,
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

  /// Convenience helper to list only the highest-counter v5 candidates.
  Future<List<MergeRemoteEntry>> listLatest() => list(latestOnly: true);

  Future<List<MergeRemoteEntry>> listLatestV4() => listV4(latestOnly: true);

  static const int _maxV4ArchiveBytes = 64 * 1024 * 1024;

  String get _v4ArchivePath => '$_snapshotNamespace/$_v4ArchiveName';

  String _v4ImportPath(String inventoryDigest) =>
      '$_snapshotNamespace/$_v4ImportDirectory/$inventoryDigest.json';

  Map<String, Object?> _archiveEntryJson(MergeRemoteEntry entry) => {
    'actor': entry.actor,
    'counter': entry.counter,
    'digest': entry.digest,
    'path': entry.filename,
  };

  Uint8List _serializeV4Archive(MergeRemoteV4Archive archive) =>
      Uint8List.fromList(
        utf8.encode(
          canonicalSyncJson({
            'schema': 1,
            'inventory': archive.inventory.map(_archiveEntryJson).toList(),
            'proof': _archiveEntryJson(archive.proof),
          }),
        ),
      );

  String _archiveInventoryDigest(MergeRemoteV4Archive archive) => sha256
      .convert(
        utf8.encode(
          canonicalSyncJson(archive.inventory.map(_archiveEntryJson).toList()),
        ),
      )
      .toString();

  MergeRemoteEntry _parseArchiveEntry(
    Object? value, {
    required MergeRemoteLayout layout,
  }) {
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        !value.keys.toSet().containsAll(const {
          'actor',
          'counter',
          'digest',
          'path',
        })) {
      throw const FormatException('Invalid v4 archive entry schema');
    }
    final actor = value['actor'];
    final counter = value['counter'];
    final digest = value['digest'];
    final path = value['path'];
    if (actor is! String ||
        counter is! int ||
        digest is! String ||
        path is! String) {
      throw const FormatException('Invalid v4 archive entry values');
    }
    final parsed = switch (layout) {
      MergeRemoteLayout.snapshotCommit => MergeRemoteEntry.tryParseSnapshot(
        path,
        actor: actor,
      ),
      MergeRemoteLayout.packCommit => MergeRemoteEntry.tryParsePackCommit(
        path,
        actor: actor,
      ),
      MergeRemoteLayout.legacyCheckpoint => null,
    };
    if (parsed == null ||
        parsed.counter != counter ||
        parsed.digest != digest.toLowerCase()) {
      throw const FormatException('Invalid v4 archive entry identity');
    }
    return parsed;
  }

  Future<MergeRemoteV4Archive?> _readV4ArchiveRecord(
    String path, {
    String? expectedInventoryDigest,
    required _RemoteOperation operation,
  }) async {
    final Uint8List markerBytes;
    try {
      markerBytes = await _downloadRawBytes(path, maxBytes: _maxV4ArchiveBytes);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      throw MergeRemoteException(
        'Failed to read v4 archive marker',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on MergeRemoteException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(markerBytes, allowMalformed: false));
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'V4 archive marker is invalid',
        cause: error,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        !decoded.keys.toSet().containsAll(const {
          'schema',
          'inventory',
          'proof',
        }) ||
        decoded['schema'] != 1 ||
        decoded['inventory'] is! List) {
      throw const MergeRemoteCorruptException(
        'V4 archive marker has an invalid schema',
      );
    }
    final inventory = <MergeRemoteEntry>[];
    try {
      for (final value in decoded['inventory'] as List) {
        inventory.add(
          _parseArchiveEntry(value, layout: MergeRemoteLayout.snapshotCommit),
        );
      }
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'V4 archive inventory is invalid',
        cause: error,
      );
    }
    final proof = _parseArchiveEntry(
      decoded['proof'],
      layout: MergeRemoteLayout.packCommit,
    );
    final archive = MergeRemoteV4Archive(inventory: inventory, proof: proof);
    if (!_bytesEqual(_serializeV4Archive(archive), markerBytes)) {
      throw const MergeRemoteCorruptException(
        'V4 archive marker is not canonical JSON',
      );
    }
    if (expectedInventoryDigest != null &&
        _archiveInventoryDigest(archive) != expectedInventoryDigest) {
      throw const MergeRemoteCorruptException(
        'V4 archive receipt path does not match its inventory',
      );
    }

    final markerDigest = sha256.convert(markerBytes).toString();
    final proofKey = '${proof.filename}:${proof.digest}:$markerDigest';
    if (operation.validatedArchiveProofs.add(proofKey)) {
      await _downloadPackCommit(proof);
    }
    return archive;
  }

  /// Reads the immutable marker and every authorized append-only import
  /// receipt; no inventory is trusted until its v5 proof fully validates.
  Future<MergeRemoteV4Archive?> readV4Archive() =>
      _readV4Archive(_RemoteOperation());

  Future<MergeRemoteV4Archive?> _readV4Archive(
    _RemoteOperation operation,
  ) async {
    final baseline = await _readV4ArchiveRecord(
      _v4ArchivePath,
      operation: operation,
    );
    List<dav.File> receiptFiles;
    try {
      receiptFiles = await _client.readDir(
        '$_snapshotNamespace/$_v4ImportDirectory',
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        if (baseline == null) return null;
        return baseline;
      }
      throw MergeRemoteException(
        'Failed to list v4 archive import receipts',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    }
    final receiptPattern = RegExp(r'^([0-9a-f]{64})\.json$');
    final receipts = <MergeRemoteV4Archive>[];
    if (baseline != null) receipts.add(baseline);
    for (final file in receiptFiles) {
      if (file.isDir == true || file.name == null) continue;
      final match = receiptPattern.firstMatch(file.name!);
      if (match == null) continue;
      final receipt = await _readV4ArchiveRecord(
        '$_snapshotNamespace/$_v4ImportDirectory/${file.name}',
        expectedInventoryDigest: match.group(1),
        operation: operation,
      );
      if (receipt != null) receipts.add(receipt);
    }
    if (baseline == null) {
      if (receipts.isEmpty) return null;
      throw const MergeRemoteCorruptException(
        'V4 archive import receipts exist without the immutable baseline',
      );
    }
    try {
      return MergeRemoteV4Archive.fromValidatedReceipts(receipts);
    } on Object catch (error) {
      throw MergeRemoteCorruptException(
        'V4 archive receipts contain conflicting inventories',
        cause: error,
      );
    }
  }

  bool _inventoryContains(
    List<MergeRemoteEntry> superset,
    List<MergeRemoteEntry> subset,
  ) {
    final byPath = {for (final entry in superset) entry.filename: entry};
    return subset.every((entry) {
      final accepted = byPath[entry.filename];
      return accepted != null &&
          MergeRemoteV4Archive._sameArchiveEntry(accepted, entry);
    });
  }

  /// Creates the initial archive or appends an explicit, immutable import receipt.
  Future<MergeRemoteV4Archive> publishV4Archive(
    MergeRemoteV4Archive archive, {
    bool acceptChanges = false,
  }) async {
    final requested = MergeRemoteV4Archive(
      inventory: archive.inventory,
      proof: archive.proof,
    );
    final operation = _RemoteOperation();
    final accepted = await _readV4Archive(operation);
    final liveInventory = await listV4();
    if (!_sameV4Inventories(liveInventory, requested.inventory)) {
      throw const MergeRemoteConflictException(
        'V4 inventory changed while preparing archive publication',
      );
    }
    if (accepted != null) {
      if (_sameV4Inventories(accepted.inventory, requested.inventory)) {
        return accepted;
      }
      if (!acceptChanges ||
          !_inventoryContains(requested.inventory, accepted.inventory)) {
        throw const MergeRemoteConflictException(
          'Existing v4 archive requires explicit import before extension',
        );
      }
    }

    final markerBytes = _serializeV4Archive(requested);
    final inventoryDigest = _archiveInventoryDigest(requested);
    final markerPath = accepted == null
        ? _v4ArchivePath
        : _v4ImportPath(inventoryDigest);
    await _ensureCollection(_snapshotNamespace, operation: operation);
    if (accepted != null) {
      await _ensureCollection(
        '$_snapshotNamespace/$_v4ImportDirectory',
        operation: operation,
      );
    }
    final markerDigest = sha256.convert(markerBytes).toString();
    final proofKey =
        '${requested.proof.filename}:${requested.proof.digest}:$markerDigest';
    if (operation.validatedArchiveProofs.add(proofKey)) {
      await _downloadPackCommit(requested.proof, usePackCache: false);
    }
    MergeRemoteV4Archive? concurrentlyAccepted;
    try {
      await _publishArchiveMarker(markerPath, markerBytes, markerDigest);
    } on MergeRemoteConflictException catch (error) {
      if (error.statusCode != 412) rethrow;
      concurrentlyAccepted = await _readV4Archive(operation);
      if (concurrentlyAccepted != null &&
          !_inventoryContains(
            concurrentlyAccepted.inventory,
            requested.inventory,
          ) &&
          acceptChanges &&
          _inventoryContains(
            requested.inventory,
            concurrentlyAccepted.inventory,
          )) {
        await _ensureCollection(
          '$_snapshotNamespace/$_v4ImportDirectory',
          operation: operation,
        );
        await _publishArchiveMarker(
          _v4ImportPath(inventoryDigest),
          markerBytes,
          markerDigest,
        );
        concurrentlyAccepted = null;
      } else if (concurrentlyAccepted == null ||
          !_inventoryContains(
            concurrentlyAccepted.inventory,
            requested.inventory,
          )) {
        rethrow;
      }
    }

    final published = concurrentlyAccepted ?? await _readV4Archive(operation);
    if (published == null ||
        !_inventoryContains(published.inventory, requested.inventory)) {
      throw const MergeRemoteConflictException(
        'Published v4 archive receipt is not visible',
      );
    }
    final afterPublication = await listV4();
    if (!_sameV4Inventories(afterPublication, published.inventory)) {
      throw const MergeRemoteConflictException(
        'Unaccepted v4 commits appeared during archive publication',
      );
    }
    return published;
  }

  Future<void> _publishArchiveMarker(
    String path,
    Uint8List bytes,
    String digest,
  ) async {
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
          options.headers!['content-type'] = 'application/json; charset=utf-8';
        },
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 412) {
        response = error.response;
      } else {
        rethrow;
      }
    }
    if ([200, 201, 204].contains(response?.statusCode)) {
      _uploadedBytes += bytes.length;
      final readBack = await _downloadRawBytes(
        path,
        maxBytes: _maxV4ArchiveBytes,
      );
      if (!_bytesEqual(readBack, bytes) ||
          sha256.convert(readBack).toString() != digest) {
        throw const MergeRemoteCorruptException(
          'V4 archive marker failed read-back verification',
        );
      }
      return;
    }
    if (response?.statusCode == 412) {
      _retries++;
      final existing = await _downloadRawBytes(
        path,
        maxBytes: _maxV4ArchiveBytes,
      );
      if (_bytesEqual(existing, bytes) &&
          sha256.convert(existing).toString() == digest) {
        return;
      }
      throw const MergeRemoteConflictException(
        'Immutable v4 archive marker already differs',
        statusCode: 412,
      );
    }
    throw MergeRemoteException(
      'V4 archive marker publication failed',
      statusCode: response?.statusCode,
    );
  }

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

  /// Downloads one immutable v5 commit and all referenced Packs.
  Future<MergeBatch> download(MergeRemoteEntry entry) {
    if (entry.layout == MergeRemoteLayout.packCommit) {
      return _downloadPackCommit(entry);
    }
    if (entry.layout == MergeRemoteLayout.snapshotCommit) {
      return _downloadSnapshot(entry);
    }
    return _downloadLegacyCheckpoint(entry);
  }

  Future<MergeBatch> _downloadPackCommit(
    MergeRemoteEntry entry, {
    bool usePackCache = true,
  }) async {
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
      if (usePackCache) {
        try {
          pack = await _packCache?.read(digest, expectedSize: expectedSize);
        } on FileSystemException {
          pack = null;
        }
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

  /// Downloads and verifies one v4 snapshot commit and its objects.
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
    final refs =
        <
          ({
            String objectPath,
            String digest,
            int compressedSize,
            String cacheKey,
          })
        >[];
    for (final refValue in objectRefs) {
      if (refValue is! Map ||
          refValue['path'] is! String ||
          refValue['sha256'] is! String ||
          refValue['compressedSize'] is! int ||
          refValue['compressedSize'] <= 0 ||
          refValue['compressedSize'] > MergeSnapshot.maxCompressedObjectBytes) {
        throw const MergeRemoteCorruptException(
          'Snapshot manifest contains an invalid object reference',
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
        throw const MergeRemoteCorruptException(
          'Snapshot manifest contains an unsafe or duplicate object path',
        );
      }
      totalCompressed += compressedSize;
      if (totalCompressed > MergeSnapshot.maxTotalCompressedBytes) {
        throw const MergeRemoteCorruptException(
          'Snapshot compressed size exceeds transport limit',
        );
      }
      refs.add((
        objectPath: objectPath,
        digest: digest,
        compressedSize: compressedSize,
        cacheKey: '$basePath/objects/$objectPath',
      ));
    }

    await _runBounded(refs, (ref) async {
      final cacheKey = ref.cacheKey;
      var bytes = _verifiedObjects[cacheKey];
      if (bytes != null &&
          (bytes.length != ref.compressedSize ||
              sha256.convert(bytes).toString() != ref.digest)) {
        _forgetVerifiedObject(cacheKey);
        _cacheInvalidations++;
        bytes = null;
      } else if (bytes != null) {
        _cacheHits++;
      }
      bytes ??= await _readPersistentObject(
        cacheKey,
        expectedSize: ref.compressedSize,
        expectedDigest: ref.digest,
      );
      if (bytes == null) {
        try {
          bytes = await _downloadRawBytes(
            cacheKey,
            maxBytes: ref.compressedSize,
            countAsObject: true,
          );
        } on DioException catch (error) {
          if (error.response?.statusCode == 404) {
            _missingObjects++;
            throw const MergeRemoteCorruptException(
              'Snapshot object is missing',
              statusCode: 404,
            );
          }
          throw MergeRemoteException(
            'Failed to download snapshot object',
            statusCode: error.response?.statusCode,
            cause: error,
          );
        } on MergeRemoteException catch (error) {
          if (error.statusCode == 404) {
            _missingObjects++;
            throw MergeRemoteCorruptException(
              'Snapshot object is missing',
              statusCode: 404,
              cause: error,
            );
          }
          rethrow;
        }
        if (bytes.length != ref.compressedSize ||
            sha256.convert(bytes).toString() != ref.digest) {
          throw const MergeRemoteCorruptException(
            'Snapshot object failed content verification',
          );
        }
        fetchedObjects[cacheKey] = bytes;
      }
      objectBytes[ref.objectPath] = bytes;
    });

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
    for (final refValue in objectRefs) {
      final object = refValue as Map;
      _compressedBytes += object['compressedSize']! as int;
      _uncompressedBytes += object['uncompressedSize']! as int;
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
        _recordWarning('Skipping a corrupt remote checkpoint candidate');
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

  /// Uploads all missing immutable Packs first, then publishes the v5 manifest.
  Future<String> upload(MergeBatch batch) async {
    return uploadSnapshot(MergeSnapshot.fromBatch(batch));
  }

  /// Publishes an already encoded v4 logical snapshot using sync-v5 Packs.
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
      namespace: _snapshotNamespace,
      operation: operation,
    );
    final basePath = '$_snapshotNamespace/$directoryName';
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

    // Manifest-last is the atomic visibility boundary for a v5 checkpoint.
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
    return '$endpoint/$actor/$directoryName';
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
        final length = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (length == expectedSize) {
          available = true;
          operation.verifiedRemoteObjects.add(path);
        } else if (length == null) {
          available = await _remotePayloadMatches(
            path,
            expectedSize,
            digest,
            operation: operation,
            countAsObject: true,
          );
        } else {
          available = false;
        }
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
        _cacheInvalidations++;
        await _removePersistentFile(file);
        return null;
      }
      final stat = await file.stat();
      if (stat.size != expectedSize ||
          stat.size > MergeSnapshot.maxCompressedObjectBytes) {
        _cacheInvalidations++;
        await _removePersistentFile(file);
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != expectedSize ||
          sha256.convert(bytes).toString() != expectedDigest) {
        _cacheInvalidations++;
        await _removePersistentFile(file);
        return null;
      }
      _cacheHits++;
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

  /// Compacts bounded sets of own v5 commits after full causal verification.
  ///
  /// v4 migration data and immutable Packs are never collected. Weak/missing
  /// ETags are filtered before downloading any candidate content.
  Future<void> compact(
    MergeBatch uploaded,
    List<MergeRemoteEntry> priorEntries,
  ) async {
    final timer = Stopwatch()..start();
    final candidatesByPath = <String, MergeRemoteEntry>{};
    var inspectedEntries = 0;
    for (final entry in priorEntries) {
      if (inspectedEntries >= _maxCompactionCandidates ||
          timer.elapsed >= _maxCompactionDuration) {
        break;
      }
      inspectedEntries++;
      if (entry.layout == MergeRemoteLayout.packCommit &&
          entry.actor == uploaded.actor &&
          entry.counter < uploaded.counter &&
          entry.filename.endsWith('.json') &&
          strongEtag(entry.eTag) != null) {
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
    if (candidates.isEmpty || timer.elapsed >= _maxCompactionDuration) return;

    final protectedProofPaths = <String>{};
    try {
      final archive = await readV4Archive();
      for (final proof in archive?.proofs ?? const <MergeRemoteEntry>[]) {
        protectedProofPaths.add(proof.filename);
      }
      if (timer.elapsed >= _maxCompactionDuration) {
        _recordWarning('Compaction time budget exhausted');
        return;
      }
    } on TimeoutException {
      _recordWarning('Compaction time budget exhausted');
      return;
    } on MergeRemoteException {
      _recordWarning(
        'Compaction skipped because archive proofs are unavailable',
      );
      return;
    } on FormatException {
      _recordWarning(
        'Compaction skipped because archive proof metadata is invalid',
      );
      return;
    }

    var retainedValidPredecessor = false;
    var scanned = 0;
    for (final prior in candidates.take(_maxCompactionCandidates)) {
      if (scanned >= _maxCompactionCandidates ||
          timer.elapsed >= _maxCompactionDuration) {
        break;
      }
      if (protectedProofPaths.contains(prior.filename)) continue;
      if (timer.elapsed >= _maxCompactionDuration) break;
      scanned++;
      final MergeBatch oldBatch;
      try {
        oldBatch = await download(prior);
      } on TimeoutException {
        _recordWarning('Compaction time budget exhausted');
        break;
      } on MergeRemoteCorruptException {
        _recordWarning('Retaining a corrupt predecessor checkpoint');
        continue;
      } on MergeRemoteException catch (error) {
        if (error.statusCode == 404) continue;
        _recordWarning('Compaction stopped after a remote service failure');
        break;
      } on FormatException {
        _recordWarning('Retaining an invalid predecessor checkpoint');
        continue;
      }
      if (timer.elapsed >= _maxCompactionDuration) {
        _recordWarning('Compaction time budget exhausted');
        break;
      }

      // Keep the newest fully valid predecessor for rollback.
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
    // Packs remain because directory enumeration cannot prove global liveness.
  }
}
