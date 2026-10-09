import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/network/webdav.dart';

void main() {
  late _LoopbackWebDavServer server;
  late MergeRemote remote;

  setUp(() async {
    server = await _LoopbackWebDavServer.start();
    final client = WebDavEndpoint(
      url: '${server.baseUrl}/dav',
      user: 'testuser',
      password: 'testpass',
    ).createClient();
    client.c.httpClientAdapter = IOHttpClientAdapter();
    remote = MergeRemote(client, deviceName: 'Device');
  });

  tearDown(() async {
    remote.client.c.close(force: true);
    await server.close();
  });

  MergeBatch createTestBatch({
    required String actor,
    required int counter,
    SyncRecords? records,
  }) {
    final doc = MergeDocument();
    doc.captureLocal(
      actor,
      const {},
      records ??
          {
            '["folder","f1"]': {'name': 'Folder 1', 'order': 1},
          },
    );
    doc.setCounterFloor(actor, counter);
    return MergeBatch.create(actor: actor, counter: counter, document: doc);
  }

  SyncRecords createLargePackRecords(int count) {
    final random = math.Random(17);
    return {
      for (var index = 0; index < count; index++)
        syncRecordKey('source', ['blob-$index']): {
          'name': 'blob-$index',
          'content': String.fromCharCodes(
            List<int>.generate(
              250000,
              (_) => 33 + random.nextInt(94),
              growable: false,
            ),
          ),
        },
    };
  }

  MergeRemoteEntry parseEntry(String path, String actor, {String? eTag}) {
    final packEntry = MergeRemoteEntry.tryParsePackCommit(
      path,
      actor: actor,
      eTag: eTag,
    );
    final snapshotEntry = MergeRemoteEntry.tryParseSnapshot(
      path,
      actor: actor,
      eTag: eTag,
    );
    return packEntry ??
        snapshotEntry ??
        MergeRemoteEntry.tryParse(path, actor: actor, eTag: eTag)!;
  }

  MergeRemoteEntry injectV4Commit(
    MergeBatch batch, {
    required String deviceName,
  }) {
    final snapshot = MergeSnapshot.fromBatch(batch);
    final basePath = 'VeneraPlus/sync-v4/$deviceName';
    final commitPath =
        '$basePath/commits/${batch.counter}-${snapshot.digest}.json';
    final eTag = '"v4-${batch.actor}-${batch.counter}"';
    server.injectOwnership(
      '/dav/$basePath',
      actor: batch.actor,
      name: deviceName,
    );
    server.injectFile(
      '/dav/$commitPath',
      snapshot.serializeManifest(),
      eTag: eTag,
    );
    for (final object in snapshot.objects.entries) {
      server.injectFile('/dav/$basePath/objects/${object.key}', object.value);
    }
    return MergeRemoteEntry.tryParseSnapshot(
      commitPath,
      actor: batch.actor,
      eTag: eTag,
    )!;
  }

  Future<void> expectIncrementalPackReuse(
    MergeRemote uploader,
    String actor,
  ) async {
    final historyKey = syncRecordKey('history', ['comic-a', 'chapter-1']);
    final settingKey = syncRecordKey('setting', ['themeMode']);
    final first = createTestBatch(
      actor: actor,
      counter: 1,
      records: {
        historyKey: {'ep': 1, 'page': 2},
        settingKey: {'value': 'dark'},
      },
    );
    final putsBefore = server.objectPutCount;
    final firstPath = await uploader.upload(first);
    final firstManifest = SyncPackManifest.parse(
      Uint8List.fromList(server._files['/dav/$firstPath']!),
    );
    final firstHistory = firstManifest.objects.singleWhere(
      (reference) => reference['domain'] == 'history',
    );

    final nextDocument = first.document.clone();
    final before = first.document.materialize();
    nextDocument.captureLocal(actor, before, {
      ...before,
      settingKey: {'value': 'light'},
    });
    final second = MergeBatch.create(
      actor: actor,
      counter: 2,
      document: nextDocument,
    );
    uploader.resetTransferStats();
    final secondPath = await uploader.upload(second);
    final secondManifest = SyncPackManifest.parse(
      Uint8List.fromList(server._files['/dav/$secondPath']!),
    );
    final secondHistory = secondManifest.objects.singleWhere(
      (reference) => reference['domain'] == 'history',
    );

    expect(secondHistory['path'], firstHistory['path']);
    expect(secondHistory['packSha256'], firstHistory['packSha256']);
    expect(uploader.uploadedObjects, 1);
    expect(uploader.downloadedObjects, 1);
    expect(server.objectPutCount - putsBefore, firstManifest.packs.length + 1);
  }

  group('MergeRemote entry parsing and quoted strong ETag', () {
    test('parses a full device path with Unicode and spaces', () {
      final digest = 'a' * 64;
      const actor = 'uuid-actor-123-456';
      const path = 'VeneraPlus/Workstation 机/7-';
      final entry = MergeRemoteEntry.tryParse(
        '$path$digest.json',
        actor: actor,
        eTag: '"strong-etag"',
      );
      expect(entry, isNotNull);
      expect(entry!.actor, actor);
      expect(entry.counter, 7);
      expect(entry.digest, digest);
      expect(entry.eTag, '"strong-etag"');
      expect(entry.hasStrongEtag, isTrue);
      expect(entry.filename, '$path$digest.json');
    });
    test('parses only v4 commit paths as snapshot entries', () {
      final digest = 'b' * 64;
      final path = 'VeneraPlus/sync-v4/Workstation 机/commits/7-$digest.json';
      final entry = MergeRemoteEntry.tryParseSnapshot(
        path,
        actor: 'uuid-actor-123',
        eTag: '"strong-etag"',
      );
      expect(entry, isNotNull);
      expect(entry!.layout, MergeRemoteLayout.snapshotCommit);
      expect(entry.counter, 7);
      expect(MergeRemoteEntry.tryParse(path, actor: 'uuid-actor-123'), isNull);
      expect(
        MergeRemoteEntry.tryParseSnapshot(
          'VeneraPlus/Workstation 机/7-$digest.json',
          actor: 'uuid-actor-123',
        ),
        isNull,
      );
    });

    test('parses only v5 Pack commit paths as pack commits', () {
      final digest = 'c' * 64;
      final path = 'VeneraPlus/sync-v5/Workstation 机/commits/8-$digest.json';
      final entry = MergeRemoteEntry.tryParsePackCommit(
        path,
        actor: 'uuid-actor-123',
        eTag: '"strong-etag"',
      );
      expect(entry, isNotNull);
      expect(entry!.layout, MergeRemoteLayout.packCommit);
      expect(entry.counter, 8);
      expect(
        MergeRemoteEntry.tryParseSnapshot(path, actor: 'uuid-actor-123'),
        isNull,
      );
      expect(
        MergeRemoteEntry.tryParsePackCommit(
          'VeneraPlus/sync-v4/Workstation 机/commits/8-$digest.json',
          actor: 'uuid-actor-123',
        ),
        isNull,
      );
    });

    test(
      'strictly rejects traversal, actor-bearing names, and old namespaces',
      () {
        final digest = 'a' * 64;
        for (final path in [
          '../../etc/1-$digest.json',
          'VeneraPlus/../Device/1-$digest.json',
          'VeneraPlus/Device/../1-$digest.json',
          'VeneraPlus/Device/uuid-actor-1-$digest.json',
          'sync-v2/Device/1-$digest.json',
          '.venera',
        ]) {
          expect(
            MergeRemoteEntry.tryParse(path, actor: 'uuid-actor'),
            isNull,
            reason: path,
          );
        }
        expect(
          MergeRemoteEntry.tryParse(
            'VeneraPlus/Device/1-$digest.json',
            actor: '../other',
          ),
          isNull,
        );
      },
    );

    test(
      'strictly requires quoted strong validator format for conditional operations',
      () {
        expect(strongEtag(null), isNull);
        expect(strongEtag(''), isNull);
        expect(strongEtag('   '), isNull);
        expect(strongEtag('""'), isNull);
        expect(strongEtag('W/"weak-validator"'), isNull);
        expect(strongEtag('W/12345'), isNull);
        expect(strongEtag('w/"weak-case"'), isNull);
        expect(strongEtag('strong-raw'), isNull);
        expect(strongEtag('12345'), isNull);
        expect(strongEtag('"strong-validator"'), '"strong-validator"');
        expect(strongEtag('"12345"'), '"12345"');
      },
    );

    test('rejects non-checkpoint filenames', () {
      for (final path in [
        'VeneraPlus/Device/device.json',
        'VeneraPlus/Device/actor-notnum-hash.json',
        'VeneraPlus/Device/1-short.json',
        '',
      ]) {
        expect(
          MergeRemoteEntry.tryParse(path, actor: 'actor'),
          isNull,
          reason: path,
        );
      }
    });
  });

  test('v5 Pack manifest hash roundtrips exact business records', () async {
    final records = <String, Map<String, Object?>>{
      syncRecordKey('search', ['cloud keyword']): {'order': 0},
      syncRecordKey('setting', ['themeMode']): {'value': 'dark'},
    };
    final batch = createTestBatch(
      actor: 'wire_roundtrip',
      counter: 1,
      records: records,
    );
    final path = await remote.upload(batch);
    final raw = server._files['/dav/$path']!;
    final manifest = SyncPackManifest.parse(Uint8List.fromList(raw));
    expect(sha256.convert(raw).toString(), manifest.digest);
    expect(path, endsWith('-${manifest.digest}.json'));
    expect(manifest.actor, batch.actor);
    expect(manifest.counter, batch.counter);
    expect(manifest.batchId, batch.id);
    expect(manifest.manifest['schema'], 2);
    expect(manifest.manifest.keys.toSet(), {
      'schema',
      'actor',
      'counter',
      'batchId',
      'documentSchema',
      'vclock',
      'packs',
      'objects',
    });
    expect(manifest.packs, isNotEmpty);
    for (final entry in manifest.packs.entries) {
      final basePath = path.substring(0, path.lastIndexOf('/commits/'));
      final bytes = server._files['/dav/$basePath/packs/${entry.key}.pack']!;
      expect(bytes, hasLength(entry.value));
      expect(SyncPack.decode(Uint8List.fromList(bytes)).digest, entry.key);
    }
    final downloaded = await remote.download(parseEntry(path, batch.actor));
    expect(downloaded.document.materialize(), records);
    expect(downloaded.toJson(), batch.toJson());
  });

  for (final extraKey in ['id', 'unknown']) {
    test(
      'legacy hash-valid wire payload with $extraKey remains read-only',
      () async {
        final batch = createTestBatch(actor: 'invalid_wire', counter: 1);
        final payload = jsonDecode(utf8.decode(batch.serializeBytes())) as Map;
        payload[extraKey] = batch.id;
        final bytes = utf8.encode(canonicalSyncJson(payload));
        final digest = sha256.convert(bytes).toString();
        final path = 'VeneraPlus/Device/1-$digest.json';
        server.injectOwnership(
          '/dav/VeneraPlus/Device',
          actor: 'invalid_wire',
          name: 'Device',
        );
        server.injectFile('/dav/$path', bytes);
        await expectLater(
          remote.downloadLegacyCheckpoint(parseEntry(path, batch.actor)),
          throwsA(isA<MergeRemoteCorruptException>()),
        );
      },
    );
  }

  test(
    'authentication and server failures are not corrupt-artifact warnings',
    () async {
      final batch = createTestBatch(actor: 'unavailable', counter: 1);
      final path = await remote.upload(batch);
      final entry = parseEntry(path, batch.actor);
      for (final status in [401, 503]) {
        server.getStatuses['/dav/$path'] = status;
        await expectLater(
          remote.downloadLatestValid(entry.actor, [entry]),
          throwsA(isA<MergeRemoteException>()),
        );
        expect(remote.warnings, isEmpty);
      }
      server.getStatuses['/dav/VeneraPlus/sync-v5/${path.split('/')[2]}/device.json'] =
          401;
      await expectLater(remote.list(), throwsA(isA<MergeRemoteException>()));
      expect(remote.warnings, isEmpty);
    },
  );

  group('Two-device concurrent publication and listing candidates', () {
    test(
      'two devices publish concurrently without overwriting each other',
      () async {
        final recordsA = {
          syncRecordKey('folder', ['alpha']): <String, Object?>{
            'name': 'Alpha',
          },
        };
        final recordsB = {
          syncRecordKey('folder', ['beta']): <String, Object?>{'name': 'Beta'},
        };
        final batchA = createTestBatch(
          actor: 'device-alpha',
          counter: 1,
          records: recordsA,
        );
        final batchB = createTestBatch(
          actor: 'device-beta',
          counter: 1,
          records: recordsB,
        );

        final paths = await Future.wait([
          remote.upload(batchA),
          remote.upload(batchB),
        ]);
        expect(paths[0], isNot(paths[1]));
        for (final path in paths) {
          expect(path.split('/').first, 'VeneraPlus');
          expect(
            path.split('/').last,
            matches(RegExp(r'^1-[0-9a-f]{64}\.json$')),
          );
        }

        final entries = await remote.list();

        final actors = entries.map((e) => e.actor).toSet();
        expect(actors, containsAll(['device-alpha', 'device-beta']));

        final downloadedA = await remote.download(
          entries.singleWhere((e) => e.actor == 'device-alpha'),
        );
        final downloadedB = await remote.download(
          entries.singleWhere((e) => e.actor == 'device-beta'),
        );

        expect(downloadedA.actor, 'device-alpha');
        expect(downloadedB.actor, 'device-beta');
        expect(downloadedA.id, batchA.id);
        expect(downloadedB.id, batchB.id);
        expect(downloadedA.document.materialize(), recordsA);
        expect(downloadedB.document.materialize(), recordsB);
      },
    );

    test(
      'retains same-counter hash collisions explicitly in latest candidates',
      () async {
        final batchA = createTestBatch(
          actor: 'device-gamma',
          counter: 2,
          records: {
            '["setting","theme"]': {'value': 'dark'},
          },
        );
        final batchB = createTestBatch(
          actor: 'device-gamma',
          counter: 2,
          records: {
            '["setting","theme"]': {'value': 'light'},
          },
        );

        await remote.upload(batchA);
        await remote.upload(batchB);

        final entries = await remote.listLatest();
        final gammaEntries = entries
            .where((e) => e.actor == 'device-gamma')
            .toList();
        expect(gammaEntries.length, 2);
        expect(gammaEntries.map((e) => e.counter).toSet(), {2});
        final themes = <Object?>{};
        for (final entry in gammaEntries) {
          final downloaded = await remote.download(entry);
          themes.add(
            downloaded.document.materialize()['["setting","theme"]']!['value'],
          );
        }
        expect(themes, {'dark', 'light'});
      },
    );

    test(
      'listing preserves all candidates latest-counter-first so corrupt latest does not mask older valid',
      () async {
        final batch1 = createTestBatch(actor: 'device-multi', counter: 1);
        final batch2 = createTestBatch(actor: 'device-multi', counter: 2);

        await remote.upload(batch1);
        await remote.upload(batch2);

        // Default list() returns all candidates sorted by counter descending
        final candidates = await remote.list();
        final multiCandidates = candidates
            .where((e) => e.actor == 'device-multi')
            .toList();
        expect(multiCandidates.length, 2);
        expect(multiCandidates[0].counter, 2);
        expect(multiCandidates[1].counter, 1);

        // If candidate 2 were corrupted on the server, candidate 1 remains accessible
        server.tamperFile(
          '/dav/${multiCandidates[0].filename}',
          utf8.encode('{"corrupted":true}'),
        );
        expect(
          () => remote.download(multiCandidates[0]),
          throwsA(isA<MergeRemoteCorruptException>()),
        );

        final fallbackDownload = await remote.download(multiCandidates[1]);
        expect(fallbackDownload.actor, 'device-multi');
        expect(fallbackDownload.counter, 1);
        expect(fallbackDownload.id, batch1.id);
      },
    );
  });
  test(
    'fails without publishing when the actor-hash fallback is owned',
    () async {
      const attemptedActor = 'attempted_actor';
      final suffix = sha256
          .convert(utf8.encode(attemptedActor))
          .toString()
          .substring(0, 8);
      server.injectOwnership(
        '/dav/VeneraPlus/sync-v5/Device',
        actor: 'base_owner',
        name: 'Device',
      );
      server.injectOwnership(
        '/dav/VeneraPlus/sync-v5/Device-$suffix',
        actor: 'fallback_owner',
        name: 'Device-$suffix',
      );

      await expectLater(
        remote.upload(createTestBatch(actor: attemptedActor, counter: 1)),
        throwsA(isA<MergeRemoteConflictException>()),
      );
      expect(server.checkpointPutCount, 0);
      expect(
        server.hasFile('/dav/VeneraPlus/sync-v5/Device/device.json'),
        isTrue,
      );
      expect(
        server.hasFile('/dav/VeneraPlus/sync-v5/Device-$suffix/device.json'),
        isTrue,
      );
    },
  );

  group('Device-directory ownership and discovery', () {
    test('renamed device keeps its old checkpoints discoverable', () async {
      final oldDevice = MergeRemote(remote.client, deviceName: 'Old Device');
      final newDevice = MergeRemote(remote.client, deviceName: 'New Device');
      final oldBatch = createTestBatch(actor: 'renamed_actor', counter: 1);
      final newBatch = createTestBatch(actor: 'renamed_actor', counter: 2);

      final oldPath = await oldDevice.upload(oldBatch);
      final newPath = await newDevice.upload(newBatch);

      expect(oldPath, startsWith('VeneraPlus/sync-v5/Old Device/commits/1-'));
      expect(newPath, startsWith('VeneraPlus/sync-v5/New Device/commits/2-'));
      expect(
        server.hasFile('/dav/VeneraPlus/sync-v5/Old Device/device.json'),
        isTrue,
      );
      expect(
        server.hasFile('/dav/VeneraPlus/sync-v5/New Device/device.json'),
        isTrue,
      );

      final entries = await newDevice.list();
      expect(entries.map((entry) => entry.actor).toSet(), {'renamed_actor'});
      expect(entries.map((entry) => entry.counter).toSet(), {1, 2});
      expect(entries.map((entry) => entry.filename).toSet(), {
        oldPath,
        newPath,
      });
      expect(server.markerPutCount, 2);
      expect(
        server._files.keys.where((path) => path.contains('/commits/')).length,
        2,
      );
    });

    test(
      'does not inspect root .venera or the old sync-v2 namespace',
      () async {
        final legacySnapshot = Uint8List.fromList([1, 2, 3, 4]);
        final legacyCheckpoint = Uint8List.fromList([5, 6, 7, 8]);
        server.injectFile('/dav/.venera', legacySnapshot);
        server.injectFile(
          '/dav/sync-v2/legacy-actor-1-${'a' * 64}.json',
          legacyCheckpoint,
        );
        final batch = createTestBatch(actor: 'current_actor', counter: 1);
        await remote.upload(batch);

        final entries = await remote.list();
        expect(entries.map((entry) => entry.actor).toList(), ['current_actor']);
        expect(server._files['/dav/.venera'], orderedEquals(legacySnapshot));
        expect(
          server._files['/dav/sync-v2/legacy-actor-1-${'a' * 64}.json'],
          orderedEquals(legacyCheckpoint),
        );
        expect(
          server.receivedRequests.any(
            (request) =>
                request.contains('/sync-v2') || request.contains('/.venera'),
          ),
          isFalse,
        );
      },
    );
  });
  test(
    'legacy checkpoints are exposed only through read-only migration APIs',
    () async {
      final legacyBatch = createTestBatch(actor: 'legacy_actor', counter: 1);
      server.injectOwnership(
        '/dav/VeneraPlus/Legacy Device',
        actor: legacyBatch.actor,
        name: 'Legacy Device',
      );
      final legacyPath =
          'VeneraPlus/Legacy Device/${legacyBatch.counter}-${legacyBatch.id}.json';
      server.injectFile(
        '/dav/$legacyPath',
        legacyBatch.serializeBytes(),
        eTag: '"legacy-strong"',
      );

      expect(await remote.list(), isEmpty);
      final legacyEntries = await remote.listLegacyCheckpoints();
      expect(legacyEntries, hasLength(1));
      expect(legacyEntries.single.layout, MergeRemoteLayout.legacyCheckpoint);
      final downloaded = await remote.downloadLegacyCheckpoint(
        legacyEntries.single,
      );
      expect(downloaded.toJson(), legacyBatch.toJson());
      expect(
        () => remote.downloadLegacyCheckpoint(
          MergeRemoteEntry.tryParseSnapshot(
            'VeneraPlus/sync-v4/Legacy Device/commits/1-${'a' * 64}.json',
            actor: legacyBatch.actor,
          )!,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'keeps v4 commits read-only and available through explicit listV4',
    () async {
      final batch = createTestBatch(actor: 'legacy_v4_actor', counter: 4);
      const basePath = 'VeneraPlus/sync-v4/Legacy V4 Device';
      server.injectOwnership(
        '/dav/$basePath',
        actor: batch.actor,
        name: 'Legacy V4 Device',
      );
      final snapshot = MergeSnapshot.fromBatch(batch);
      final commitPath =
          '$basePath/commits/${batch.counter}-${snapshot.digest}.json';
      server.injectFile(
        '/dav/$commitPath',
        snapshot.serializeManifest(),
        eTag: '"v4-commit-etag"',
      );
      for (final object in snapshot.objects.entries) {
        server.injectFile('/dav/$basePath/objects/${object.key}', object.value);
      }

      expect(await remote.list(), isEmpty);
      final v4Entries = await remote.listV4();
      expect(v4Entries, hasLength(1));
      expect(v4Entries.single.layout, MergeRemoteLayout.snapshotCommit);
      expect(
        (await remote.download(v4Entries.single)).toJson(),
        batch.toJson(),
      );
      await remote.compact(batch, v4Entries);
      expect(server.hasFile('/dav/$commitPath'), isTrue);
      expect(
        server.receivedRequests.where(
          (request) => request.startsWith('DELETE '),
        ),
        isEmpty,
      );
    },
  );

  test(
    'freezes v4 inventory and appends only explicit immutable import receipts',
    () async {
      final proofBatch = createTestBatch(actor: 'archive_proof', counter: 1);
      final proofPath = await remote.upload(proofBatch);
      final proof = (await remote.list()).singleWhere(
        (entry) => entry.filename == proofPath,
      );
      final first = injectV4Commit(
        createTestBatch(actor: 'legacy_import_one', counter: 1),
        deviceName: 'Archive Device One',
      );
      final baselinePath = '/dav/VeneraPlus/sync-v5/archive-v4.json';
      final baseline = await remote.publishV4Archive(
        MergeRemoteV4Archive(inventory: [first], proof: proof),
      );
      final originalBaselineBytes = List<int>.of(server._files[baselinePath]!);
      expect(baseline.inventory.map((entry) => entry.filename), [
        first.filename,
      ]);

      final second = injectV4Commit(
        createTestBatch(actor: 'legacy_import_two', counter: 1),
        deviceName: 'Archive Device Two',
      );
      final twoEntryArchive = MergeRemoteV4Archive(
        inventory: [first, second],
        proof: proof,
      );
      await expectLater(
        remote.publishV4Archive(twoEntryArchive),
        throwsA(isA<MergeRemoteConflictException>()),
      );
      expect(server._files[baselinePath], orderedEquals(originalBaselineBytes));

      final acceptedTwo = await remote.publishV4Archive(
        twoEntryArchive,
        acceptChanges: true,
      );
      expect(acceptedTwo.inventory, hasLength(2));
      expect(server._files[baselinePath], orderedEquals(originalBaselineBytes));
      expect(
        server._files.keys.where(
          (path) => path.contains('/archive-v4-imports/'),
        ),
        hasLength(1),
      );

      final third = injectV4Commit(
        createTestBatch(actor: 'legacy_import_three', counter: 1),
        deviceName: 'Archive Device Three',
      );
      final threeEntryArchive = MergeRemoteV4Archive(
        inventory: [first, second, third],
        proof: proof,
      );
      await expectLater(
        remote.publishV4Archive(threeEntryArchive),
        throwsA(isA<MergeRemoteConflictException>()),
      );
      final acceptedThree = await remote.publishV4Archive(
        threeEntryArchive,
        acceptChanges: true,
      );
      expect(acceptedThree.inventory, hasLength(3));
      expect(server._files[baselinePath], orderedEquals(originalBaselineBytes));
      expect(
        server._files.keys.where(
          (path) => path.contains('/archive-v4-imports/'),
        ),
        hasLength(2),
      );

      final freshReader = MergeRemote(
        remote.client,
        deviceName: 'Fresh Archive Reader',
      );
      final globallyAccepted = await freshReader.readV4Archive();
      expect(
        globallyAccepted!.inventory.map((entry) => entry.filename).toSet(),
        {first.filename, second.filename, third.filename},
      );
    },
  );

  test(
    'concurrent identical archive publication resolves conditional 412 safely',
    () async {
      final proofBatch = createTestBatch(
        actor: 'archive_race_proof',
        counter: 1,
      );
      final proofPath = await remote.upload(proofBatch);
      final proof = (await remote.list()).singleWhere(
        (entry) => entry.filename == proofPath,
      );
      final v4Entry = injectV4Commit(
        createTestBatch(actor: 'archive_race_v4', counter: 1),
        deviceName: 'Archive Race Device',
      );
      final archive = MergeRemoteV4Archive(inventory: [v4Entry], proof: proof);
      final secondWriter = MergeRemote(
        remote.client,
        deviceName: 'Concurrent Archive Writer',
      );
      server.synchronizeArchivePutRequests(2);

      final results = await Future.wait([
        remote.publishV4Archive(archive),
        secondWriter.publishV4Archive(archive),
      ]);

      expect(results, hasLength(2));
      expect(results.every((result) => result.inventory.length == 1), isTrue);
      expect(server.archivePutCount, 2);
      expect(server.lastArchivePutHeaders!['if-none-match']?.firstOrNull, '*');
      expect(
        server._files['/dav/VeneraPlus/sync-v5/archive-v4.json'],
        isNotEmpty,
      );
      expect(
        (await secondWriter.readV4Archive())!.inventory.single.filename,
        v4Entry.filename,
      );
    },
  );

  test('archive marker proof bypasses a local Pack cache', () async {
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'sync-v5-proof-cache-',
    );
    try {
      final cachedRemote = MergeRemote(
        remote.client,
        deviceName: 'Proof Cache Device',
        cacheDirectory: cacheDirectory,
      );
      final proofBatch = createTestBatch(
        actor: 'missing_archive_proof',
        counter: 1,
      );
      final proofPath = await cachedRemote.upload(proofBatch);
      final proof = (await cachedRemote.list()).singleWhere(
        (entry) => entry.filename == proofPath,
      );
      final manifest = SyncPackManifest.parse(
        Uint8List.fromList(server._files['/dav/$proofPath']!),
      );
      final packDigest = manifest.packs.keys.single;
      final basePath = proofPath.substring(
        0,
        proofPath.lastIndexOf('/commits/'),
      );
      server._files.remove('/dav/$basePath/packs/$packDigest.pack');
      server._etags.remove('/dav/$basePath/packs/$packDigest.pack');
      final v4Entry = injectV4Commit(
        createTestBatch(actor: 'archived_v4_without_proof', counter: 1),
        deviceName: 'Unproven Archive Device',
      );

      await expectLater(
        cachedRemote.publishV4Archive(
          MergeRemoteV4Archive(inventory: [v4Entry], proof: proof),
        ),
        throwsA(isA<MergeRemoteException>()),
      );
      expect(
        server.hasFile('/dav/VeneraPlus/sync-v5/archive-v4.json'),
        isFalse,
      );
    } finally {
      await cacheDirectory.delete(recursive: true);
    }
  });

  group('Consumer fail-first, truncated file recovery, and valid SHA scenario', () {
    test(
      'consumer skips truncated latest, reads valid older, and authoring device recovers torn file via retry',
      () async {
        // 1. Authoring device publishes good checkpoint 1
        final batch1 = createTestBatch(actor: 'device-recover', counter: 1);
        await remote.upload(batch1);

        // 2. Authoring device attempts upload of checkpoint 2, but server truncates/tears the write
        final doc2 = batch1.document.clone();
        final updated = doc2.materialize()
          ..['["folder","f2"]'] = {'name': 'Folder 2'};
        doc2.captureLocal(
          'device-recover',
          batch1.document.materialize(),
          updated,
        );
        final batch2 = MergeBatch.create(
          actor: 'device-recover',
          counter: 2,
          document: doc2,
        );

        server.truncateNextPut = true;
        await expectLater(
          remote.upload(batch2),
          throwsA(isA<MergeRemoteCorruptException>()),
        );

        // Server now holds a torn/truncated non-zero file for batch 2
        final candidates = await remote.list();
        expect(candidates.any((e) => e.counter == 2), isTrue);

        // 3. Consumer calls downloadLatestValid:
        // Candidate 2 fails cryptographic SHA check, consumer skips it with warning, and receives valid Batch 1
        final corruptWarnings = <String>[];
        final consumerBatch = await remote.downloadLatestValid(
          'device-recover',
          candidates,
          onCorruptCandidate: (cand, err) {
            corruptWarnings.add(cand.filename);
          },
        );

        expect(consumerBatch, isNotNull);
        expect(consumerBatch!.counter, 1);
        expect(consumerBatch.id, batch1.id);
        expect(corruptWarnings.length, 1);
        expect(corruptWarnings.first, contains('/2-'));

        // 4. Authoring device retries uploading batch 2:
        // HTTP 412 is encountered. Upload inspects HEAD, obtains quoted strong ETag,
        // and safely replaces the truncated file using conditional If-Match: strongEtag.
        final recoveredPath = await remote.upload(batch2);
        expect(
          recoveredPath,
          startsWith('VeneraPlus/sync-v5/Device/commits/2-'),
        );

        // 5. Consumer refreshes listing and calls downloadLatestValid:
        // Now candidate 2 succeeds cleanly with valid SHA!
        final refreshedCandidates = await remote.list();
        final finalBatch = await remote.downloadLatestValid(
          'device-recover',
          refreshedCandidates,
        );

        expect(finalBatch, isNotNull);
        expect(finalBatch!.counter, 2);
        expect(finalBatch.id, batch2.id);
      },
    );
  });

  group('Directory and path casing preservation', () {
    test(
      'preserves mixed-case paths over HTTP with a literal-percent base',
      () async {
        // `%25` encodes the fixture's logical `/dav%` base in its URL.
        server.addDirectory('/dav%');
        final customClient = WebDavEndpoint(
          url: '${server.baseUrl}/dav%25',
          user: 'testuser',
          password: 'testpass',
        ).createClient();
        customClient.c.httpClientAdapter = IOHttpClientAdapter();
        final customRemote = MergeRemote(
          customClient,
          deviceName: 'My Device 机',
        );

        try {
          final batch = createTestBatch(actor: 'MyDevice-Actor', counter: 1);
          final uploadedPath = await customRemote.upload(batch);

          expect(
            uploadedPath,
            startsWith('VeneraPlus/sync-v5/My Device 机/commits/1-'),
          );

          final entries = await customRemote.list();
          expect(entries.length, 1);
          expect(
            entries.first.filename,
            startsWith('VeneraPlus/sync-v5/My Device 机/commits/1-'),
          );

          final downloaded = await customRemote.download(entries.single);
          expect(downloaded.id, batch.id);
          expect(downloaded.actor, batch.actor);
          expect(downloaded.counter, batch.counter);
          expect(
            downloaded.document.materialize(),
            batch.document.materialize(),
          );

          expect(server.receivedRequests, contains('PUT /dav%/$uploadedPath'));
          expect(server.receivedRequests, contains('GET /dav%/$uploadedPath'));
          expect(
            server.receivedRawRequests.any(
              (request) => request.startsWith('PUT /dav%25/'),
            ),
            isTrue,
          );
          expect(
            server.receivedRawRequests.any(
              (request) => request.startsWith('GET /dav%25/'),
            ),
            isTrue,
          );
          expect(server.hasFile('/dav%/$uploadedPath'), isTrue);
          expect(server.hasFile('/dav%25/$uploadedPath'), isFalse);
        } finally {
          customClient.c.close(force: true);
        }
      },
    );
  });

  group('Streamed PUT upload and post-upload verification', () {
    test(
      'uploads packed data then a conditional content-addressed manifest',
      () async {
        final batch = createTestBatch(actor: 'device-stream', counter: 3);
        final packed = SyncPackSnapshot.fromSnapshot(
          MergeSnapshot.fromBatch(batch),
        );
        await remote.upload(batch);

        final putHeaderMap = server.lastPutHeaders;
        expect(putHeaderMap, isNotNull);
        expect(putHeaderMap!['if-none-match']?.firstOrNull, '*');
        expect(
          putHeaderMap['content-type']?.firstOrNull,
          'application/json; charset=utf-8',
        );
        expect(
          putHeaderMap['content-length']?.firstOrNull,
          packed.serializeManifest().length.toString(),
        );

        final packHeaders = server.lastPackPutHeaders;
        expect(packHeaders, isNotNull);
        expect(packHeaders!['if-none-match']?.firstOrNull, '*');
        expect(
          packHeaders['content-type']?.firstOrNull,
          'application/octet-stream',
        );

        // Ping (OPTIONS) must not contain conditional headers.
        final optionsHeaderMaps = server.optionsHeaders;
        for (final headers in optionsHeaderMaps) {
          expect(headers['if-match'], isNull);
          expect(headers['if-none-match'], isNull);
        }
      },
    );

    test(
      'post-upload read-back verifies file integrity and catches server-truncated writes',
      () async {
        server.truncateNextPut = true;
        final batch = createTestBatch(actor: 'device-truncate', counter: 1);

        expect(
          () => remote.upload(batch),
          throwsA(isA<MergeRemoteCorruptException>()),
        );
      },
    );
  });

  test(
    'first sync packs many partitions into few physical files and requests',
    () async {
      final records = <String, Map<String, Object?>>{
        for (var index = 0; index < 96; index++)
          syncRecordKey('history', ['comic-$index', 'chapter-1']): {
            'ep': index,
            'page': index + 1,
          },
      };
      final batch = createTestBatch(
        actor: 'many_partitions',
        counter: 1,
        records: records,
      );
      final path = await remote.upload(batch);
      final manifest = SyncPackManifest.parse(
        Uint8List.fromList(server._files['/dav/$path']!),
      );

      expect(manifest.objects.length, greaterThan(12));
      expect(manifest.packs.length, lessThan(manifest.objects.length));
      expect(
        server._files.keys.where((file) => file.contains('/packs/')).length,
        manifest.packs.length,
      );
      expect(server.objectPutCount, manifest.packs.length);
      expect(server.commitPutCount, 1);
      final lastPackReadBack = server.receivedRequests.lastIndexWhere(
        (request) => request.startsWith('GET ') && request.contains('/packs/'),
      );
      final manifestPutIndex = server.receivedRequests.indexWhere(
        (request) =>
            request.startsWith('PUT ') && request.contains('/commits/'),
      );
      expect(lastPackReadBack, greaterThanOrEqualTo(0));
      expect(lastPackReadBack, lessThan(manifestPutIndex));
      final methodCounts =
          remote.transferStats['requestCounts']! as Map<String, int>;
      expect(methodCounts['PUT'], lessThanOrEqualTo(manifest.packs.length + 2));
      expect(remote.uploadedObjects, manifest.packs.length);
      expect(
        server.receivedRequests
            .where(
              (request) =>
                  request == 'PROPFIND /dav/VeneraPlus/sync-v5/Device/packs',
            )
            .length,
        1,
      );
    },
  );

  test(
    'pack upload uses at most four workers and drains them before failure',
    () async {
      server.packPutDelay = const Duration(milliseconds: 30);
      server.failPackPutAt = 2;
      final batch = createTestBatch(
        actor: 'pack_upload_failure',
        counter: 1,
        records: createLargePackRecords(20),
      );

      await expectLater(
        remote.upload(batch),
        throwsA(isA<MergeRemoteException>()),
      );
      expect(server.maxActivePackRequests, greaterThan(1));
      expect(server.maxActivePackRequests, lessThanOrEqualTo(4));
      expect(server.activePackRequests, 0);
      expect(server.commitPutCount, 0);
      expect(
        server.receivedRequests.where(
          (request) =>
              request.startsWith('PUT ') && request.contains('/commits/'),
        ),
        isEmpty,
      );
    },
  );

  test('pack download uses at most four concurrent physical GETs', () async {
    final batch = createTestBatch(
      actor: 'pack_download_pool',
      counter: 1,
      records: createLargePackRecords(20),
    );
    final path = await remote.upload(batch);
    final entry = MergeRemoteEntry.tryParsePackCommit(
      path,
      actor: batch.actor,
    )!;
    final manifest = SyncPackManifest.parse(
      Uint8List.fromList(server._files['/dav/$path']!),
    );
    server.maxActivePackRequests = 0;
    server.packGetDelay = const Duration(milliseconds: 30);
    remote.resetTransferStats();

    expect((await remote.download(entry)).toJson(), batch.toJson());
    expect(server.maxActivePackRequests, greaterThan(1));
    expect(server.maxActivePackRequests, lessThanOrEqualTo(4));
    expect(server.activePackRequests, 0);
    expect(remote.downloadedObjects, manifest.packs.length);
  });
  test(
    'default no-cache uploads keep incremental pack publication state',
    () async {
      await expectIncrementalPackReuse(remote, 'default_no_cache_incremental');
    },
  );

  test(
    'unwritable disk cache falls back to incremental in-memory publication state',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-v5-unwritable-cache-',
      );
      try {
        final cachePath =
            '${cacheDirectory.path}${Platform.pathSeparator}sync-v5-packs';
        await File(cachePath).writeAsString('cache root is a file');
        final uncachedRemote = MergeRemote(
          remote.client,
          deviceName: 'Unwritable Cache Device',
          cacheDirectory: cacheDirectory,
        );
        await expectIncrementalPackReuse(
          uncachedRemote,
          'unwritable_cache_incremental',
        );
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'reuses unchanged objects across an incremental pack publication',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-v5-incremental-packs-',
      );
      try {
        final cachedRemote = MergeRemote(
          remote.client,
          deviceName: 'Device',
          cacheDirectory: cacheDirectory,
        );
        final historyKey = syncRecordKey('history', ['comic-a', 'chapter-1']);
        final settingKey = syncRecordKey('setting', ['themeMode']);
        final first = createTestBatch(
          actor: 'object_cache',
          counter: 1,
          records: {
            historyKey: {'ep': 1, 'page': 2},
            settingKey: {'value': 'dark'},
          },
        );
        final firstPath = await cachedRemote.upload(first);
        final firstManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$firstPath']!),
        );
        final firstHistory = firstManifest.objects.singleWhere(
          (reference) => reference['domain'] == 'history',
        );
        expect(cachedRemote.uploadedObjects, firstManifest.packs.length);
        expect(cachedRemote.downloadedObjects, firstManifest.packs.length);

        final nextDocument = first.document.clone();
        final before = first.document.materialize();
        final after = {
          ...before,
          settingKey: {'value': 'light'},
        };
        nextDocument.captureLocal('object_cache', before, after);
        final second = MergeBatch.create(
          actor: 'object_cache',
          counter: 2,
          document: nextDocument,
        );
        cachedRemote.resetTransferStats();
        final secondPath = await cachedRemote.upload(second);
        final secondManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$secondPath']!),
        );
        final secondHistory = secondManifest.objects.singleWhere(
          (reference) => reference['domain'] == 'history',
        );

        expect(secondHistory['path'], firstHistory['path']);
        expect(secondHistory['packSha256'], firstHistory['packSha256']);
        expect(cachedRemote.uploadedObjects, 1);
        expect(cachedRemote.downloadedObjects, 1);
        expect(server.objectPutCount, firstManifest.packs.length + 1);
        await cachedRemote.list();
        expect(cachedRemote.deviceNames['object_cache'], 'Device');
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'repairs a missing reused remote pack from the verified pack cache',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-v5-missing-pack-',
      );
      try {
        final cachedRemote = MergeRemote(
          remote.client,
          deviceName: 'Device',
          cacheDirectory: cacheDirectory,
        );
        final actor = 'cached_pack_missing';
        final historyKey = syncRecordKey('history', ['comic-a', 'chapter-1']);
        final settingKey = syncRecordKey('setting', ['themeMode']);
        final first = createTestBatch(
          actor: actor,
          counter: 1,
          records: {
            historyKey: {'ep': 1, 'page': 2},
            settingKey: {'value': 'dark'},
          },
        );
        final firstPath = await cachedRemote.upload(first);
        final firstManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$firstPath']!),
        );
        final missingPack = firstManifest.packs.keys.single;
        final missingPath =
            '/dav/VeneraPlus/sync-v5/Device/packs/$missingPack.pack';
        server._files.remove(missingPath);
        server._etags.remove(missingPath);

        final nextDocument = first.document.clone();
        final before = first.document.materialize();
        nextDocument.captureLocal(actor, before, {
          ...before,
          settingKey: {'value': 'dark-high-contrast'},
        });
        final second = MergeBatch.create(
          actor: actor,
          counter: 2,
          document: nextDocument,
        );
        cachedRemote.resetTransferStats();
        final secondPath = await cachedRemote.upload(second);
        final secondManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$secondPath']!),
        );

        expect(server.hasFile(missingPath), isTrue);
        expect(secondManifest.packs, contains(missingPack));
        expect(cachedRemote.uploadedObjects, 2);
        expect(server.objectPutCount, firstManifest.packs.length + 2);
        final latest = await cachedRemote.downloadLatestValid(
          actor,
          await cachedRemote.list(),
        );
        expect(latest?.toJson(), second.toJson());
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'unsupported HEAD and missing Content-Length fall back to pack GETs',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-v5-head-fallback-',
      );
      try {
        final cachedRemote = MergeRemote(
          remote.client,
          deviceName: 'Device',
          cacheDirectory: cacheDirectory,
        );
        final actor = 'head_fallback';
        final historyKey = syncRecordKey('history', ['comic-a', 'chapter-1']);
        final settingKey = syncRecordKey('setting', ['themeMode']);
        final first = createTestBatch(
          actor: actor,
          counter: 1,
          records: {
            historyKey: {'ep': 1, 'page': 2},
            settingKey: {'value': 'dark'},
          },
        );
        final firstPath = await cachedRemote.upload(first);
        final firstManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$firstPath']!),
        );
        final firstPack = firstManifest.packs.keys.single;

        MergeBatch changeSetting(MergeBatch source, int counter, String value) {
          final document = source.document.clone();
          final before = source.document.materialize();
          document.captureLocal(actor, before, {
            ...before,
            settingKey: {'value': value},
          });
          return MergeBatch.create(
            actor: actor,
            counter: counter,
            document: document,
          );
        }

        server.headUnsupported = true;
        var requestStart = server.receivedRequests.length;
        final second = changeSetting(first, 2, 'light');
        final secondPath = await cachedRemote.upload(second);
        final secondManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$secondPath']!),
        );
        expect(
          server.receivedRequests.skip(requestStart),
          contains('GET /dav/VeneraPlus/sync-v5/Device/packs/$firstPack.pack'),
        );

        server.headUnsupported = false;
        server.omitHeadContentLength = true;
        cachedRemote.resetTransferStats();
        requestStart = server.receivedRequests.length;
        final third = changeSetting(second, 3, 'contrast');
        final thirdPath = await cachedRemote.upload(third);
        final thirdManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$thirdPath']!),
        );
        final thirdRequests = server.receivedRequests.skip(requestStart);
        final reusedPacks = secondManifest.packs.keys.where(
          thirdManifest.packs.containsKey,
        );
        for (final digest in reusedPacks) {
          expect(
            thirdRequests,
            contains('GET /dav/VeneraPlus/sync-v5/Device/packs/$digest.pack'),
          );
        }
        expect(cachedRemote.uploadedObjects, 1);
        expect(cachedRemote.downloadedObjects, thirdManifest.packs.length);
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'repairs a corrupt cached pack only with strong If-Match and readback',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-v5-pack-repair-',
      );
      try {
        final cachedRemote = MergeRemote(
          remote.client,
          deviceName: 'Device',
          cacheDirectory: cacheDirectory,
        );
        final actor = 'pack_repair';
        final historyKey = syncRecordKey('history', ['comic-a', 'chapter-1']);
        final settingKey = syncRecordKey('setting', ['themeMode']);
        final first = createTestBatch(
          actor: actor,
          counter: 1,
          records: {
            historyKey: {'ep': 1, 'page': 2},
            settingKey: {'value': 'dark'},
          },
        );
        final firstPath = await cachedRemote.upload(first);
        final firstManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$firstPath']!),
        );
        final digest = firstManifest.packs.keys.single;
        final packPath = '/dav/VeneraPlus/sync-v5/Device/packs/$digest.pack';
        final correctPack = List<int>.of(server._files[packPath]!);
        server.tamperFile(
          packPath,
          correctPack.sublist(0, correctPack.length - 1),
        );
        server.setFileEtag(packPath, '"pack-strong-validator"');

        final document = first.document.clone();
        final before = first.document.materialize();
        document.captureLocal(actor, before, {
          ...before,
          settingKey: {'value': 'light'},
        });
        final second = MergeBatch.create(
          actor: actor,
          counter: 2,
          document: document,
        );
        await cachedRemote.upload(second);

        expect(sha256.convert(server._files[packPath]!).toString(), digest);
        expect(
          server.packPutHeaderLogs.any(
            (headers) =>
                headers['if-match']?.firstOrNull == '"pack-strong-validator"',
          ),
          isTrue,
        );
        expect(
          server.packPutHeaderLogs.every(
            (headers) =>
                headers['if-none-match']?.firstOrNull == '*' ||
                headers['if-match']?.firstOrNull != null,
          ),
          isTrue,
        );
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
    },
  );

  test('reuses verified packs from the endpoint cache after restart', () async {
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'sync-v5-pack-cache-',
    );
    try {
      final cachedRemote = MergeRemote(
        remote.client,
        deviceName: 'Cached Device',
        cacheDirectory: cacheDirectory,
      );
      final batch = createTestBatch(
        actor: 'disk_cache_actor',
        counter: 1,
        records: {
          syncRecordKey('history', ['comic-a', 'chapter-1']): {
            'ep': 1,
            'page': 2,
          },
        },
      );
      final encoded = MergeSnapshot.fromBatch(batch);
      final persistedSnapshot =
          MergeSnapshot.fromEncoded(encoded.serializeManifest(), {
            for (final object in encoded.objects.entries)
              object.key: Uint8List.fromList(object.value),
          });
      final path = await cachedRemote.uploadSnapshot(persistedSnapshot);
      final restartedRemote = MergeRemote(
        remote.client,
        deviceName: 'Cached Device',
        cacheDirectory: cacheDirectory,
      );
      final entry = MergeRemoteEntry.tryParsePackCommit(
        path,
        actor: batch.actor,
      )!;
      final downloaded = await restartedRemote.download(entry);

      expect(downloaded.toJson(), batch.toJson());
      expect(restartedRemote.downloadedObjects, 0);
      final cacheFiles = <File>[];
      await for (final entity in cacheDirectory.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.pack')) {
          cacheFiles.add(entity);
        }
      }
      expect(cacheFiles, hasLength(1));
      final corruptCacheBytes = await cacheFiles.single.readAsBytes();
      corruptCacheBytes[0] ^= 1;
      await cacheFiles.single.writeAsBytes(corruptCacheBytes, flush: true);
      final corruptCacheRemote = MergeRemote(
        remote.client,
        deviceName: 'Cached Device',
        cacheDirectory: cacheDirectory,
      );
      final recovered = await corruptCacheRemote.download(entry);
      expect(recovered.toJson(), batch.toJson());
      expect(corruptCacheRemote.downloadedObjects, 1);
    } finally {
      await cacheDirectory.delete(recursive: true);
    }
  });

  test('rejects over-capacity pack inventories before any pack GET', () async {
    const actor = 'oversized_manifest';
    final packSize = SyncPack.maxPackBytes;
    final packCount = SyncPackManifest.maxTotalPackBytes ~/ packSize + 1;
    final packDigests = List<String>.generate(
      packCount,
      (index) => sha256.convert(utf8.encode('pack-$index')).toString(),
    )..sort();
    final manifest = <String, Object?>{
      'schema': 2,
      'actor': actor,
      'counter': 1,
      'batchId': 'a' * 64,
      'documentSchema': 3,
      'vclock': {actor: 1},
      'packs': {for (final digest in packDigests) digest: packSize},
      'objects': [
        for (var index = 0; index < packDigests.length; index++)
          {
            'path': 'history/${packDigests[index]}.json.gz',
            'domain': 'history',
            'partition': 'bucket-${index.toString().padLeft(2, '0')}',
            'sha256': packDigests[index],
            'compressedSize': 1,
            'uncompressedSize': 1,
            'recordCount': 1,
            'packSha256': packDigests[index],
            'offset': 0,
          },
      ],
    };
    final manifestBytes = Uint8List.fromList(
      utf8.encode(canonicalSyncJson(manifest)),
    );
    final digest = sha256.convert(manifestBytes).toString();
    const devicePath = 'VeneraPlus/sync-v5/Oversized Device';
    final commitPath = '$devicePath/commits/1-$digest.json';
    server.injectOwnership(
      '/dav/$devicePath',
      actor: actor,
      name: 'Oversized Device',
    );
    server.injectFile('/dav/$commitPath', manifestBytes);
    final entry = MergeRemoteEntry.tryParsePackCommit(
      commitPath,
      actor: actor,
    )!;
    final requestStart = server.receivedRequests.length;

    await expectLater(
      remote.download(entry),
      throwsA(isA<MergeRemoteCorruptException>()),
    );
    expect(
      server.receivedRequests
          .skip(requestStart)
          .where((request) => request.contains('/packs/')),
      isEmpty,
    );
  });

  group('GET redirect without ETag', () {
    test(
      'downloads redirected file lacking ETag verified by SHA-256',
      () async {
        final batch = createTestBatch(actor: 'device-redir', counter: 5);
        final uploadedPath = await remote.upload(batch);

        server.configureRedirect(
          fromPath: '/dav/$uploadedPath',
          toPath: '/dav/external-storage/redirected-batch.json',
          omitRedirectEtag: true,
        );

        final entries = await remote.list();
        final entry = entries.firstWhere((e) => e.actor == 'device-redir');

        final downloaded = await remote.download(entry);
        expect(downloaded.actor, 'device-redir');
        expect(downloaded.counter, 5);
        expect(downloaded.id, batch.id);
      },
    );
  });

  group('Idempotent retry and HTTP 412 verification', () {
    test(
      'same batch re-upload returns successfully on 412 after verifying existing hash',
      () async {
        final batch = createTestBatch(actor: 'device-idemp', counter: 1);

        final firstPath = await remote.upload(batch);
        expect(firstPath, isNotEmpty);

        // Second upload triggers HTTP 412 from server due to If-None-Match: *
        final secondPath = await remote.upload(batch);
        expect(secondPath, firstPath);
      },
    );

    test(
      'throws MergeRemoteConflictException when HTTP 412 has mismatched content and missing strong ETag',
      () async {
        final batch = createTestBatch(actor: 'device-mismatch', counter: 1);
        final path = await remote.upload(batch);

        // Tamper with the server's copy and remove strong ETag validator
        server.tamperFile('/dav/$path', utf8.encode('{"tampered":true}'));
        server.setFileEtag('/dav/$path', 'W/"weak-tampered"');

        expect(
          () => remote.upload(batch),
          throwsA(isA<MergeRemoteConflictException>()),
        );
      },
    );
  });

  group('Corrupted and incomplete file handling', () {
    test(
      '0-byte incomplete file does not mask older valid checkpoint in listLatest',
      () async {
        final validBatch = createTestBatch(
          actor: 'device-fallback',
          counter: 1,
        );
        await remote.upload(validBatch);

        final fakeDigest = 'b' * 64;
        server.injectFile(
          '/dav/VeneraPlus/sync-v5/Device/commits/2-$fakeDigest.json',
          Uint8List(0),
          eTag: '"etag-2"',
        );

        final entries = await remote.listLatest();
        final deviceEntry = entries.firstWhere(
          (e) => e.actor == 'device-fallback',
        );
        expect(deviceEntry.counter, 1);
        expect(
          deviceEntry.digest,
          SyncPackSnapshot.fromSnapshot(
            MergeSnapshot.fromBatch(validBatch),
          ).digest,
        );
      },
    );

    test(
      'download throws MergeRemoteCorruptException on corrupted bytes SHA256 mismatch',
      () async {
        final batch = createTestBatch(actor: 'device-corrupt', counter: 1);
        final path = await remote.upload(batch);

        server.tamperFile('/dav/$path', utf8.encode('{"corrupted":true}'));

        final entries = await remote.list();
        final entry = entries.firstWhere((e) => e.actor == 'device-corrupt');

        expect(
          () => remote.download(entry),
          throwsA(isA<MergeRemoteCorruptException>()),
        );
      },
    );
    test(
      'a corrupt newest Pack falls back to an older fully verified commit',
      () async {
        const actor = 'device-pack-fallback';
        final first = createTestBatch(
          actor: actor,
          counter: 1,
          records: {
            '["folder","one"]': {'name': 'One'},
          },
        );
        await remote.upload(first);

        final document = first.document.clone();
        final before = first.document.materialize();
        document.captureLocal(actor, before, {
          ...before,
          '["folder","two"]': {'name': 'Two'},
        });
        final second = MergeBatch.create(
          actor: actor,
          counter: 2,
          document: document,
        );
        final secondPath = await remote.upload(second);
        final secondManifest = SyncPackManifest.parse(
          Uint8List.fromList(server._files['/dav/$secondPath']!),
        );
        final corruptDigest = secondManifest.packs.keys.first;
        final corruptPackPath =
            '/dav/VeneraPlus/sync-v5/Device/packs/$corruptDigest.pack';
        final corrupted = List<int>.of(server._files[corruptPackPath]!);
        corrupted[0] ^= 1;
        server.tamperFile(corruptPackPath, corrupted);

        final skipped = <String>[];
        final recovered = await remote.downloadLatestValid(
          actor,
          await remote.list(),
          onCorruptCandidate: (candidate, _) => skipped.add(candidate.filename),
        );
        expect(recovered?.toJson(), first.toJson());
        expect(skipped, hasLength(1));
        expect(skipped.single, secondPath);
        expect(remote.warnings, [
          'Skipping a corrupt remote checkpoint candidate',
        ]);
      },
    );

    test(
      'rejects checkpoint payload actor that disagrees with device ownership metadata',
      () async {
        final doc = MergeDocument();
        doc.captureLocal('legit-actor', const {}, {
          'k': {'v': 1},
        });
        final mismatchedBatchMap = {
          'actor': 'different-actor',
          'counter': 1,
          'document': doc.toJson(),
        };
        final bytes = Uint8List.fromList(
          utf8.encode(jsonEncode(mismatchedBatchMap)),
        );
        final digest = sha256.convert(bytes).toString();

        final fakeFilename = 'VeneraPlus/Device/1-$digest.json';
        server.injectOwnership(
          '/dav/VeneraPlus/Device',
          actor: 'legit-actor',
          name: 'Device',
        );
        server.injectFile('/dav/$fakeFilename', bytes, eTag: '"etag-legit"');

        final entry = MergeRemoteEntry.tryParse(
          fakeFilename,
          actor: 'legit-actor',
          eTag: '"etag-legit"',
        )!;
        expect(
          () => remote.downloadLegacyCheckpoint(entry),
          throwsA(isA<MergeRemoteCorruptException>()),
        );
      },
    );
  });

  group(
    'Safe compaction with full content domination, quoted strong ETag, and observable warnings',
    () {
      test(
        'downloads predecessor, proves uploaded.document.dominates, and records observable warnings',
        () async {
          final doc1 = MergeDocument();
          doc1.captureLocal('owner-actor', const {}, {
            '["folder","f1"]': {'name': 'Folder 1'},
          });
          final batch1 = MergeBatch.create(
            actor: 'owner-actor',
            counter: 1,
            document: doc1,
          );

          // Batch 2 causally merges Batch 1
          final doc2 = MergeDocument();
          doc2.merge(doc1);
          doc2.captureLocal(
            'owner-actor',
            {
              '["folder","f1"]': {'name': 'Folder 1'},
            },
            {
              '["folder","f1"]': {'name': 'Folder 1 Renamed'},
            },
          );
          final batch2 = MergeBatch.create(
            actor: 'owner-actor',
            counter: 2,
            document: doc2,
          );

          // Predecessors from owner-actor
          final path1 = await remote.upload(batch1);
          final path2 = await remote.upload(batch2);

          // Other actor
          final batchOther = createTestBatch(actor: 'other-actor', counter: 1);
          final pathOther = await remote.upload(batchOther);
          server.injectFile(
            '/dav/.venera',
            Uint8List.fromList([1, 2, 3]),
            eTag: '"strong-legacy"',
          );

          // Both predecessors have strong validators; compaction must still keep the newest valid one.
          server.setFileEtag('/dav/$path1', '"strong-etag-1"');
          server.setFileEtag('/dav/$path2', '"strong-etag-2"');
          server.setFileEtag('/dav/$pathOther', '"strong-etag-other"');

          // Create an independent batch that did NOT merge Batch 1 (counter reserved to 5, but empty content)
          final docIndependent = MergeDocument();
          docIndependent.captureLocal('owner-actor', const {}, {
            '["folder","unrelated"]': {'name': 'Unrelated'},
          });
          docIndependent.setCounterFloor('owner-actor', 5);
          final batchUndominated = MergeBatch.create(
            actor: 'owner-actor',
            counter: 5,
            document: docIndependent,
          );

          final priorEntries = [
            MergeRemoteEntry.tryParsePackCommit(
              path1,
              actor: 'owner-actor',
              eTag: '"strong-etag-1"',
            )!,
            MergeRemoteEntry.tryParsePackCommit(
              path2,
              actor: 'owner-actor',
              eTag: '"strong-etag-2"',
            )!,
            MergeRemoteEntry.tryParsePackCommit(
              pathOther,
              actor: 'other-actor',
              eTag: '"strong-etag-other"',
            )!,
            // Forged listing identity cannot authorize deleting another owner's file.
            MergeRemoteEntry.tryParsePackCommit(
              pathOther,
              actor: 'owner-actor',
              eTag: '"strong-etag-other"',
            )!,
          ];

          // Compacting with batchUndominated must NOT delete batch1 because doc does not dominate doc1
          await remote.compact(batchUndominated, priorEntries);
          expect(
            server.hasFile('/dav/$path1'),
            isTrue,
            reason: 'Undominated predecessor must be retained',
          );

          // Now create Batch 3 that genuinely merges Batch 2 (which merged Batch 1)
          final doc3 = MergeDocument();
          doc3.merge(doc2);
          doc3.captureLocal(
            'owner-actor',
            {
              '["folder","f1"]': {'name': 'Folder 1 Renamed'},
            },
            {
              '["folder","f1"]': {'name': 'Folder 1 Final'},
            },
          );
          final batch3 = MergeBatch.create(
            actor: 'owner-actor',
            counter: 3,
            document: doc3,
          );
          await remote.upload(batch3);

          await remote.compact(batch3, priorEntries);

          // Check results:
          // batch1 had quoted strong ETag, own actor, counter 1 < 3, genuinely dominated => DELETED
          expect(server.hasFile('/dav/$path1'), isFalse);

          // The newest valid old commit remains as a recovery predecessor despite its strong ETag.
          expect(server.hasFile('/dav/$path2'), isTrue);

          // batchOther was another actor => RETAINED
          expect(server.hasFile('/dav/$pathOther'), isTrue);

          // legacy .venera file => RETAINED
          expect(server.hasFile('/dav/.venera'), isTrue);

          // Conditional DELETE must have attached If-Match: "strong-etag-1"
          final deleteHeaders = server.deleteHeaderLogs;
          expect(deleteHeaders.length, 1);
          expect(deleteHeaders.first['if-match'], '"strong-etag-1"');
        },
      );
      test(
        'skips weak and missing ETags before any candidate content read',
        () async {
          final batch = createTestBatch(actor: 'weak_compaction', counter: 1);
          final path = await remote.upload(batch);
          final weak = MergeRemoteEntry.tryParsePackCommit(
            path,
            actor: batch.actor,
            eTag: 'W/"weak"',
          )!;
          final missing = MergeRemoteEntry.tryParsePackCommit(
            path,
            actor: batch.actor,
          )!;
          final uploaded = createTestBatch(actor: batch.actor, counter: 2);
          final requestStart = server.receivedRequests.length;

          await remote.compact(uploaded, [weak, missing]);

          expect(server.receivedRequests.skip(requestStart), isEmpty);
          expect(server.deleteHeaderLogs, isEmpty);
        },
      );
      test(
        'drains an over-budget candidate download before returning',
        () async {
          final prior = createTestBatch(actor: 'slow_compaction', counter: 1);
          final path = await remote.upload(prior);
          final entry = MergeRemoteEntry.tryParsePackCommit(
            path,
            actor: prior.actor,
            eTag: '"strong-slow-etag"',
          )!;
          final uploaded = createTestBatch(actor: prior.actor, counter: 2);
          server.packGetDelay = const Duration(milliseconds: 2100);
          final timer = Stopwatch()..start();

          await remote.compact(uploaded, [entry]);

          expect(
            timer.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 2)),
          );
          expect(server.activePackRequests, 0);
          expect(server.deleteHeaderLogs, isEmpty);
          final requestCount = server.receivedRequests.length;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(server.receivedRequests, hasLength(requestCount));
        },
      );
    },
  );
}

/// In-memory loopback WebDAV server for HTTP protocol verification.
class _LoopbackWebDavServer {
  _LoopbackWebDavServer(this._server);

  final HttpServer _server;
  final Map<String, List<int>> _files = {};
  final Map<String, String> _etags = {};
  final Set<String> _directories = {'/dav'};
  final List<String> receivedRequests = [];
  final List<String> receivedRawRequests = [];
  final List<Map<String, List<String>>> optionsHeaders = [];
  Map<String, List<String>>? lastPutHeaders;
  Map<String, List<String>>? lastCheckpointPutHeaders;
  Map<String, List<String>>? lastPackPutHeaders;
  final List<Map<String, List<String>>> packPutHeaderLogs = [];
  Map<String, List<String>>? lastArchivePutHeaders;
  final List<Map<String, List<String>>> markerPutHeaders = [];
  final List<Map<String, String>> deleteHeaderLogs = [];
  final Map<String, int> getStatuses = {};
  int markerPutCount = 0;
  int checkpointPutCount = 0;
  int commitPutCount = 0;
  int objectPutCount = 0;
  int archivePutCount = 0;
  Completer<void>? _archivePutBarrier;
  int _archivePutBarrierTarget = 0;
  int _archivePutBarrierArrivals = 0;
  int activePackRequests = 0;
  int maxActivePackRequests = 0;
  Duration packPutDelay = Duration.zero;
  Duration packGetDelay = Duration.zero;
  int? failPackPutAt;

  String? _redirectFrom;
  String? _redirectTo;
  bool _omitRedirectEtag = false;
  bool truncateNextPut = false;
  bool headUnsupported = false;
  bool omitHeadContentLength = false;
  void synchronizeArchivePutRequests(int count) {
    _archivePutBarrier = Completer<void>();
    _archivePutBarrierTarget = count;
    _archivePutBarrierArrivals = 0;
  }

  Future<void> _waitForArchivePutBarrier() async {
    final barrier = _archivePutBarrier;
    if (barrier == null) return;
    _archivePutBarrierArrivals++;
    if (_archivePutBarrierArrivals >= _archivePutBarrierTarget &&
        !barrier.isCompleted) {
      barrier.complete();
    }
    await barrier.future;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_LoopbackWebDavServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _LoopbackWebDavServer(server);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  void addDirectory(String path) {
    _directories.add(_canonicalPath(path));
  }

  String _canonicalPath(String path) {
    // Fixture paths are logical text. Only HTTP ingress decodes URI escapes.
    if (path.length > 1 && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    if (separator <= 0) return '/';
    return path.substring(0, separator);
  }

  void _addDirectoryTree(String path) {
    var current = _canonicalPath(path);
    while (current != '/' && current.isNotEmpty) {
      _directories.add(current);
      current = _parentPath(current);
    }
  }

  String _encodeHref(String path, {bool directory = false}) {
    final segments = path.split('/').map(Uri.encodeComponent).join('/');
    return '$segments${directory ? '/' : ''}';
  }

  void configureRedirect({
    required String fromPath,
    required String toPath,
    bool omitRedirectEtag = false,
  }) {
    _redirectFrom = _canonicalPath(fromPath);
    _redirectTo = _canonicalPath(toPath);
    _omitRedirectEtag = omitRedirectEtag;
    if (_files.containsKey(_redirectFrom)) {
      _files[_redirectTo!] = _files[_redirectFrom!]!;
      _etags[_redirectTo!] = _etags[_redirectFrom!] ?? '"redirect-etag"';
      _addDirectoryTree(_redirectTo!);
    }
  }

  void injectFile(String path, List<int> content, {String? eTag}) {
    final canonical = _canonicalPath(path);
    _addDirectoryTree(_parentPath(canonical));
    _files[canonical] = content;
    if (eTag != null) {
      _etags[canonical] = eTag;
    }
  }

  void injectOwnership(
    String directoryPath, {
    required String actor,
    required String name,
  }) {
    final canonicalDirectory = _canonicalPath(directoryPath);
    _addDirectoryTree(canonicalDirectory);
    injectFile(
      '$canonicalDirectory/device.json',
      utf8.encode(jsonEncode({'actor': actor, 'name': name})),
    );
  }

  void tamperFile(String path, List<int> newContent) {
    _files[_canonicalPath(path)] = newContent;
  }

  void setFileEtag(String path, String eTag) {
    _etags[_canonicalPath(path)] = eTag;
  }

  bool hasFile(String path) => _files.containsKey(_canonicalPath(path));

  void _writePropfindResponse(
    StringBuffer buffer,
    String path, {
    required bool isDirectory,
    List<int>? content,
    String? eTag,
  }) {
    final fileEtag =
        eTag ?? (content == null ? null : '"etag-${sha256.convert(content)}"');
    buffer.writeln('  <D:response>');
    buffer.writeln(
      '    <D:href>${_encodeHref(path, directory: isDirectory)}</D:href>',
    );
    buffer.writeln('    <D:propstat>');
    buffer.writeln('      <D:prop>');
    if (isDirectory) {
      buffer.writeln(
        '        <D:resourcetype><D:collection/></D:resourcetype>',
      );
    } else {
      buffer.writeln('        <D:resourcetype/>');
      buffer.writeln(
        '        <D:getcontentlength>${content!.length}</D:getcontentlength>',
      );
      buffer.writeln(
        '        <D:getcontenttype>application/json</D:getcontenttype>',
      );
      if (fileEtag != null) {
        buffer.writeln('        <D:getetag>$fileEtag</D:getetag>');
      }
    }
    buffer.writeln(
      '        <D:getlastmodified>Wed, 07 Oct 2026 12:00:00 GMT</D:getlastmodified>',
    );
    buffer.writeln('      </D:prop>');
    buffer.writeln('      <D:status>HTTP/1.1 200 OK</D:status>');
    buffer.writeln('    </D:propstat>');
    buffer.writeln('  </D:response>');
  }

  Future<void> _handle(HttpRequest request) async {
    receivedRawRequests.add('${request.method} ${request.uri.path}');
    final path = _canonicalPath(Uri.decodeComponent(request.uri.path));
    receivedRequests.add('${request.method} $path');
    final body = await request.fold<List<int>>(
      [],
      (buffer, chunk) => buffer..addAll(chunk),
    );

    if (request.method == 'OPTIONS') {
      final headersMap = <String, List<String>>{};
      request.headers.forEach((name, values) {
        headersMap[name.toLowerCase()] = values;
      });
      optionsHeaders.add(headersMap);
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    if (request.method == 'HEAD') {
      if (headUnsupported) {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final content = _files[path];
      if (content == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      final etag = _etags[path];
      if (etag != null) request.response.headers.set('etag', etag);
      if (!omitHeadContentLength) {
        request.response.headers.contentLength = content.length;
      }
      await request.response.close();
      return;
    }

    if (request.method == 'MKCOL') {
      if (_directories.contains(path)) {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else if (!_directories.contains(_parentPath(path))) {
        request.response.statusCode = HttpStatus.conflict;
      } else {
        _directories.add(path);
        request.response.statusCode = HttpStatus.created;
      }
      await request.response.close();
      return;
    }

    if (request.method == 'PROPFIND') {
      if (!_directories.contains(path)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );

      final buffer = StringBuffer()
        ..writeln('<?xml version="1.0" encoding="utf-8"?>')
        ..writeln('<D:multistatus xmlns:D="DAV:">');
      _writePropfindResponse(buffer, path, isDirectory: true);

      final directDirectories =
          _directories
              .where(
                (directory) =>
                    directory != path && _parentPath(directory) == path,
              )
              .toList()
            ..sort();
      for (final directory in directDirectories) {
        _writePropfindResponse(buffer, directory, isDirectory: true);
      }

      final directFiles =
          _files.keys
              .where((filePath) => _parentPath(filePath) == path)
              .toList()
            ..sort();
      for (final filePath in directFiles) {
        final bytes = _files[filePath]!;
        _writePropfindResponse(
          buffer,
          filePath,
          isDirectory: false,
          content: bytes,
          eTag: _etags[filePath],
        );
      }
      buffer.writeln('</D:multistatus>');
      request.response.write(buffer.toString());
      await request.response.close();
      return;
    }

    if (request.method == 'HEAD') {
      final content = _files[path];
      if (content == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        final etag = _etags[path];
        if (etag != null) request.response.headers.set('etag', etag);
      }
      await request.response.close();
      return;
    }

    if (request.method == 'PUT') {
      final headersMap = <String, List<String>>{};
      request.headers.forEach((name, values) {
        headersMap[name.toLowerCase()] = values;
      });
      lastPutHeaders = headersMap;
      final isMarker = path.endsWith('/device.json');
      final isCommit = path.contains('/commits/');
      final isPack = path.contains('/packs/');
      final isArchive =
          path.endsWith('/archive-v4.json') ||
          path.contains('/archive-v4-imports/');
      if (isMarker) {
        markerPutCount++;
        markerPutHeaders.add(headersMap);
      } else {
        checkpointPutCount++;
        lastCheckpointPutHeaders = headersMap;
        if (isCommit) {
          commitPutCount++;
        } else if (isPack) {
          objectPutCount++;
          packPutHeaderLogs.add(headersMap);
          lastPackPutHeaders = headersMap;
        }
      }
      if (isArchive) {
        archivePutCount++;
        lastArchivePutHeaders = headersMap;
        await _waitForArchivePutBarrier();
      }
      if (isPack) {
        final packPutNumber = objectPutCount;
        activePackRequests++;
        if (activePackRequests > maxActivePackRequests) {
          maxActivePackRequests = activePackRequests;
        }
        if (packPutDelay > Duration.zero) {
          await Future<void>.delayed(packPutDelay);
        }
        if (failPackPutAt == packPutNumber) {
          activePackRequests--;
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
      }

      final ifNoneMatch = request.headers.value('if-none-match');
      if (ifNoneMatch == '*' && _files.containsKey(path)) {
        if (isPack) activePackRequests--;
        request.response.statusCode = HttpStatus.preconditionFailed;
        await request.response.close();
        return;
      }

      final ifMatch = request.headers.value('if-match');
      if (ifMatch != null) {
        final currentEtag = _etags[path];
        if (currentEtag != null && ifMatch != currentEtag) {
          if (isPack) activePackRequests--;
          request.response.statusCode = HttpStatus.preconditionFailed;
          await request.response.close();
          return;
        }
      }

      _addDirectoryTree(_parentPath(path));
      if (truncateNextPut && isCommit) {
        truncateNextPut = false;
        _files[path] = body.sublist(0, math.min(10, body.length));
      } else {
        _files[path] = body;
      }
      _etags[path] = '"etag-${sha256.convert(_files[path]!)}"';
      request.response.statusCode = HttpStatus.created;
      if (isPack) activePackRequests--;
      await request.response.close();
      return;
    }

    if (request.method == 'GET') {
      final forcedStatus = getStatuses[path];
      if (forcedStatus != null) {
        request.response.statusCode = forcedStatus;
        await request.response.close();
        return;
      }
      if (_redirectFrom != null && path == _redirectFrom) {
        request.response.statusCode = HttpStatus.movedTemporarily;
        request.response.headers.set('location', '$_redirectTo');
        await request.response.close();
        return;
      }

      final content = _files[path];
      if (content == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final isPack = path.contains('/packs/');
      if (isPack) {
        activePackRequests++;
        if (activePackRequests > maxActivePackRequests) {
          maxActivePackRequests = activePackRequests;
        }
        if (packGetDelay > Duration.zero) {
          await Future<void>.delayed(packGetDelay);
        }
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      if (!(_omitRedirectEtag && path == _redirectTo)) {
        final etag = _etags[path];
        if (etag != null) request.response.headers.set('etag', etag);
      }
      request.response.add(content);
      if (isPack) activePackRequests--;
      await request.response.close();
      return;
    }

    if (request.method == 'DELETE') {
      final ifMatch = request.headers.value('if-match');
      final logMap = <String, String>{};
      if (ifMatch != null) logMap['if-match'] = ifMatch;
      deleteHeaderLogs.add(logMap);
      if (!_files.containsKey(path)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final currentEtag = _etags[path];
      if (ifMatch != null && currentEtag != null && ifMatch != currentEtag) {
        request.response.statusCode = HttpStatus.preconditionFailed;
        await request.response.close();
        return;
      }
      _files.remove(path);
      _etags.remove(path);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.methodNotAllowed;
    await request.response.close();
  }
}
