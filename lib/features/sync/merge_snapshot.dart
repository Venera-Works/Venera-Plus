import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../foundation/sync_records.dart';
import 'merge_engine.dart';

/// Lossless, content-addressed transport representation of a causal checkpoint.
///
/// The manifest carries publication metadata and the vector clock. Immutable
/// gzip objects carry disjoint domain partitions, including the event digests
/// needed to reconstruct every record's causal history.
class MergeSnapshot {
  MergeSnapshot._(
    Map<String, Object?> manifest,
    Map<String, Uint8List> objects,
    Uint8List manifestBytes,
  ) : manifest = Map.unmodifiable(_freezeMap(manifest)),
      objects = Map.unmodifiable({
        for (final entry in objects.entries)
          entry.key: entry.value.asUnmodifiableView(),
      }),
      _manifestBytes = manifestBytes;

  /// Maximum canonical manifest size accepted by the transport codec (4 MiB).
  static const int maxManifestBytes = 4 * 1024 * 1024;

  /// Maximum number of immutable objects in one checkpoint.
  static const int maxObjectCount = 4096;

  /// Maximum compressed object size (16 MiB).
  static const int maxCompressedObjectBytes = 16 * 1024 * 1024;

  /// Maximum decompressed object size (64 MiB).
  static const int maxUncompressedObjectBytes = 64 * 1024 * 1024;

  /// Maximum aggregate compressed size in one checkpoint (64 MiB).
  static const int maxTotalCompressedBytes = 64 * 1024 * 1024;

  /// Maximum aggregate decompressed size in one checkpoint (256 MiB).
  static const int maxTotalUncompressedBytes = 256 * 1024 * 1024;

  static const int _historyBucketCount = 64;
  static const Set<String> _largeDomains = {
    'history',
    'historyChapter',
    'imageFavorite',
    'favorite',
  };
  static const Set<String> _identityDomains = {
    'source',
    'sourceSession',
    'cookies',
  };
  static const Set<String> _smallDomains = {
    'setting',
    'search',
    'folder',
    'favoriteRole',
  };
  static const Set<String> _knownDomains = {
    ..._largeDomains,
    ..._identityDomains,
    ..._smallDomains,
  };

  final Map<String, Object?> manifest;
  final Map<String, Uint8List> objects;
  final Uint8List _manifestBytes;

  /// SHA-256 of the exact canonical manifest bytes.
  late final String digest = sha256.convert(_manifestBytes).toString();

  /// Encodes [batch] into deterministic stable partitions.
  factory MergeSnapshot.fromBatch(MergeBatch batch) {
    if (!_isSafeActor(batch.actor)) {
      throw const FormatException('Invalid snapshot actor');
    }
    final document = batch.document.toJson();
    final validatedDocument = MergeDocument.fromJson(document);
    final batchId = sha256
        .convert(
          utf8.encode(
            canonicalSyncJson({
              'actor': batch.actor,
              'counter': batch.counter,
              'document': document,
            }),
          ),
        )
        .toString();
    if (batch.counter <= 0 ||
        validatedDocument.counterFor(batch.actor) != batch.counter ||
        batch.id != batchId) {
      throw const FormatException('Batch counter or digest mismatch');
    }
    final vectorClock = _asIntMap(document['vclock'], 'document vector clock');
    if (vectorClock.keys.any((actor) => !_isSafeActor(actor))) {
      throw const FormatException('Invalid actor in document vector clock');
    }
    final allRecords = _asMap(document['records'], 'document records');
    final allEvents = _asStringMap(document['eventDigests'], 'event digests');
    if (allEvents.keys.any(
      (event) => !_isSafeActor(MergeDot.parse(event).actor),
    )) {
      throw const FormatException('Invalid actor in event digest identity');
    }
    final recordsByDomain = <String, Map<String, Object?>>{};
    for (final entry in allRecords.entries) {
      final domain = syncRecordDomain(entry.key);
      if (!_knownDomains.contains(domain)) {
        throw FormatException('Unsupported sync record domain: $domain');
      }
      recordsByDomain.putIfAbsent(domain, () => {})[entry.key] = entry.value;
    }

    final partitions =
        <({String domain, String partition, Map<String, Object?> records})>[];
    for (final domain in recordsByDomain.keys.toList()..sort()) {
      final records = recordsByDomain[domain]!;
      if (_largeDomains.contains(domain)) {
        final byBucket = <int, Map<String, Object?>>{};
        for (final entry in records.entries) {
          final bucket = _bucketForRecord(entry.key);
          byBucket.putIfAbsent(bucket, () => {})[entry.key] = entry.value;
        }
        for (final bucket in byBucket.keys.toList()..sort()) {
          partitions.add((
            domain: domain,
            partition: 'bucket-${bucket.toString().padLeft(2, '0')}',
            records: byBucket[bucket]!,
          ));
        }
      } else if (_identityDomains.contains(domain)) {
        for (final key in records.keys.toList()..sort()) {
          partitions.add((
            domain: domain,
            partition: 'record-${_keyDigest(key)}',
            records: {key: records[key]},
          ));
        }
      } else {
        partitions.add((domain: domain, partition: 'all', records: records));
      }
    }

    if (partitions.length > maxObjectCount) {
      throw const FormatException('Snapshot has too many objects');
    }

    final objectBytes = <String, Uint8List>{};
    final references = <Map<String, Object?>>[];
    var totalCompressed = 0;
    var totalUncompressed = 0;
    for (final partition in partitions) {
      final eventIds = <String>{};
      for (final value in partition.records.values) {
        final record = _asMap(value, 'record');
        final presence = _asMap(record['presence'], 'record presence');
        final seen = _asMap(presence['seen'], 'presence observations');
        eventIds.addAll(seen.keys);
      }
      final eventDigests = <String, Object?>{};
      for (final id in eventIds.toList()..sort()) {
        final digest = allEvents[id];
        if (digest == null) {
          throw const FormatException(
            'Record presence references missing event digest',
          );
        }
        eventDigests[id] = digest;
      }

      final payload = <String, Object?>{
        'domain': partition.domain,
        'records': partition.records,
        'eventDigests': eventDigests,
      };
      final uncompressed = Uint8List.fromList(
        utf8.encode(canonicalSyncJson(payload)),
      );
      if (uncompressed.length > maxUncompressedObjectBytes) {
        throw const FormatException(
          'Snapshot object exceeds decompressed size limit',
        );
      }
      final compressed = Uint8List.fromList(
        GZipCodec(level: 6).encode(uncompressed),
      );
      if (compressed.length > maxCompressedObjectBytes) {
        throw const FormatException(
          'Snapshot object exceeds compressed size limit',
        );
      }
      totalCompressed += compressed.length;
      totalUncompressed += uncompressed.length;
      if (totalCompressed > maxTotalCompressedBytes ||
          totalUncompressed > maxTotalUncompressedBytes) {
        throw const FormatException('Snapshot exceeds aggregate size limits');
      }

      final hash = sha256.convert(compressed).toString();
      final path = '${partition.domain}/$hash.json.gz';
      if (objectBytes.containsKey(path)) {
        throw const FormatException('Duplicate snapshot object reference');
      }
      objectBytes[path] = compressed;
      references.add({
        'path': path,
        'domain': partition.domain,
        'partition': partition.partition,
        'sha256': hash,
        'compressedSize': compressed.length,
        'uncompressedSize': uncompressed.length,
        'recordCount': partition.records.length,
      });
    }
    references.sort(
      (a, b) => (a['path']! as String).compareTo(b['path']! as String),
    );

    final manifest = <String, Object?>{
      'schema': 1,
      'actor': batch.actor,
      'counter': batch.counter,
      'batchId': batch.id,
      'documentSchema': 3,
      'vclock': document['vclock'],
      'objects': references,
    };
    final manifestBytes = Uint8List.fromList(
      utf8.encode(canonicalSyncJson(manifest)),
    );
    final snapshot = MergeSnapshot._(manifest, objectBytes, manifestBytes);
    if (snapshot._manifestBytes.length > maxManifestBytes) {
      throw const FormatException('Snapshot manifest exceeds size limit');
    }
    return snapshot;
  }

  /// Loads persisted encoded bytes, validating the full causal checkpoint.
  ///
  /// The caller transfers ownership of the input buffers and MUST NOT mutate
  /// them afterward. The snapshot retains those bytes and exposes read-only
  /// object views, so upload retries do not copy or recompress objects.
  factory MergeSnapshot.fromEncoded(
    Uint8List manifestBytes,
    Map<String, Uint8List> objects,
  ) {
    if (manifestBytes.isEmpty ||
        manifestBytes.length > maxManifestBytes ||
        objects.length > maxObjectCount) {
      throw const FormatException('Invalid encoded snapshot size');
    }
    var compressedBytes = 0;
    for (final object in objects.values) {
      if (object.isEmpty || object.length > maxCompressedObjectBytes) {
        throw const FormatException('Invalid encoded snapshot object size');
      }
      compressedBytes += object.length;
      if (compressedBytes > maxTotalCompressedBytes) {
        throw const FormatException('Encoded snapshot exceeds size limit');
      }
    }

    decode(manifestBytes, objects);
    final manifest = _asMap(
      jsonDecode(utf8.decode(manifestBytes, allowMalformed: false)),
      'snapshot manifest',
    );
    return MergeSnapshot._(manifest, objects, manifestBytes);
  }

  /// Returns an independent byte buffer suitable for durable storage or upload.
  Uint8List serializeManifest() => Uint8List.fromList(_manifestBytes);

  /// Reconstructs and validates a full causal [MergeBatch].
  static MergeBatch decode(
    Uint8List manifestBytes,
    Map<String, Uint8List> objects,
  ) {
    if (manifestBytes.isEmpty || manifestBytes.length > maxManifestBytes) {
      throw const FormatException('Invalid snapshot manifest size');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Invalid snapshot manifest: $error');
    }
    final manifest = _asMap(decoded, 'snapshot manifest');
    _requireKeys(manifest, const {
      'schema',
      'actor',
      'counter',
      'batchId',
      'documentSchema',
      'vclock',
      'objects',
    });
    if (manifest['schema'] != 1 || manifest['documentSchema'] != 3) {
      throw const FormatException('Unsupported snapshot schema');
    }
    final actor = manifest['actor'];
    final counter = manifest['counter'];
    final batchId = manifest['batchId'];
    if (actor is! String ||
        !_isSafeActor(actor) ||
        counter is! int ||
        counter <= 0 ||
        batchId is! String ||
        !_isSha256(batchId)) {
      throw const FormatException('Invalid snapshot publication metadata');
    }
    final manifestVclock = _asIntMap(
      manifest['vclock'],
      'snapshot vector clock',
    );
    if (manifestVclock.keys.any((actor) => !_isSafeActor(actor))) {
      throw const FormatException('Invalid actor in snapshot vector clock');
    }
    final refsValue = manifest['objects'];
    if (refsValue is! List || refsValue.length > maxObjectCount) {
      throw const FormatException('Invalid snapshot object list');
    }
    final refs = refsValue
        .map((value) => _asMap(value, 'object reference'))
        .toList();
    final canonical = utf8.encode(canonicalSyncJson(manifest));
    if (!_bytesEqual(canonical, manifestBytes)) {
      throw const FormatException('Snapshot manifest is not canonical JSON');
    }

    final records = <String, Object?>{};
    final eventDigests = <String, Object?>{};
    final referencedPaths = <String>{};
    final partitions = <String>{};
    final suppliedPaths = objects.keys.toSet();
    String? previousPath;
    var totalCompressed = 0;
    var totalUncompressed = 0;
    for (final reference in refs) {
      _requireKeys(reference, const {
        'path',
        'domain',
        'partition',
        'sha256',
        'compressedSize',
        'uncompressedSize',
        'recordCount',
      });
      final path = reference['path'];
      final domain = reference['domain'];
      final partition = reference['partition'];
      final digest = reference['sha256'];
      final compressedSize = reference['compressedSize'];
      final uncompressedSize = reference['uncompressedSize'];
      final recordCount = reference['recordCount'];
      if (path is! String ||
          domain is! String ||
          partition is! String ||
          digest is! String ||
          !_isSha256(digest) ||
          compressedSize is! int ||
          compressedSize <= 0 ||
          compressedSize > maxCompressedObjectBytes ||
          uncompressedSize is! int ||
          uncompressedSize <= 0 ||
          uncompressedSize > maxUncompressedObjectBytes ||
          recordCount is! int ||
          recordCount <= 0 ||
          !_knownDomains.contains(domain) ||
          path != '$domain/$digest.json.gz' ||
          !_isSafeObjectPath(path) ||
          !referencedPaths.add(path)) {
        throw const FormatException(
          'Invalid or duplicate snapshot object reference',
        );
      }
      final canonicalPath = path;
      if (previousPath != null && previousPath.compareTo(canonicalPath) >= 0) {
        throw const FormatException(
          'Snapshot object references are not sorted',
        );
      }
      previousPath = canonicalPath;
      final partitionKey = '$domain\u0000$partition';
      if (!partitions.add(partitionKey)) {
        throw const FormatException('Duplicate snapshot partition reference');
      }
      final compressed = objects[path];
      if (compressed == null ||
          compressed.length != compressedSize ||
          sha256.convert(compressed).toString() != digest) {
        throw FormatException(
          'Snapshot object is missing or has an invalid hash: $path',
        );
      }
      totalCompressed += compressed.length;
      totalUncompressed += uncompressedSize;
      if (totalCompressed > maxTotalCompressedBytes ||
          totalUncompressed > maxTotalUncompressedBytes) {
        throw const FormatException('Snapshot exceeds aggregate size limits');
      }
      final Uint8List raw;
      try {
        raw = _gunzipBounded(compressed, uncompressedSize);
      } on Object catch (error) {
        throw FormatException('Invalid gzip snapshot object $path: $error');
      }
      if (raw.length != uncompressedSize) {
        throw FormatException('Snapshot object size mismatch: $path');
      }
      final Object? partValue;
      try {
        partValue = jsonDecode(utf8.decode(raw, allowMalformed: false));
      } on Object catch (error) {
        throw FormatException('Invalid snapshot object JSON $path: $error');
      }
      final part = _asMap(partValue, 'snapshot object');
      _requireKeys(part, const {'domain', 'records', 'eventDigests'});
      if (part['domain'] != domain) {
        throw const FormatException('Snapshot object domain mismatch');
      }
      if (!_bytesEqual(utf8.encode(canonicalSyncJson(part)), raw)) {
        throw FormatException('Snapshot object is not canonical JSON: $path');
      }
      final partRecords = _asMap(part['records'], 'snapshot records');
      final partEvents = _asStringMap(
        part['eventDigests'],
        'snapshot event digests',
      );
      if (partRecords.isEmpty || partRecords.length != recordCount) {
        throw FormatException('Snapshot object record count mismatch: $path');
      }
      final requiredEvents = <String>{};
      for (final entry in partRecords.entries) {
        final record = _asMap(entry.value, 'snapshot record');
        final presence = _asMap(record['presence'], 'snapshot record presence');
        requiredEvents.addAll(
          _asMap(presence['seen'], 'snapshot record observations').keys,
        );
      }
      if (requiredEvents.length != partEvents.length ||
          !requiredEvents.containsAll(partEvents.keys)) {
        throw FormatException(
          'Snapshot event digest references do not match records: $path',
        );
      }
      for (final entry in partRecords.entries) {
        if (syncRecordDomain(entry.key) != domain ||
            _partitionFor(domain, entry.key) != partition ||
            records.containsKey(entry.key)) {
          throw FormatException(
            'Invalid record partition or duplicate record: ${entry.key}',
          );
        }
        records[entry.key] = entry.value;
      }
      for (final entry in partEvents.entries) {
        final prior = eventDigests[entry.key];
        if (prior != null && prior != entry.value) {
          throw FormatException('Conflicting event digest for ${entry.key}');
        }
        eventDigests[entry.key] = entry.value;
      }
    }
    if (suppliedPaths.length != referencedPaths.length ||
        !suppliedPaths.containsAll(referencedPaths)) {
      throw const FormatException('Unexpected or unreferenced snapshot object');
    }

    final document = <String, Object?>{
      'schema': 3,
      'vclock': manifestVclock,
      'eventDigests': eventDigests,
      'records': records,
    };
    final batch = MergeBatch.fromJson({
      'actor': actor,
      'counter': counter,
      'document': document,
      'id': batchId,
    });
    if (eventDigests.keys.any(
      (event) => !_isSafeActor(MergeDot.parse(event).actor),
    )) {
      throw const FormatException('Invalid actor in snapshot event identity');
    }
    if (batch.document.counterFor(actor) != counter) {
      throw const FormatException(
        'Snapshot counter does not match vector clock',
      );
    }
    return batch;
  }

  static bool _isSafeActor(String value) =>
      RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value);

  static Uint8List _gunzipBounded(List<int> compressed, int maxBytes) {
    final sink = _BoundedByteSink(maxBytes);
    final decoder = ZLibDecoder(gzip: true).startChunkedConversion(sink);
    try {
      decoder
        ..add(compressed)
        ..close();
    } on Object {
      try {
        decoder.close();
      } on Object {
        // Preserve the decompression or output-limit failure.
      }
      rethrow;
    }
    return sink.takeBytes();
  }

  static String _partitionFor(String domain, String key) {
    if (_largeDomains.contains(domain)) {
      return 'bucket-${_bucketForRecord(key).toString().padLeft(2, '0')}';
    }
    if (_identityDomains.contains(domain)) return 'record-${_keyDigest(key)}';
    if (_smallDomains.contains(domain)) return 'all';
    throw FormatException('Unsupported sync record domain: $domain');
  }

  static int _bucketForRecord(String key) =>
      sha256.convert(utf8.encode(key)).bytes.first & (_historyBucketCount - 1);

  static String _keyDigest(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static bool _isSafeObjectPath(String path) =>
      RegExp(r'^[A-Za-z][A-Za-z0-9]*\/[0-9a-f]{64}\.json\.gz$').hasMatch(path);

  static Map<String, Object?> _asMap(Object? value, String description) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('Invalid $description object');
    }
    return value.cast<String, Object?>();
  }

  static Map<String, String> _asStringMap(Object? value, String description) {
    final map = _asMap(value, description);
    if (map.values.any((value) => value is! String)) {
      throw FormatException('Invalid $description values');
    }
    return map.cast<String, String>();
  }

  static Map<String, int> _asIntMap(Object? value, String description) {
    final map = _asMap(value, description);
    if (map.entries.any(
      (entry) =>
          entry.key.isEmpty || entry.value is! int || (entry.value as int) < 0,
    )) {
      throw FormatException('Invalid $description values');
    }
    return map.cast<String, int>();
  }

  static void _requireKeys(Map<String, Object?> map, Set<String> keys) {
    if (map.length != keys.length || !map.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid snapshot schema keys');
    }
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static Map<String, Object?> _freezeMap(Map<String, Object?> map) => {
    for (final entry in map.entries) entry.key: _freezeValue(entry.value),
  };

  static Object? _freezeValue(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: _freezeValue(entry.value),
      });
    }
    if (value is List) {
      return List.unmodifiable(value.map(_freezeValue));
    }
    return value;
  }
}

final class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.maxBytes) : _builder = BytesBuilder(copy: false);

  final int maxBytes;
  final BytesBuilder _builder;
  int _length = 0;

  @override
  void add(List<int> chunk) {
    if (chunk.length > maxBytes - _length) {
      throw const FormatException('Gzip snapshot exceeds declared size limit');
    }
    _length += chunk.length;
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
