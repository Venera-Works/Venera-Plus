import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/sync_records.dart';

void main() {
  test('packs are deterministic, compact, and preserve exact v4 batches', () {
    final batch = _makeBatch();
    final v4Snapshot = MergeSnapshot.fromBatch(batch);
    final first = SyncPackSnapshot.fromSnapshot(v4Snapshot);
    final repeated = SyncPackSnapshot.fromSnapshot(v4Snapshot);

    expect(
      first.serializeManifest(),
      orderedEquals(repeated.serializeManifest()),
    );
    expect(first.digest, repeated.digest);
    expect(first.manifest.objects.length, v4Snapshot.objects.length);
    final packedByPath = {
      for (final object in first.manifest.objects)
        object['path']! as String: object,
    };
    for (final path in v4Snapshot.objects.keys) {
      final reference = packedByPath[path]!;
      final pack = first.packs[reference['packSha256']! as String]!;
      expect(
        pack.objectBytes(
          path,
          offset: reference['offset']! as int,
          size: reference['compressedSize']! as int,
        ),
        orderedEquals(v4Snapshot.objects[path]!),
      );
    }
    expect(first.packs.keys, unorderedEquals(repeated.packs.keys));
    for (final digest in first.packs.keys) {
      expect(
        first.packs[digest]!.bytes,
        orderedEquals(repeated.packs[digest]!.bytes),
      );
    }
    expect(first.packs.length, lessThan(v4Snapshot.objects.length));
    expect(v4Snapshot.objects.length, greaterThan(1));
    final pack = first.packs.values.first;
    final entry = pack.index.values.first;
    expect(() => pack.bytes[0] = 0, throwsA(isA<UnsupportedError>()));
    expect(
      () => pack.objectBytes(
        entry.path,
        offset: entry.offset,
        size: entry.size,
      )[0] = 0,
      throwsA(isA<UnsupportedError>()),
    );

    final legacyDecoded = MergeSnapshot.decode(
      v4Snapshot.serializeManifest(),
      v4Snapshot.objects,
    );
    expect(legacyDecoded.toJson(), batch.toJson());
    final parsed = SyncPackManifest.parse(first.serializeManifest());
    expect(parsed.digest, first.manifest.digest);
    expect(parsed.decode(first.packs).toJson(), batch.toJson());
  });

  test(
    'setting-only checkpoint reuses historical packs and encodes one new object',
    () {
      final firstBatch = _makeBatch();
      final firstV4 = MergeSnapshot.fromBatch(firstBatch);
      final first = SyncPackSnapshot.fromSnapshot(firstV4);

      final settingKey = syncRecordKey('setting', ['themeMode']);
      final changedDocument = firstBatch.document.clone();
      final before = firstBatch.document.materialize();
      final after = Map<String, Map<String, Object?>>.of(before)
        ..[settingKey] = {'value': 'light'};
      changedDocument.captureLocal(firstBatch.actor, before, after);
      final secondBatch = MergeBatch.create(
        actor: firstBatch.actor,
        counter: changedDocument.counterFor(firstBatch.actor),
        document: changedDocument,
      );
      final secondV4 = MergeSnapshot.fromBatch(secondBatch);
      final second = SyncPackSnapshot.fromSnapshot(
        secondV4,
        previous: first.manifest,
      );

      expect(second.packs.length, 1);
      expect(second.manifest.packs.length, first.manifest.packs.length + 1);
      final firstByPath = {
        for (final object in first.manifest.objects)
          object['path']! as String: object,
      };
      final changedReferences = second.manifest.objects
          .where((object) => object['domain'] == 'setting')
          .toList();
      expect(changedReferences, hasLength(1));
      for (final object in second.manifest.objects.where(
        (object) => object['domain'] != 'setting',
      )) {
        final old = firstByPath[object['path']! as String]!;
        expect(object['packSha256'], old['packSha256']);
        expect(object['offset'], old['offset']);
      }
      expect(
        second.manifest.packs.keys.toSet().difference(
          first.manifest.packs.keys.toSet(),
        ),
        second.packs.keys.toSet(),
      );

      final referencedPacks = <String, SyncPack>{};
      for (final digest in second.manifest.packs.keys) {
        referencedPacks[digest] = second.packs[digest] ?? first.packs[digest]!;
      }
      expect(
        second.manifest.decode(referencedPacks).toJson(),
        secondBatch.toJson(),
      );
    },
  );

  test('rebases only when retained packs cross the physical inventory cap', () {
    const actor = 'aggregate_rebase_actor';
    final sourceRecords = <String, Map<String, Object?>>{
      for (var index = 0; index < 26; index++)
        syncRecordKey('source', ['source-$index']): {'name': 'source-$index'},
    };
    final initialDocument = MergeDocument()
      ..captureLocal(actor, const {}, sourceRecords);
    final initialBatch = MergeBatch.create(
      actor: actor,
      counter: initialDocument.counterFor(actor),
      document: initialDocument,
    );
    final initial = SyncPackSnapshot.fromSnapshot(
      MergeSnapshot.fromBatch(initialBatch),
    );
    expect(initial.manifest.objects, hasLength(26));

    final packDigests = [
      for (var index = 1; index <= 13; index++)
        (index + 200).toRadixString(16).padLeft(64, '0'),
    ];
    final packSizes = <String, int>{
      for (var index = 0; index < 12; index++)
        packDigests[index]: SyncPack.maxPackBytes,
      packDigests.last:
          SyncPackManifest.maxTotalPackBytes - 12 * SyncPack.maxPackBytes - 1,
    };
    final offsets = List<int>.filled(packDigests.length, 0);
    final previousObjects = <Map<String, Object?>>[];
    for (var index = 0; index < initial.manifest.objects.length; index++) {
      final object = Map<String, Object?>.of(initial.manifest.objects[index]);
      final packIndex = index % packDigests.length;
      object['packSha256'] = packDigests[packIndex];
      object['offset'] = offsets[packIndex];
      offsets[packIndex] += object['compressedSize']! as int;
      previousObjects.add(object);
    }
    final syntheticPrevious = Map<String, Object?>.of(initial.manifest.manifest)
      ..['packs'] = packSizes
      ..['objects'] = previousObjects;
    final previous = SyncPackManifest.parse(
      Uint8List.fromList(utf8.encode(canonicalSyncJson(syntheticPrevious))),
    );
    expect(
      packSizes.values.reduce((left, right) => left + right),
      lessThan(SyncPackManifest.maxTotalPackBytes),
    );

    final changedDocument = initialBatch.document.clone();
    final before = initialBatch.document.materialize();
    final sourceKey = syncRecordKey('source', ['source-0']);
    final after = Map<String, Map<String, Object?>>.of(before)
      ..[sourceKey] = {'name': 'changed'};
    changedDocument.captureLocal(actor, before, after);
    final changedBatch = MergeBatch.create(
      actor: actor,
      counter: changedDocument.counterFor(actor),
      document: changedDocument,
    );
    final changed = SyncPackSnapshot.fromSnapshot(
      MergeSnapshot.fromBatch(changedBatch),
      previous: previous,
    );

    expect(changed.packs.length, 1);
    expect(changed.manifest.packs.keys.toSet(), changed.packs.keys.toSet());
    expect(
      changed.manifest.decode(changed.packs).toJson(),
      changedBatch.toJson(),
    );
  });

  test(
    'rejects a checkpoint whose referenced pack inventory exceeds its cap',
    () {
      final packs = <String, int>{};
      final objects = <Map<String, Object?>>[];
      for (var index = 1; index <= 13; index++) {
        final objectDigest = index.toRadixString(16).padLeft(64, '0');
        final packDigest = (index + 100).toRadixString(16).padLeft(64, '0');
        packs[packDigest] = SyncPack.maxPackBytes;
        objects.add({
          'path': 'source/$objectDigest.json.gz',
          'domain': 'source',
          'partition': 'record-$objectDigest',
          'sha256': objectDigest,
          'compressedSize': 1,
          'uncompressedSize': 1,
          'recordCount': 1,
          'packSha256': packDigest,
          'offset': 0,
        });
      }
      final overLimitManifest = Uint8List.fromList(
        utf8.encode(
          canonicalSyncJson({
            'schema': 2,
            'actor': 'actor',
            'counter': 1,
            'batchId': List.filled(64, 'a').join(),
            'documentSchema': 3,
            'vclock': {'actor': 1},
            'packs': packs,
            'objects': objects,
          }),
        ),
      );

      expect(
        () => SyncPackManifest.parse(overLimitManifest),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects malformed pack indexes, offsets, duplicates, and oversized packs',
    () {
      final snapshot = SyncPackSnapshot.fromSnapshot(
        MergeSnapshot.fromBatch(_makeBatch()),
      );
      final pack = snapshot.packs.values.single;
      final parsed = _readPack(pack.bytes);

      final badSchema = Map<String, Object?>.of(parsed.index)..['schema'] = 2;
      _expectInvalidPack(_assemblePack(badSchema, parsed.payload));

      final badOffset = _copyEntries(parsed.index);
      badOffset.first['offset'] = 1;
      _expectInvalidPack(
        _assemblePack(_withEntries(parsed.index, badOffset), parsed.payload),
      );

      final overlap = _copyEntries(parsed.index);
      expect(overlap.length, greaterThan(1));
      overlap[1]['offset'] =
          (overlap[0]['offset']! as int) + (overlap[0]['size']! as int) - 1;
      _expectInvalidPack(
        _assemblePack(_withEntries(parsed.index, overlap), parsed.payload),
      );

      final duplicate = _copyEntries(parsed.index);
      duplicate[1]['path'] = duplicate[0]['path'];
      duplicate[1]['sha256'] = duplicate[0]['sha256'];
      _expectInvalidPack(
        _assemblePack(_withEntries(parsed.index, duplicate), parsed.payload),
      );

      expect(
        () => SyncPack.decode(Uint8List(SyncPack.maxPackBytes + 1)),
        throwsFormatException,
      );
    },
  );

  test('rejects manifest index mismatches and bounded gzip expansion', () {
    final initial = SyncPackSnapshot.fromSnapshot(
      MergeSnapshot.fromBatch(_makeBatch()),
    );
    final originalPack = initial.packs.values.single;
    final originalIndex = _readPack(originalPack.bytes);
    final badIndexEntries = _copyEntries(originalIndex.index);
    badIndexEntries.first['uncompressedSize'] =
        (badIndexEntries.first['uncompressedSize']! as int) + 1;
    final mismatchedPack = SyncPack.decode(
      _assemblePack(
        _withEntries(originalIndex.index, badIndexEntries),
        originalIndex.payload,
      ),
    );
    final changedManifest = Map<String, Object?>.of(initial.manifest.manifest)
      ..['packs'] = {mismatchedPack.digest: mismatchedPack.bytes.length}
      ..['objects'] = [
        for (final object in initial.manifest.objects)
          {...object, 'packSha256': mismatchedPack.digest},
      ];
    final changedParsed = SyncPackManifest.parse(
      Uint8List.fromList(utf8.encode(canonicalSyncJson(changedManifest))),
    );
    expect(
      () => changedParsed.decode({mismatchedPack.digest: mismatchedPack}),
      throwsFormatException,
    );

    final compressed = Uint8List.fromList(
      GZipCodec(level: 6).encode(List<int>.filled(4096, 0x41)),
    );
    final objectDigest = sha256.convert(compressed).toString();
    final path = 'setting/$objectDigest.json.gz';
    final bombPack = SyncPack.encode(
      {path: compressed},
      uncompressedSizes: {path: 32},
    );
    final reference = <String, Object?>{
      'path': path,
      'domain': 'setting',
      'partition': 'all',
      'sha256': objectDigest,
      'compressedSize': compressed.length,
      'uncompressedSize': 32,
      'recordCount': 1,
      'packSha256': bombPack.digest,
      'offset': 0,
    };
    final bombManifest = SyncPackManifest.parse(
      Uint8List.fromList(
        utf8.encode(
          canonicalSyncJson({
            'schema': 2,
            'actor': 'gzip_bomb_actor',
            'counter': 1,
            'batchId': List.filled(64, 'a').join(),
            'documentSchema': 3,
            'vclock': {'gzip_bomb_actor': 1},
            'packs': {bombPack.digest: bombPack.bytes.length},
            'objects': [reference],
          }),
        ),
      ),
    );
    expect(
      () => bombManifest.decode({bombPack.digest: bombPack}),
      throwsFormatException,
    );
  });
}

MergeBatch _makeBatch() {
  const actor = 'sync_pack_actor';
  final records = <String, Map<String, Object?>>{
    syncRecordKey('setting', ['themeMode']): {'value': 'dark'},
    for (var index = 0; index < 256; index++)
      syncRecordKey('history', ['comic-$index', 'chapter-1']): {
        'ep': index,
        'page': index % 20,
      },
  };
  final document = MergeDocument()..captureLocal(actor, const {}, records);
  return MergeBatch.create(
    actor: actor,
    counter: document.counterFor(actor),
    document: document,
  );
}

({Map<String, Object?> index, Uint8List payload}) _readPack(Uint8List bytes) {
  final indexLength = ByteData.sublistView(bytes).getUint32(8, Endian.big);
  final payloadStart = SyncPack.headerBytes + indexLength;
  return (
    index:
        (jsonDecode(
                  utf8.decode(
                    bytes.sublist(SyncPack.headerBytes, payloadStart),
                  ),
                )
                as Map)
            .cast<String, Object?>(),
    payload: Uint8List.fromList(bytes.sublist(payloadStart)),
  );
}

List<Map<String, Object?>> _copyEntries(Map<String, Object?> index) =>
    (index['objects']! as List)
        .map(
          (entry) =>
              Map<String, Object?>.of((entry as Map).cast<String, Object?>()),
        )
        .toList();

Map<String, Object?> _withEntries(
  Map<String, Object?> index,
  List<Map<String, Object?>> entries,
) => Map<String, Object?>.of(index)..['objects'] = entries;

Uint8List _assemblePack(Map<String, Object?> index, Uint8List payload) {
  final indexBytes = utf8.encode(canonicalSyncJson(index));
  final result = Uint8List(
    SyncPack.headerBytes + indexBytes.length + payload.length,
  );
  result.setRange(0, 8, const [0x56, 0x4e, 0x53, 0x50, 0x4b, 0x30, 0x30, 0x31]);
  ByteData.sublistView(result).setUint32(8, indexBytes.length, Endian.big);
  result.setRange(12, 12 + indexBytes.length, indexBytes);
  result.setRange(12 + indexBytes.length, result.length, payload);
  return result;
}

void _expectInvalidPack(Uint8List bytes) {
  final digest = sha256.convert(bytes).toString();
  expect(
    () => SyncPack.decode(bytes, expectedDigest: digest),
    throwsFormatException,
  );
}
