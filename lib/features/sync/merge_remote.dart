import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

import 'merge_engine.dart';
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

/// Metadata representation of a remote causal checkpoint candidate file.
class MergeRemoteEntry {
  /// Full relative path below the WebDAV endpoint.
  final String filename;

  /// Actor read from the owning device directory's `device.json`.
  final String actor;

  /// The monotonic publication counter for [actor].
  final int counter;

  /// Lowercase 64-character SHA-256 hex digest of the canonical JSON checkpoint bytes.
  final String digest;

  /// Optional remote HTTP ETag returned by directory listing or HEAD/GET.
  final String? eTag;

  const MergeRemoteEntry({
    required this.filename,
    required this.actor,
    required this.counter,
    required this.digest,
    this.eTag,
  });

  /// Regex validating safe actor identifiers used in checkpoint payloads.
  static final RegExp _actorRegex = RegExp(r'^[a-zA-Z0-9_\-]+$');

  /// Regex matching `<counter>-<sha256>.json`.
  static final RegExp _entryRegex = RegExp(r'^(\d+)-([0-9a-fA-F]{64})\.json$');

  /// Attempts to parse a full `VeneraPlus/<device>/<counter>-<digest>.json` path.
  ///
  /// [actor] comes from the device directory ownership marker; it is deliberately
  /// not encoded into the immutable checkpoint filename.
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
          eTag == other.eTag;

  @override
  int get hashCode => Object.hash(filename, actor, counter, digest, eTag);

  @override
  String toString() =>
      'MergeRemoteEntry(filename: $filename, actor: $actor, counter: $counter, digest: $digest, eTag: $eTag)';
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
/// Checkpoints are immutable files in `VeneraPlus/<device-name>/` and their
/// ownership is established by a conditional `device.json` marker.
class MergeRemote {
  MergeRemote(this._client, {String deviceName = 'Device', this.onWarning})
    : deviceName = normalizeSyncDeviceName(deviceName);

  static const String _namespace = 'VeneraPlus';
  static const String _markerName = 'device.json';

  final dav.Client _client;
  final String deviceName;

  /// Optional callback to observe non-fatal warnings (e.g. compaction skips, corrupt candidate skips).
  final void Function(String warning)? onWarning;

  /// Observable record of non-fatal operational warnings.
  final List<String> warnings = [];

  dav.Client get client => _client;

  void _recordWarning(String message) {
    warnings.add(message);
    onWarning?.call(message);
  }

  String _deviceDirectoryPath(String name) => '$_namespace/$name';

  String _markerPath(String name) =>
      '${_deviceDirectoryPath(name)}/$_markerName';

  /// Validates a complete checkpoint path rather than silently rebasing it.
  String _resolvePath(MergeRemoteEntry entry) {
    final parsed = MergeRemoteEntry.tryParse(
      entry.filename,
      actor: entry.actor,
    );
    if (parsed == null ||
        parsed.counter != entry.counter ||
        parsed.digest != entry.digest.toLowerCase()) {
      throw FormatException(
        'Invalid checkpoint path for actor ${entry.actor}: ${entry.filename}',
      );
    }
    return parsed.filename;
  }

  Future<void> _verifyEntryOwnership(MergeRemoteEntry entry) async {
    final directoryName = entry.filename.split('/')[1];
    final owner = await _readDeviceOwnership(directoryName);
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

  Future<void> _ensureNamespaceDirectory() => _ensureCollection(_namespace);

  Future<_DeviceOwnership?> _readDeviceOwnership(
    String directoryName, {
    bool ignoreInvalid = false,
  }) async {
    final path = _markerPath(directoryName);
    final Response<List<int>> response;
    try {
      response = await _client.c.req<List<int>>(
        _client,
        'GET',
        path,
        optionsHandler: (options) {
          options.responseType = ResponseType.bytes;
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw MergeRemoteException(
        'Failed to read device ownership marker',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200 || response.data == null) {
      throw MergeRemoteException(
        'Unexpected response reading device ownership marker',
        statusCode: response.statusCode,
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(response.data!));
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
        data: markerBytes,
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
    final owner = await _readDeviceOwnership(directoryName);
    if (owner == null) {
      throw const MergeRemoteConflictException(
        'Device ownership marker was not visible after claim',
      );
    }
    return owner;
  }

  Future<String> _ensureDeviceDirectory(String actor) async {
    await _ensureNamespaceDirectory();

    var directoryName = deviceName;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _ensureCollection(_deviceDirectoryPath(directoryName));
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
  Future<List<MergeRemoteEntry>> list({bool latestOnly = false}) async {
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

  /// Convenience helper to list only the highest-counter candidates per actor.
  Future<List<MergeRemoteEntry>> listLatest() => list(latestOnly: true);

  /// Downloads and cryptographically verifies a remote causal checkpoint.
  ///
  /// Verification steps:
  /// 1. Download response bytes (follows redirects; does not require GET ETag).
  /// 2. Compute SHA-256 of received bytes and compare to [entry.digest].
  /// 3. Decode UTF-8 and parse JSON schema.
  /// 4. Verify payload `actor` and `counter` strictly match [entry.actor] and [entry.counter].
  /// 5. Validate `MergeBatch.fromJson` and verify `batch.id` matches [entry.digest].
  Future<MergeBatch> download(MergeRemoteEntry entry) async {
    final remotePath = _resolvePath(entry);
    await _verifyEntryOwnership(entry);
    final Response<List<int>> response;
    try {
      response = await _client.c.req<List<int>>(
        _client,
        'GET',
        remotePath,
        optionsHandler: (options) {
          options.responseType = ResponseType.bytes;
        },
      );
    } on DioException catch (e) {
      throw MergeRemoteException(
        'HTTP GET failed for $remotePath: ${e.message}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }

    if (response.statusCode != 200) {
      throw MergeRemoteException(
        'Unexpected status downloading $remotePath: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw MergeRemoteCorruptException(
        'Download returned empty body for $remotePath',
        statusCode: response.statusCode,
      );
    }

    // Independent of server redirect or missing ETag header, bind response bytes via SHA-256.
    final computedDigest = sha256.convert(bytes).toString().toLowerCase();
    if (computedDigest != entry.digest.toLowerCase()) {
      throw MergeRemoteCorruptException(
        'SHA256 digest mismatch for ${entry.filename}: '
        'expected ${entry.digest}, got $computedDigest',
        statusCode: response.statusCode,
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

  /// Downloads raw bytes from [remotePath] without schema validation.
  Future<Uint8List> _downloadRawBytes(String remotePath) async {
    final response = await _client.c.req<List<int>>(
      _client,
      'GET',
      remotePath,
      optionsHandler: (options) {
        options.responseType = ResponseType.bytes;
      },
    );
    if (response.statusCode != 200 || response.data == null) {
      throw MergeRemoteException(
        'Failed to download raw bytes for $remotePath: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return Uint8List.fromList(response.data!);
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

  /// Publishes an immutable full causal checkpoint batch.
  ///
  /// Publication procedure:
  /// 1. Filename format: `<counter>-<sha256>.json` inside the claimed device directory.
  /// 2. Authenticates beforehand via `client.ping()` (OPTIONS without conditional headers).
  /// 3. Creates and verifies the fixed `VeneraPlus/<device-name>/` collection, claiming
  ///    `device.json` conditionally when the folder has no owner.
  /// 4. Performs streamed PUT with `If-None-Match: *` to prevent unintended overwrites.
  /// 5. On 200/201/204, performs GET read-back to verify that bytes on the server match
  ///    [batch.id] before acknowledging success.
  /// 6. On HTTP 412:
  ///    a. If remote content matches [batch.id], returns idempotently.
  ///    b. If remote content is a truncated/torn upload of our OWN pending checkpoint,
  ///       checks remote quoted strong ETag via HEAD and conditionally replaces the
  ///       corrupt file using `If-Match: strongEtag`, then re-verifies.
  ///    c. Otherwise throws [MergeRemoteConflictException].
  ///
  /// Returns the full relative path below the WebDAV endpoint.
  Future<String> upload(MergeBatch batch) async {
    if (!_actorIsSafe(batch.actor)) {
      throw FormatException('Invalid actor identifier: ${batch.actor}');
    }
    if (batch.counter < 0) {
      throw const FormatException('Checkpoint counter must be non-negative');
    }

    final bytes = batch.serializeBytes();
    final expectedDigest = batch.id.toLowerCase();
    if (sha256.convert(bytes).toString() != expectedDigest) {
      throw const FormatException(
        'Batch changed after its digest was assigned',
      );
    }

    // Authenticate before opening streamed PUT. No conditional headers on ping.
    await _client.ping();
    final directoryName = await _ensureDeviceDirectory(batch.actor);
    final relativePath =
        '$_namespace/$directoryName/${batch.counter}-${batch.id}.json';
    final entry = MergeRemoteEntry.tryParse(relativePath, actor: batch.actor);
    if (entry == null) {
      throw FormatException('Invalid checkpoint path: $relativePath');
    }

    Response? response;
    try {
      response = await _client.c.req(
        _client,
        'PUT',
        relativePath,
        data: _streamBytes(bytes),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['If-None-Match'] = '*';
          options.headers!['content-length'] = bytes.length;
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
    if (statusCode == 200 || statusCode == 201 || statusCode == 204) {
      // Cryptographically verify uploaded bytes on server before acknowledging success
      // to prevent truncated/corrupted writes from acknowledging and causing deletion of good predecessors.
      final uploadedBytes = await _downloadRawBytes(relativePath);
      final uploadedDigest = sha256
          .convert(uploadedBytes)
          .toString()
          .toLowerCase();
      if (uploadedDigest != expectedDigest) {
        throw MergeRemoteCorruptException(
          'Uploaded file at $relativePath was corrupted or truncated on server: '
          'digest mismatch (server $uploadedDigest != expected $expectedDigest)',
          statusCode: statusCode,
        );
      }
      return relativePath;
    }

    if (statusCode == 412) {
      // 1. Download existing file bytes
      final existingBytes = await _downloadRawBytes(relativePath);
      final existingDigest = sha256
          .convert(existingBytes)
          .toString()
          .toLowerCase();

      // 2. If existing content matches expected batch id, idempotent success!
      if (existingDigest == expectedDigest) {
        return relativePath;
      }

      // 3. The existing file has different content.
      // Check if it is our OWN pending file that was previously truncated/torn during PUT.
      // Safe recovery: inspect server's current ETag via HEAD. If strong ETag is present,
      // conditionally replace it using If-Match: strongEtag.
      try {
        final headResp = await _client.c.req(_client, 'HEAD', relativePath);
        final remoteEtag = headResp.headers.value('etag');
        final strong = strongEtag(remoteEtag);
        if (strong != null) {
          final replaceResp = await _client.c.req(
            _client,
            'PUT',
            relativePath,
            data: _streamBytes(bytes),
            optionsHandler: (options) {
              options.headers ??= {};
              options.headers!['If-Match'] = strong;
              options.headers!['content-length'] = bytes.length;
              options.headers!['content-type'] =
                  'application/json; charset=utf-8';
            },
          );

          if ([200, 201, 204].contains(replaceResp.statusCode)) {
            final verifiedBytes = await _downloadRawBytes(relativePath);
            final verifiedDigest = sha256
                .convert(verifiedBytes)
                .toString()
                .toLowerCase();
            if (verifiedDigest == expectedDigest) {
              return relativePath; // Successfully recovered from truncated/torn upload!
            }
          }
        }
      } on DioException catch (error) {
        if (error.response?.statusCode != 412) rethrow;
      }

      throw MergeRemoteConflictException(
        'Remote file exists with different content digest at $relativePath '
        '(existing $existingDigest != expected $expectedDigest)',
        statusCode: 412,
      );
    }

    throw MergeRemoteException(
      'WebDAV PUT failed for $relativePath: HTTP $statusCode',
      statusCode: statusCode,
    );
  }

  /// Compacts predecessor checkpoints for the owning actor.
  ///
  /// Compaction rules:
  /// - Only inspects candidates present in [priorEntries] before publication.
  /// - Only deletes files belonging to [uploaded.actor] (never other actors).
  /// - Only deletes predecessors where `counter < uploaded.counter`.
  /// - Downloads and verifies predecessor content, confirming [uploaded.document.dominates]
  ///   covers all old fields, candidates, and tombstones. (Counter checks alone are insufficient).
  /// - Requires a legitimate quoted strong ETag validator (`isStrongEtag(entry.eTag)`);
  ///   missing, unquoted, or weak validators are retained.
  /// - Sends conditional DELETE with `If-Match: strongEtag`.
  /// - Never modifies or removes legacy `.venera` files or files outside namespace.
  /// - Emits observable non-fatal warnings for unexpected statuses or network errors.
  Future<void> compact(
    MergeBatch uploaded,
    List<MergeRemoteEntry> priorEntries,
  ) async {
    for (final prior in priorEntries) {
      // 1. Must belong to the same owning actor.
      if (prior.actor != uploaded.actor) {
        continue;
      }

      // 2. Must be an older predecessor counter.
      if (prior.counter >= uploaded.counter) {
        continue;
      }

      // 3. Must not be the newly published batch.
      if (prior.digest.toLowerCase() == uploaded.id.toLowerCase()) {
        continue;
      }

      // 4. Must be a json checkpoint within this namespace, not legacy .venera snapshot.
      if (!prior.filename.endsWith('.json') ||
          prior.filename.endsWith('.venera')) {
        continue;
      }

      // 5. Strong ETag validator check: only legitimate quoted strong ETags may be conditionally deleted.
      final strong = strongEtag(prior.eTag);
      if (strong == null) {
        continue;
      }

      // 6. Download predecessor checkpoint and prove causal dominance over full content.
      // A counter check alone does not prove data coverage (counters may come from reserve/floor).
      // Must download and verify uploaded.document.dominates(oldBatch.document).
      final MergeBatch oldBatch;
      try {
        oldBatch = await download(prior);
      } on MergeRemoteCorruptException catch (error) {
        _recordWarning(
          'Retaining predecessor ${prior.filename}: ${error.message}',
        );
        continue;
      } on MergeRemoteException catch (error) {
        if (error.statusCode != 404) rethrow;
        continue;
      }

      if (!uploaded.document.dominates(oldBatch.document)) {
        // The published checkpoint does not fully cover the causal content of the predecessor. Retain.
        _recordWarning(
          'Retaining predecessor ${prior.filename}: not fully dominated by published checkpoint',
        );
        continue;
      }

      // 7. Conditional DELETE with If-Match: strong (quoted strong ETag).
      final remotePath = _resolvePath(prior);
      try {
        final delResponse = await _client.c.req(
          _client,
          'DELETE',
          remotePath,
          optionsHandler: (options) {
            options.headers ??= {};
            options.headers!['If-Match'] = strong;
          },
        );

        // 200/204: deleted; 404: already gone; 412: modified concurrently, safely retained.
        if (![200, 204, 404, 412].contains(delResponse.statusCode)) {
          throw MergeRemoteException(
            'Compaction DELETE failed for $remotePath',
            statusCode: delResponse.statusCode,
          );
        }
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 404 || status == 412) {
          // Already gone or modified concurrently, retain safely.
        } else {
          rethrow;
        }
      }
    }
  }
}
