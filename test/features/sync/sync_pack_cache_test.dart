import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';

void main() {
  test(
    'pack and publication cache survive restart and reject disk corruption',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-pack-cache-');
      addTearDown(() => root.delete(recursive: true));
      final snapshot = _snapshotFor('dark');
      final pack = snapshot.packs.values.single;
      final cache = SyncPackCache(root, maxBytes: 4 * 1024 * 1024);

      await cache.write(pack);
      await cache.writeManifest(
        'https://sync.example/device-a',
        snapshot.manifest,
      );
      final restarted = SyncPackCache(root, maxBytes: 4 * 1024 * 1024);
      final loadedPack = await restarted.read(
        pack.digest,
        expectedSize: pack.bytes.length,
      );
      final loadedManifest = await restarted.readManifest(
        'https://sync.example/device-a',
      );
      expect(loadedPack!.bytes, orderedEquals(pack.bytes));
      expect(
        loadedManifest!.serializeManifest(),
        orderedEquals(snapshot.serializeManifest()),
      );
      expect(restarted.hits, 2);

      final corrupted = List<int>.of(pack.bytes);
      corrupted[corrupted.length - 1] ^= 1;
      final diskPack = File('${root.path}/packs/${pack.digest}.pack');
      await diskPack.writeAsBytes(corrupted, flush: true);
      expect(
        await restarted.read(pack.digest, expectedSize: pack.bytes.length),
        isNull,
      );
      expect(restarted.invalidations, 1);

      final keyDigest = sha256
          .convert(utf8.encode('https://sync.example/device-a'))
          .toString();
      final diskManifest = File('${root.path}/manifests/$keyDigest.json');
      final envelope =
          (jsonDecode(utf8.decode(await diskManifest.readAsBytes())) as Map)
              .cast<String, Object?>();
      final publication =
          (jsonDecode(
                    utf8.decode(base64Decode(envelope['manifest']! as String)),
                  )
                  as Map)
              .cast<String, Object?>();
      publication['batchId'] = List.filled(64, 'b').join();
      envelope['manifest'] = base64Encode(utf8.encode(jsonEncode(publication)));
      await diskManifest.writeAsBytes(
        utf8.encode(jsonEncode(envelope)),
        flush: true,
      );
      expect(
        await restarted.readManifest('https://sync.example/device-a'),
        isNull,
      );
      expect(restarted.invalidations, 2);

      await diskManifest.writeAsBytes(utf8.encode('{broken'), flush: true);
      final malformedCache = SyncPackCache(root, maxBytes: 4 * 1024 * 1024);
      expect(
        await malformedCache.readManifest('https://sync.example/device-a'),
        isNull,
      );
      expect(malformedCache.invalidations, 1);
    },
  );
  test(
    'preserves cached content with unsupported pack and manifest versions',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-pack-cache-future-',
      );
      addTearDown(() => root.delete(recursive: true));
      const key = 'https://sync.example/future-version';
      final snapshot = _snapshotFor('future cache version');
      final originalPack = snapshot.packs.values.single;
      final parsedPack = _readPack(originalPack.bytes);
      final futureIndex = Map<String, Object?>.of(parsedPack.index)
        ..['schema'] = 2;
      final futurePackBytes = _assemblePack(futureIndex, parsedPack.payload);
      final futurePackDigest = sha256.convert(futurePackBytes).toString();
      final packFile = File('${root.path}/packs/$futurePackDigest.pack');
      await packFile.parent.create(recursive: true);
      await packFile.writeAsBytes(futurePackBytes, flush: true);
      final cache = SyncPackCache(root);

      await expectLater(
        cache.read(futurePackDigest, expectedSize: futurePackBytes.length),
        throwsA(
          isA<UnsupportedSyncProtocolException>()
              .having((error) => error.format, 'format', 'pack index')
              .having((error) => error.version, 'version', 2),
        ),
      );
      expect(await packFile.readAsBytes(), orderedEquals(futurePackBytes));

      await cache.writeManifest(key, snapshot.manifest);
      final keyDigest = sha256.convert(utf8.encode(key)).toString();
      final manifestFile = File('${root.path}/manifests/$keyDigest.json');
      final envelope = (jsonDecode(await manifestFile.readAsString()) as Map)
          .cast<String, Object?>();
      final manifest =
          (jsonDecode(
                    utf8.decode(base64Decode(envelope['manifest']! as String)),
                  )
                  as Map)
              .cast<String, Object?>()
            ..['schema'] = 3;
      final manifestBytes = utf8.encode(canonicalSyncJson(manifest));
      envelope['sha256'] = sha256.convert(manifestBytes).toString();
      envelope['manifest'] = base64Encode(manifestBytes);
      final futureManifestEntry = utf8.encode(jsonEncode(envelope));
      await manifestFile.writeAsBytes(futureManifestEntry, flush: true);

      await expectLater(
        cache.readManifest(key),
        throwsA(
          isA<UnsupportedSyncProtocolException>()
              .having((error) => error.format, 'format', 'pack manifest')
              .having((error) => error.version, 'version', 3),
        ),
      );
      expect(
        await manifestFile.readAsBytes(),
        orderedEquals(futureManifestEntry),
      );
      expect(cache.invalidations, 0);
      expect(cache.misses, 0);
    },
  );

  test('new root-layout publication key does not reuse old mappings', () async {
    final root = await Directory.systemTemp.createTemp(
      'sync-pack-layout-cache-',
    );
    addTearDown(() => root.delete(recursive: true));
    final snapshot = _snapshotFor('layout');
    const oldKey = 'endpoint-hash/sync_cache_actor/Device';
    const newKey = 'VeneraPlus/endpoint-hash/sync_cache_actor/Device';
    final cache = SyncPackCache(root);
    await cache.writeManifest(oldKey, snapshot.manifest);

    final restarted = SyncPackCache(root);
    expect(await restarted.readManifest(newKey), isNull);
    expect(
      (await restarted.readManifest(oldKey))!.serializeManifest(),
      orderedEquals(snapshot.serializeManifest()),
    );
  });

  test(
    'disk LRU eviction stays bounded and rebuilds its inventory after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-pack-lru-');
      addTearDown(() => root.delete(recursive: true));
      final first = _snapshotFor('A' * 512).packs.values.single;
      final second = _snapshotFor('B' * 512).packs.values.single;
      final third = _snapshotFor('C' * 512).packs.values.single;
      final sizes = [
        first.bytes.length,
        second.bytes.length,
        third.bytes.length,
      ]..sort();
      final budget = sizes[1] + sizes[2];
      final cache = SyncPackCache(root, maxBytes: budget);

      await cache.write(first);
      await cache.write(second);
      expect(
        await cache.read(first.digest, expectedSize: first.bytes.length),
        isNotNull,
      );
      await cache.write(third);
      expect(cache.usedBytes, lessThanOrEqualTo(budget));
      expect(cache.evictions, 1);
      expect(
        await cache.read(second.digest, expectedSize: second.bytes.length),
        isNull,
      );
      expect(
        await cache.read(first.digest, expectedSize: first.bytes.length),
        isNotNull,
      );
      expect(
        await cache.read(third.digest, expectedSize: third.bytes.length),
        isNotNull,
      );

      final restarted = SyncPackCache(root, maxBytes: budget);
      expect(
        await restarted.read(first.digest, expectedSize: first.bytes.length),
        isNotNull,
      );
      expect(
        await restarted.read(second.digest, expectedSize: second.bytes.length),
        isNull,
      );
      expect(
        await restarted.read(third.digest, expectedSize: third.bytes.length),
        isNotNull,
      );
      expect(restarted.usedBytes, lessThanOrEqualTo(budget));
    },
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

Uint8List _assemblePack(Map<String, Object?> index, Uint8List payload) {
  final indexBytes = utf8.encode(canonicalSyncJson(index));
  final result = Uint8List(
    SyncPack.headerBytes + indexBytes.length + payload.length,
  );
  result.setRange(0, 8, const [0x56, 0x4e, 0x53, 0x50, 0x4b, 0x30, 0x30, 0x31]);
  ByteData.sublistView(result).setUint32(8, indexBytes.length, Endian.big);
  result.setRange(
    SyncPack.headerBytes,
    SyncPack.headerBytes + indexBytes.length,
    indexBytes,
  );
  result.setRange(
    SyncPack.headerBytes + indexBytes.length,
    result.length,
    payload,
  );
  return result;
}

SyncPackSnapshot _snapshotFor(String value) {
  const actor = 'sync_cache_actor';
  final document = MergeDocument();
  document.captureLocal(actor, const {}, {
    syncRecordKey('setting', ['themeMode']): {'value': value},
  });
  final batch = MergeBatch.create(
    actor: actor,
    counter: document.counterFor(actor),
    document: document,
  );
  return SyncPackSnapshot.fromSnapshot(MergeSnapshot.fromBatch(batch));
}
