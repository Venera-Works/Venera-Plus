import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../foundation/sync_records.dart';
import 'merge_engine.dart';
import 'merge_snapshot.dart';

/// One verified compressed logical object in a [SyncPack].
final class SyncPackIndexEntry {
  const SyncPackIndexEntry({
    required this.path,
    required this.sha256,
    required this.offset,
    required this.size,
    required this.uncompressedSize,
    required this.codec,
  });

  final String path;
  final String sha256;

  /// Offset from the first payload byte, not from the beginning of the pack.
  final int offset;

  /// Exact compressed object length in bytes.
  final int size;
  final int uncompressedSize;
  final String codec;
}

/// A deterministic container of unchanged v4 gzip objects.
///
/// Layout: 8-byte `VNSPK001` version magic, a big-endian uint32 canonical
/// index length, the canonical JSON index, then the exact compressed v4 object
/// bytes concatenated in path order. Index offsets are relative to this final
/// payload section and must exactly cover it without gaps or overlap.
final class SyncPack {
  SyncPack._(
    Uint8List storage,
    this._payloadStart,
    this.digest,
    Map<String, SyncPackIndexEntry> indexEntries,
  ) : _storage = storage,
      bytes = storage.asUnmodifiableView(),
      index = Map.unmodifiable(indexEntries);

  static const int headerBytes = 12;
  static const int targetPackBytes = 1024 * 1024;
  static const int maxIndexBytes = 4 * 1024 * 1024;
  static const int maxPackBytes =
      MergeSnapshot.maxCompressedObjectBytes + maxIndexBytes + headerBytes;
  static const List<int> _magic = [
    0x56,
    0x4e,
    0x53,
    0x50,
    0x4b,
    0x30,
    0x30,
    0x31,
  ];

  final Uint8List _storage;
  final int _payloadStart;

  /// Immutable view over the complete verified pack bytes.
  final Uint8List bytes;
  final String digest;
  final Map<String, SyncPackIndexEntry> index;

  /// Encodes existing v4 gzip object bytes without recompressing them.
  static SyncPack encode(
    Map<String, Uint8List> objects, {
    required Map<String, int> uncompressedSizes,
  }) {
    if (objects.isEmpty || objects.length > MergeSnapshot.maxObjectCount) {
      throw const FormatException('Invalid sync pack object count');
    }
    if (uncompressedSizes.length != objects.length ||
        objects.keys.any((path) => !uncompressedSizes.containsKey(path))) {
      throw const FormatException('Missing sync pack uncompressed sizes');
    }
    final paths = objects.keys.toList()..sort();
    final entries = <Map<String, Object?>>[];
    final indexEntries = <String, SyncPackIndexEntry>{};
    final hashes = <String>{};
    var totalUncompressed = 0;
    var offset = 0;
    for (final path in paths) {
      final object = objects[path]!;
      final uncompressedSize = uncompressedSizes[path]!;
      final pathDigest = _digestFromPath(path);
      if (pathDigest == null ||
          object.isEmpty ||
          object.length > MergeSnapshot.maxCompressedObjectBytes ||
          object.length > maxPackBytes - headerBytes - offset ||
          uncompressedSize <= 0 ||
          uncompressedSize > MergeSnapshot.maxUncompressedObjectBytes ||
          sha256.convert(object).toString() != pathDigest ||
          !hashes.add(pathDigest)) {
        throw const FormatException('Invalid or duplicate sync pack object');
      }
      totalUncompressed += uncompressedSize;
      if (totalUncompressed > MergeSnapshot.maxTotalUncompressedBytes) {
        throw const FormatException(
          'Sync pack exceeds uncompressed size limit',
        );
      }
      entries.add({
        'path': path,
        'sha256': pathDigest,
        'offset': offset,
        'size': object.length,
        'uncompressedSize': uncompressedSize,
        'codec': 'gzip',
      });
      indexEntries[path] = SyncPackIndexEntry(
        path: path,
        sha256: pathDigest,
        offset: offset,
        size: object.length,
        uncompressedSize: uncompressedSize,
        codec: 'gzip',
      );
      offset += object.length;
    }
    final indexBytes = utf8.encode(
      canonicalSyncJson({
        'schema': 1,
        'objectCount': entries.length,
        'objects': entries,
      }),
    );
    if (indexBytes.isEmpty || indexBytes.length > maxIndexBytes) {
      throw const FormatException('Sync pack index exceeds size limit');
    }
    final totalLength = headerBytes + indexBytes.length + offset;
    if (totalLength > maxPackBytes) {
      throw const FormatException('Sync pack exceeds size limit');
    }
    final storage = Uint8List(totalLength);
    storage.setRange(0, _magic.length, _magic);
    ByteData.sublistView(storage).setUint32(8, indexBytes.length, Endian.big);
    storage.setRange(headerBytes, headerBytes + indexBytes.length, indexBytes);
    final payloadStart = headerBytes + indexBytes.length;
    for (final path in paths) {
      final entry = indexEntries[path]!;
      storage.setRange(
        payloadStart + entry.offset,
        payloadStart + entry.offset + entry.size,
        objects[path]!,
      );
    }
    final digest = sha256.convert(storage).toString();
    return SyncPack._(storage, payloadStart, digest, indexEntries);
  }

  /// Loads and verifies a complete pack, taking a private stable byte copy.
  factory SyncPack.decode(Uint8List bytes, {String? expectedDigest}) {
    if (bytes.length < headerBytes || bytes.length > maxPackBytes) {
      throw const FormatException('Invalid sync pack size');
    }
    final storage = Uint8List.fromList(bytes);
    final digest = sha256.convert(storage).toString();
    if (expectedDigest != null &&
        (!_isSha256(expectedDigest) || digest != expectedDigest)) {
      throw const FormatException('Sync pack digest mismatch');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (storage[i] != _magic[i]) {
        throw const FormatException('Invalid sync pack version header');
      }
    }
    final indexLength = ByteData.sublistView(storage).getUint32(8, Endian.big);
    if (indexLength <= 0 ||
        indexLength > maxIndexBytes ||
        headerBytes + indexLength > storage.length) {
      throw const FormatException('Invalid sync pack index length');
    }
    final indexStart = headerBytes;
    final payloadStart = indexStart + indexLength;
    final indexBytes = Uint8List.sublistView(storage, indexStart, payloadStart);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(indexBytes, allowMalformed: false));
    } on Object catch (error) {
      throw FormatException('Invalid sync pack index: $error');
    }
    final rawIndex = _asMap(decoded, 'sync pack index');
    _requireKeys(rawIndex, const {'schema', 'objectCount', 'objects'});
    if (rawIndex['schema'] is! int || rawIndex['schema'] != 1) {
      throw const FormatException('Unsupported sync pack index schema');
    }
    final count = rawIndex['objectCount'];
    final rawEntries = rawIndex['objects'];
    if (count is! int ||
        count <= 0 ||
        count > MergeSnapshot.maxObjectCount ||
        rawEntries is! List ||
        rawEntries.length != count) {
      throw const FormatException('Invalid sync pack object count');
    }
    if (!_bytesEqual(utf8.encode(canonicalSyncJson(rawIndex)), indexBytes)) {
      throw const FormatException('Sync pack index is not canonical JSON');
    }
    final payloadLength = storage.length - payloadStart;
    final index = <String, SyncPackIndexEntry>{};
    final hashes = <String>{};
    var nextOffset = 0;
    var totalUncompressed = 0;
    String? previousPath;
    for (final rawEntry in rawEntries) {
      final entry = _asMap(rawEntry, 'sync pack object index');
      _requireKeys(entry, const {
        'path',
        'sha256',
        'offset',
        'size',
        'uncompressedSize',
        'codec',
      });
      final path = entry['path'];
      final objectDigest = entry['sha256'];
      final offset = entry['offset'];
      final size = entry['size'];
      final uncompressedSize = entry['uncompressedSize'];
      final codec = entry['codec'];
      final pathDigest = path is String ? _digestFromPath(path) : null;
      if (path is! String ||
          pathDigest == null ||
          objectDigest is! String ||
          objectDigest != pathDigest ||
          !_isSha256(objectDigest) ||
          offset is! int ||
          offset != nextOffset ||
          size is! int ||
          size <= 0 ||
          size > MergeSnapshot.maxCompressedObjectBytes ||
          uncompressedSize is! int ||
          uncompressedSize <= 0 ||
          uncompressedSize > MergeSnapshot.maxUncompressedObjectBytes ||
          codec is! String ||
          codec != 'gzip' ||
          index.containsKey(path) ||
          !hashes.add(objectDigest) ||
          (previousPath != null && previousPath.compareTo(path) >= 0) ||
          size > payloadLength - nextOffset) {
        throw const FormatException(
          'Invalid or duplicate sync pack index entry',
        );
      }
      final objectBytes = Uint8List.sublistView(
        storage,
        payloadStart + offset,
        payloadStart + offset + size,
      );
      if (sha256.convert(objectBytes).toString() != objectDigest) {
        throw const FormatException('Sync pack object digest mismatch');
      }
      index[path] = SyncPackIndexEntry(
        path: path,
        sha256: objectDigest,
        offset: offset,
        size: size,
        uncompressedSize: uncompressedSize,
        codec: codec,
      );
      nextOffset += size;
      previousPath = path;
      totalUncompressed += uncompressedSize;
      if (totalUncompressed > MergeSnapshot.maxTotalUncompressedBytes) {
        throw const FormatException(
          'Sync pack exceeds uncompressed size limit',
        );
      }
    }
    if (nextOffset != payloadLength) {
      throw const FormatException(
        'Sync pack has a payload gap or trailing bytes',
      );
    }
    return SyncPack._(storage, payloadStart, digest, index);
  }

  /// Returns an immutable zero-copy view after checking the manifest coordinates.
  Uint8List objectBytes(String path, {required int offset, required int size}) {
    final entry = index[path];
    if (entry == null || entry.offset != offset || entry.size != size) {
      throw const FormatException('Sync pack object index mismatch');
    }
    return Uint8List.sublistView(
      _storage,
      _payloadStart + entry.offset,
      _payloadStart + entry.offset + entry.size,
    ).asUnmodifiableView();
  }
}

/// Strict schema-2 full checkpoint manifest referencing immutable packs.
final class SyncPackManifest {
  SyncPackManifest._(this._manifestBytes, Map<String, Object?> manifest)
    : manifest = Map.unmodifiable(_freezeMap(manifest)),
      actor = manifest['actor']! as String,
      counter = manifest['counter']! as int,
      batchId = manifest['batchId']! as String,
      digest = sha256.convert(_manifestBytes).toString(),
      packs = Map.unmodifiable((manifest['packs']! as Map).cast<String, int>()),
      objects = List.unmodifiable(
        (manifest['objects']! as List).map(
          (value) => Map<String, Object?>.unmodifiable(
            _freezeMap(_asMap(value, 'sync pack manifest object')),
          ),
        ),
      );

  static const int maxManifestBytes = MergeSnapshot.maxManifestBytes;

  /// Maximum active physical pack bytes referenced by one checkpoint.
  static const int maxTotalPackBytes = 256 * 1024 * 1024;

  final Uint8List _manifestBytes;
  final Map<String, Object?> manifest;
  final String actor;
  final int counter;
  final String batchId;
  final String digest;

  /// Complete historical + newly-created pack inventory and exact byte sizes.
  final Map<String, int> packs;
  final List<Map<String, Object?>> objects;

  factory SyncPackManifest.parse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxManifestBytes) {
      throw const FormatException('Invalid sync pack manifest size');
    }
    final stableBytes = Uint8List.fromList(bytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(stableBytes, allowMalformed: false));
    } on Object catch (error) {
      throw FormatException('Invalid sync pack manifest: $error');
    }
    final manifest = _asMap(decoded, 'sync pack manifest');
    _requireKeys(manifest, const {
      'schema',
      'actor',
      'counter',
      'batchId',
      'documentSchema',
      'vclock',
      'packs',
      'objects',
    });
    if (manifest['schema'] is! int ||
        manifest['schema'] != 2 ||
        manifest['documentSchema'] is! int ||
        manifest['documentSchema'] != 3) {
      throw const FormatException('Unsupported sync pack manifest schema');
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
      throw const FormatException('Invalid sync pack publication metadata');
    }
    final vclock = _asMap(manifest['vclock'], 'sync pack vector clock');
    if (vclock.entries.any(
          (entry) =>
              !_isSafeActor(entry.key) ||
              entry.value is! int ||
              (entry.value as int) < 0,
        ) ||
        vclock[actor] != counter) {
      throw const FormatException('Invalid sync pack vector clock');
    }
    final rawPacks = _asMap(manifest['packs'], 'sync pack inventory');
    if (rawPacks.length > MergeSnapshot.maxObjectCount) {
      throw const FormatException('Invalid sync pack inventory');
    }
    var totalPackBytes = 0;
    for (final entry in rawPacks.entries) {
      final size = entry.value;
      if (!_isSha256(entry.key) ||
          size is! int ||
          size < SyncPack.headerBytes + 1 ||
          size > SyncPack.maxPackBytes ||
          size > maxTotalPackBytes - totalPackBytes) {
        throw const FormatException('Invalid or oversized sync pack inventory');
      }
      totalPackBytes += size;
    }
    final packs = rawPacks.cast<String, int>();
    final rawObjects = manifest['objects'];
    if (rawObjects is! List ||
        rawObjects.length > MergeSnapshot.maxObjectCount) {
      throw const FormatException('Invalid sync pack object list');
    }

    final v4Objects = <Map<String, Object?>>[];
    final usedPacks = <String>{};
    final partitions = <(String, String)>{};
    final ranges = <String, List<(int, int)>>{};
    var totalCompressed = 0;
    var totalUncompressed = 0;
    String? previousPath;
    for (final rawObject in rawObjects) {
      final object = _asMap(rawObject, 'sync pack manifest object');
      _requireKeys(object, const {
        'path',
        'domain',
        'partition',
        'sha256',
        'compressedSize',
        'uncompressedSize',
        'recordCount',
        'packSha256',
        'offset',
      });
      final path = object['path'];
      final domain = object['domain'];
      final partition = object['partition'];
      final objectDigest = object['sha256'];
      final compressedSize = object['compressedSize'];
      final uncompressedSize = object['uncompressedSize'];
      final recordCount = object['recordCount'];
      final packDigest = object['packSha256'];
      final offset = object['offset'];
      final expectedPathDigest = path is String ? _digestFromPath(path) : null;
      final packSize = packDigest is String ? packs[packDigest] : null;
      final packPayloadLimit = packSize == null
          ? -1
          : packSize - SyncPack.headerBytes - 1;
      if (path is! String ||
          expectedPathDigest == null ||
          domain is! String ||
          !_knownDomain(domain) ||
          !path.startsWith('$domain/') ||
          partition is! String ||
          !_validPartition(domain, partition) ||
          objectDigest != expectedPathDigest ||
          compressedSize is! int ||
          compressedSize <= 0 ||
          compressedSize > MergeSnapshot.maxCompressedObjectBytes ||
          uncompressedSize is! int ||
          uncompressedSize <= 0 ||
          uncompressedSize > MergeSnapshot.maxUncompressedObjectBytes ||
          recordCount is! int ||
          recordCount <= 0 ||
          packDigest is! String ||
          !_isSha256(packDigest) ||
          !packs.containsKey(packDigest) ||
          offset is! int ||
          offset < 0 ||
          packPayloadLimit < 0 ||
          offset > packPayloadLimit ||
          compressedSize > packPayloadLimit - offset ||
          (previousPath != null && previousPath.compareTo(path) >= 0) ||
          !partitions.add((domain, partition))) {
        throw const FormatException(
          'Invalid sync pack manifest object reference',
        );
      }
      usedPacks.add(packDigest);
      ranges.putIfAbsent(packDigest, () => []).add((
        offset,
        offset + compressedSize,
      ));
      totalCompressed += compressedSize;
      totalUncompressed += uncompressedSize;
      if (totalCompressed > MergeSnapshot.maxTotalCompressedBytes ||
          totalUncompressed > MergeSnapshot.maxTotalUncompressedBytes) {
        throw const FormatException('Sync pack checkpoint exceeds size limits');
      }
      final v4Object = Map<String, Object?>.of(object)
        ..remove('packSha256')
        ..remove('offset');
      v4Objects.add(v4Object);
      previousPath = path;
    }
    if (usedPacks.length != packs.length ||
        !usedPacks.containsAll(packs.keys)) {
      throw const FormatException('Unreferenced sync pack inventory entry');
    }
    for (final packRanges in ranges.values) {
      packRanges.sort((a, b) => a.$1.compareTo(b.$1));
      for (var i = 1; i < packRanges.length; i++) {
        if (packRanges[i].$1 < packRanges[i - 1].$2) {
          throw const FormatException('Overlapping sync pack object offsets');
        }
      }
    }
    if (!_bytesEqual(utf8.encode(canonicalSyncJson(manifest)), stableBytes)) {
      throw const FormatException('Sync pack manifest is not canonical JSON');
    }

    // Reuse the v4 metadata validator so schema, exact reference fields, domain
    // partitions, and publication metadata remain one shared contract.
    final v4Manifest = Map<String, Object?>.of(manifest)
      ..['schema'] = 1
      ..remove('packs')
      ..['objects'] = v4Objects;
    MergeSnapshot.validateManifestMetadata(
      Uint8List.fromList(utf8.encode(canonicalSyncJson(v4Manifest))),
    );
    return SyncPackManifest._(stableBytes, manifest);
  }

  Uint8List serializeManifest() => Uint8List.fromList(_manifestBytes);

  /// Verifies every index/ref pair and reconstructs the exact v4 [MergeBatch].
  MergeBatch decode(Map<String, SyncPack> suppliedPacks) {
    if (suppliedPacks.length != packs.length ||
        !suppliedPacks.keys.toSet().containsAll(packs.keys)) {
      throw const FormatException('Missing or unreferenced sync pack bytes');
    }
    for (final entry in packs.entries) {
      final pack = suppliedPacks[entry.key];
      if (pack == null ||
          pack.digest != entry.key ||
          pack.bytes.length != entry.value) {
        throw const FormatException(
          'Sync pack inventory size or digest mismatch',
        );
      }
    }
    final objectsByPath = <String, Uint8List>{};
    final v4Objects = <Map<String, Object?>>[];
    for (final object in objects) {
      final path = object['path']! as String;
      final packDigest = object['packSha256']! as String;
      final pack = suppliedPacks[packDigest]!;
      final offset = object['offset']! as int;
      final compressedSize = object['compressedSize']! as int;
      final indexEntry = pack.index[path];
      if (indexEntry == null ||
          indexEntry.sha256 != object['sha256'] ||
          indexEntry.offset != offset ||
          indexEntry.size != compressedSize ||
          indexEntry.uncompressedSize != object['uncompressedSize'] ||
          indexEntry.codec != 'gzip') {
        throw const FormatException('Sync pack index does not match manifest');
      }
      objectsByPath[path] = pack.objectBytes(
        path,
        offset: offset,
        size: compressedSize,
      );
      v4Objects.add(
        Map<String, Object?>.of(object)
          ..remove('packSha256')
          ..remove('offset'),
      );
    }
    final v4Manifest = Map<String, Object?>.of(manifest)
      ..['schema'] = 1
      ..remove('packs')
      ..['objects'] = v4Objects;
    return MergeSnapshot.decode(
      Uint8List.fromList(utf8.encode(canonicalSyncJson(v4Manifest))),
      objectsByPath,
    );
  }
}

/// One schema-2 full checkpoint and only the packs newly encoded for it.
final class SyncPackSnapshot {
  SyncPackSnapshot._(this.manifest, Map<String, SyncPack> packs)
    : packs = Map.unmodifiable(packs),
      digest = manifest.digest;

  final SyncPackManifest manifest;
  final Map<String, SyncPack> packs;
  final String digest;

  factory SyncPackSnapshot.fromSnapshot(
    MergeSnapshot snapshot, {
    SyncPackManifest? previous,
  }) {
    final sourceManifest = snapshot.manifest;
    final sourceObjects = (sourceManifest['objects']! as List)
        .cast<Map<String, Object?>>();
    final previousByPath = <String, Map<String, Object?>>{
      if (previous != null)
        for (final object in previous.objects)
          object['path']! as String: object,
    };
    final locations = <String, ({String packSha256, int offset})>{};
    final packSizes = <String, int>{};
    final newPacks = <String, SyncPack>{};
    final changedObjects = <Map<String, Object?>>[];

    for (final object in sourceObjects) {
      final path = object['path']! as String;
      final old = previousByPath[path];
      if (old != null && _sameV4Reference(old, object)) {
        final packDigest = old['packSha256']! as String;
        final offset = old['offset']! as int;
        final size = previous!.packs[packDigest]!;
        locations[path] = (packSha256: packDigest, offset: offset);
        packSizes[packDigest] = size;
      } else {
        changedObjects.add(object);
      }
    }

    var group = <Map<String, Object?>>[];
    var groupEstimate = SyncPack.headerBytes + 128;
    void flushGroup() {
      if (group.isEmpty) return;
      final bytesByPath = <String, Uint8List>{};
      final uncompressedSizes = <String, int>{};
      for (final object in group) {
        final path = object['path']! as String;
        final bytes = snapshot.objects[path];
        if (bytes == null) {
          throw const FormatException('Missing changed snapshot object bytes');
        }
        bytesByPath[path] = bytes;
        uncompressedSizes[path] = object['uncompressedSize']! as int;
      }
      final pack = SyncPack.encode(
        bytesByPath,
        uncompressedSizes: uncompressedSizes,
      );
      final priorSize = previous?.packs[pack.digest];
      if (priorSize != null && priorSize != pack.bytes.length) {
        throw const FormatException('Reused pack digest has conflicting size');
      }
      for (final object in group) {
        final path = object['path']! as String;
        final entry = pack.index[path]!;
        locations[path] = (packSha256: pack.digest, offset: entry.offset);
      }
      packSizes[pack.digest] = pack.bytes.length;
      if (priorSize == null) newPacks[pack.digest] = pack;
      group = <Map<String, Object?>>[];
      groupEstimate = SyncPack.headerBytes + 128;
    }

    for (final object in changedObjects) {
      final path = object['path']! as String;
      final objectBytes = snapshot.objects[path]!;
      final estimate = objectBytes.length + 256 + utf8.encode(path).length;
      if (group.isNotEmpty &&
          groupEstimate + estimate > SyncPack.targetPackBytes) {
        flushGroup();
      }
      group.add(object);
      groupEstimate += estimate;
    }
    flushGroup();

    final references = <Map<String, Object?>>[];
    for (final object in sourceObjects) {
      final path = object['path']! as String;
      final location = locations[path]!;
      references.add({
        ...object,
        'packSha256': location.packSha256,
        'offset': location.offset,
      });
    }
    final manifestValue = <String, Object?>{
      ...sourceManifest,
      'schema': 2,
      'packs': {
        for (final digest in packSizes.keys.toList()..sort())
          digest: packSizes[digest]!,
      },
      'objects': references,
    };
    if (_exceedsPackInventoryLimit(packSizes.values)) {
      if (previous == null) {
        throw const FormatException('Fresh sync pack inventory exceeds limit');
      }
      // Retained historical packs can accumulate sparse obsolete objects.
      // Rebase only at the hard inventory cap, then return the complete new set.
      return SyncPackSnapshot.fromSnapshot(snapshot);
    }

    final manifest = SyncPackManifest.parse(
      Uint8List.fromList(utf8.encode(canonicalSyncJson(manifestValue))),
    );
    return SyncPackSnapshot._(manifest, newPacks);
  }

  Uint8List serializeManifest() => manifest.serializeManifest();
}

String? _digestFromPath(String path) {
  final match = RegExp(
    r'^([A-Za-z][A-Za-z0-9]*)/([0-9a-f]{64})\.json\.gz$',
  ).firstMatch(path);
  if (match == null || !_knownDomain(match.group(1)!)) return null;
  return match.group(2);
}

bool _knownDomain(String domain) => const {
  'history',
  'historyChapter',
  'imageFavorite',
  'favorite',
  'source',
  'sourceSession',
  'cookies',
  'setting',
  'search',
  'folder',
  'favoriteRole',
}.contains(domain);

bool _validPartition(String domain, String partition) {
  if (const {
    'history',
    'historyChapter',
    'imageFavorite',
    'favorite',
  }.contains(domain)) {
    final match = RegExp(r'^bucket-(\d{2})$').firstMatch(partition);
    final bucket = match == null ? null : int.tryParse(match.group(1)!);
    return bucket != null && bucket >= 0 && bucket < 64;
  }
  if (const {'source', 'sourceSession', 'cookies'}.contains(domain)) {
    return RegExp(r'^record-[0-9a-f]{64}$').hasMatch(partition);
  }
  return const {
        'setting',
        'search',
        'folder',
        'favoriteRole',
      }.contains(domain) &&
      partition == 'all';
}

bool _exceedsPackInventoryLimit(Iterable<int> packSizes) {
  var total = 0;
  for (final size in packSizes) {
    if (size > SyncPackManifest.maxTotalPackBytes - total) return true;
    total += size;
  }
  return false;
}

bool _sameV4Reference(
  Map<String, Object?> previous,
  Map<String, Object?> next,
) {
  final previousV4 = Map<String, Object?>.of(previous)
    ..remove('packSha256')
    ..remove('offset');
  return canonicalSyncJson(previousV4) == canonicalSyncJson(next);
}

bool _isSafeActor(String value) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value);

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Map<String, Object?> _asMap(Object? value, String description) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Invalid $description object');
  }
  return value.cast<String, Object?>();
}

void _requireKeys(Map<String, Object?> map, Set<String> keys) {
  if (map.length != keys.length || !map.keys.toSet().containsAll(keys)) {
    throw const FormatException('Invalid sync pack schema keys');
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Map<String, Object?> _freezeMap(Map<String, Object?> map) => {
  for (final entry in map.entries) entry.key: _freezeValue(entry.value),
};

Object? _freezeValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeValue(entry.value),
    });
  }
  if (value is List) return List.unmodifiable(value.map(_freezeValue));
  return value;
}
