import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/sync_records.dart';

void main() {
  test(
    'round trips conflicts, tombstones, event digests, and stable objects',
    () {
      final actor = 'snapshot_actor';
      final settingKey = syncRecordKey('setting', ['themeMode']);
      final deletedKey = syncRecordKey('favorite', ['removed']);
      final initialRecords = <String, Map<String, Object?>>{
        settingKey: {'value': 'dark'},
        deletedKey: {'name': 'Removed later'},
        for (var index = 0; index < 128; index++)
          syncRecordKey('history', ['comic-$index', 'chapter-1']): {
            'ep': index,
            'page': 3,
          },
      };
      final document = MergeDocument();
      document.captureLocal(actor, const {}, initialRecords);
      final concurrent = MergeDocument();
      concurrent.captureLocal('other_actor', const {}, {
        settingKey: {'value': 'light'},
      });
      document.merge(concurrent);

      final beforeDelete = document.materialize();
      final afterDelete = Map<String, Map<String, Object?>>.of(beforeDelete)
        ..remove(deletedKey);
      document.captureLocal(actor, beforeDelete, afterDelete);
      final batch = MergeBatch.create(
        actor: actor,
        counter: document.counterFor(actor),
        document: document,
      );

      final snapshot = MergeSnapshot.fromBatch(batch);
      final secondSnapshot = MergeSnapshot.fromBatch(batch);
      expect(
        secondSnapshot.serializeManifest(),
        orderedEquals(snapshot.serializeManifest()),
      );
      expect(secondSnapshot.digest, snapshot.digest);
      expect(
        secondSnapshot.objects.keys.toSet(),
        snapshot.objects.keys.toSet(),
      );
      for (final path in snapshot.objects.keys) {
        expect(
          secondSnapshot.objects[path],
          orderedEquals(snapshot.objects[path]!),
        );
      }

      final decoded = MergeSnapshot.decode(
        snapshot.serializeManifest(),
        snapshot.objects,
      );
      expect(decoded.toJson(), batch.toJson());
      expect(decoded.document.materialize().containsKey(deletedKey), isFalse);
      expect(decoded.document.conflicts, isNotEmpty);
      expect(
        decoded.document.conflicts
            .map((conflict) => conflict.toJson())
            .toList(),
        batch.document.conflicts.map((conflict) => conflict.toJson()).toList(),
      );
      expect(
        decoded.document.toJson()['eventDigests'],
        batch.document.toJson()['eventDigests'],
      );
    },
  );
  test(
    'loads persisted encoded snapshot without exposing mutable object bytes',
    () {
      final document = MergeDocument();
      document.captureLocal('persisted_actor', const {}, {
        syncRecordKey('setting', ['themeMode']): {'value': 'dark'},
      });
      final batch = MergeBatch.create(
        actor: 'persisted_actor',
        counter: 1,
        document: document,
      );
      final encoded = MergeSnapshot.fromBatch(batch);
      final inputObjects = {
        for (final entry in encoded.objects.entries)
          entry.key: Uint8List.fromList(entry.value),
      };
      final path = inputObjects.keys.single;
      final expectedBytes = Uint8List.fromList(inputObjects[path]!);
      final loaded = MergeSnapshot.fromEncoded(
        encoded.serializeManifest(),
        inputObjects,
      );

      expect(
        loaded.serializeManifest(),
        orderedEquals(encoded.serializeManifest()),
      );
      expect(loaded.objects[path], orderedEquals(expectedBytes));
      expect(
        () => loaded.objects[path]![0] = 0,
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test(
    'changing a setting reuses history objects and one history edit changes one bucket',
    () {
      const actor = 'bucket_actor';
      final settingKey = syncRecordKey('setting', ['themeMode']);
      final historyKeys = [
        for (var index = 0; index < 128; index++)
          syncRecordKey('history', ['comic-$index', 'chapter-1']),
      ];
      final document = MergeDocument();
      document.captureLocal(actor, const {}, {
        settingKey: {'value': 'dark'},
        for (final key in historyKeys) key: {'ep': 1, 'page': 2},
      });
      final first = MergeBatch.create(
        actor: actor,
        counter: document.counterFor(actor),
        document: document,
      );
      final firstSnapshot = MergeSnapshot.fromBatch(first);

      final settingDocument = first.document.clone();
      final beforeSetting = first.document.materialize();
      final afterSetting = {
        ...beforeSetting,
        settingKey: {'value': 'light'},
      };
      settingDocument.captureLocal(actor, beforeSetting, afterSetting);
      final second = MergeBatch.create(
        actor: actor,
        counter: settingDocument.counterFor(actor),
        document: settingDocument,
      );
      final secondSnapshot = MergeSnapshot.fromBatch(second);
      final firstHistoryPaths = _pathsFor(firstSnapshot, 'history');
      final secondHistoryPaths = _pathsFor(secondSnapshot, 'history');
      expect(firstHistoryPaths, isNotEmpty);
      expect(secondHistoryPaths, firstHistoryPaths);
      expect(
        _pathsFor(secondSnapshot, 'setting'),
        isNot(_pathsFor(firstSnapshot, 'setting')),
      );

      final historyDocument = second.document.clone();
      final beforeHistory = second.document.materialize();
      final afterHistory = {
        ...beforeHistory,
        historyKeys.first: {'ep': 2, 'page': 2},
      };
      historyDocument.captureLocal(actor, beforeHistory, afterHistory);
      final third = MergeBatch.create(
        actor: actor,
        counter: historyDocument.counterFor(actor),
        document: historyDocument,
      );
      final thirdSnapshot = MergeSnapshot.fromBatch(third);
      final thirdHistoryPaths = _pathsFor(thirdSnapshot, 'history');
      final reusedHistoryPaths = secondHistoryPaths.toSet().intersection(
        thirdHistoryPaths.toSet(),
      );
      expect(secondHistoryPaths.length, greaterThan(1));
      expect(reusedHistoryPaths.length, secondHistoryPaths.length - 1);
      expect(thirdHistoryPaths.length, secondHistoryPaths.length);
    },
  );

  test('rejects a missing or modified content-addressed object', () {
    final document = MergeDocument();
    document.captureLocal('codec_actor', const {}, {
      syncRecordKey('setting', ['themeMode']): {'value': 'dark'},
    });
    final batch = MergeBatch.create(
      actor: 'codec_actor',
      counter: 1,
      document: document,
    );
    final snapshot = MergeSnapshot.fromBatch(batch);
    final path = snapshot.objects.keys.single;
    final changed = Uint8List.fromList(snapshot.objects[path]!);
    changed[changed.length - 1] ^= 1;

    expect(
      () => MergeSnapshot.decode(snapshot.serializeManifest(), {path: changed}),
      throwsFormatException,
    );
    expect(
      () => MergeSnapshot.decode(snapshot.serializeManifest(), const {}),
      throwsFormatException,
    );
  });
  test(
    'distinguishes unsupported snapshot and document versions from bad types',
    () {
      const actor = 'snapshot_version_actor';
      final document = MergeDocument()
        ..captureLocal(actor, const {}, {
          syncRecordKey('setting', ['themeMode']): {'value': 'dark'},
        });
      final batch = MergeBatch.create(
        actor: actor,
        counter: document.counterFor(actor),
        document: document,
      );
      final snapshot = MergeSnapshot.fromBatch(batch);

      Map<String, Object?> manifestWith(String field, Object value) {
        final manifest =
            (jsonDecode(utf8.decode(snapshot.serializeManifest())) as Map)
                .cast<String, Object?>();
        manifest[field] = value;
        return manifest;
      }

      Uint8List serializeManifest(Map<String, Object?> manifest) =>
          Uint8List.fromList(utf8.encode(canonicalSyncJson(manifest)));
      void expectUnsupported(
        void Function() decode, {
        required String format,
        required int version,
      }) {
        expect(
          decode,
          throwsA(
            isA<UnsupportedSyncProtocolException>()
                .having((error) => error.format, 'format', format)
                .having((error) => error.version, 'version', version),
          ),
        );
      }

      void expectMalformedNotUnsupported(void Function() decode) {
        expect(
          decode,
          throwsA(
            allOf(
              isA<FormatException>(),
              isNot(isA<UnsupportedSyncProtocolException>()),
            ),
          ),
        );
      }

      expectUnsupported(
        () => MergeSnapshot.decode(
          serializeManifest(manifestWith('schema', 2)),
          snapshot.objects,
        ),
        format: 'snapshot',
        version: 2,
      );
      expectUnsupported(
        () => MergeSnapshot.decode(
          serializeManifest(manifestWith('documentSchema', 4)),
          snapshot.objects,
        ),
        format: 'merge document',
        version: 4,
      );
      final futureDocument = Map<String, Object?>.of(document.toJson())
        ..['schema'] = 4;
      expectUnsupported(
        () => MergeDocument.fromJson(futureDocument),
        format: 'merge document',
        version: 4,
      );

      expectMalformedNotUnsupported(
        () => MergeSnapshot.decode(
          serializeManifest(manifestWith('schema', '1')),
          snapshot.objects,
        ),
      );
      expectMalformedNotUnsupported(
        () => MergeSnapshot.decode(
          serializeManifest(manifestWith('documentSchema', '3')),
          snapshot.objects,
        ),
      );
      final malformedDocument = Map<String, Object?>.of(document.toJson())
        ..['schema'] = '3';
      expectMalformedNotUnsupported(
        () => MergeDocument.fromJson(malformedDocument),
      );
    },
  );
  test(
    'encoding cache preserves v4 bytes and fingerprints causal event digests',
    () {
      const actor = 'snapshot_cache_actor';
      final key = syncRecordKey('setting', ['themeMode']);
      final document = MergeDocument();
      document.captureLocal(actor, const {}, {
        key: {'value': 'dark'},
      });
      final batch = MergeBatch.create(
        actor: actor,
        counter: document.counterFor(actor),
        document: document,
      );
      final cache = MergeSnapshotEncodingCache(maxBytes: 1024 * 1024);
      final uncached = MergeSnapshot.fromBatch(batch);
      final first = MergeSnapshot.fromBatch(batch, encodingCache: cache);
      expect(
        first.serializeManifest(),
        orderedEquals(uncached.serializeManifest()),
      );
      expect(first.objects.keys, unorderedEquals(uncached.objects.keys));
      for (final path in first.objects.keys) {
        expect(first.objects[path], orderedEquals(uncached.objects[path]!));
      }
      final encodedBytes = cache.encodedBytes;
      expect(encodedBytes, greaterThan(0));

      final repeated = MergeSnapshot.fromBatch(batch, encodingCache: cache);
      expect(
        repeated.serializeManifest(),
        orderedEquals(first.serializeManifest()),
      );
      expect(cache.hits, first.objects.length);
      expect(cache.encodedBytes, encodedBytes);

      final causalDocument = document.clone();
      final dark = causalDocument.materialize();
      final light = Map<String, Map<String, Object?>>.of(dark)
        ..[key] = {'value': 'light'};
      causalDocument.captureLocal(actor, dark, light);
      final restoredDark = Map<String, Map<String, Object?>>.of(light)
        ..[key] = {'value': 'dark'};
      causalDocument.captureLocal(actor, light, restoredDark);
      final causalBatch = MergeBatch.create(
        actor: actor,
        counter: causalDocument.counterFor(actor),
        document: causalDocument,
      );
      expect(causalBatch.document.materialize(), batch.document.materialize());
      expect(
        causalBatch.document.toJson()['eventDigests'],
        isNot(batch.document.toJson()['eventDigests']),
      );
      final causalSnapshot = MergeSnapshot.fromBatch(
        causalBatch,
        encodingCache: cache,
      );
      expect(cache.hits, first.objects.length);
      expect(cache.encodedBytes, greaterThan(encodedBytes));
      expect(
        causalSnapshot.objects.keys.single,
        isNot(first.objects.keys.single),
      );
      expect(
        MergeSnapshot.decode(
          causalSnapshot.serializeManifest(),
          causalSnapshot.objects,
        ).toJson(),
        causalBatch.toJson(),
      );
    },
  );
}

List<String> _pathsFor(MergeSnapshot snapshot, String domain) =>
    (snapshot.manifest['objects'] as List)
        .cast<Map<String, Object?>>()
        .where((reference) => reference['domain'] == domain)
        .map((reference) => reference['path'] as String)
        .toList(growable: false);
