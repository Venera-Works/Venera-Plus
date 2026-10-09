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
    return MergeRemoteEntry.tryParsePackCommit(path, actor: actor, eTag: eTag)!;
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
    expect(server.objectPutCount - putsBefore, firstManifest.packs.length + 1);
    final readBack = await MergeRemote(
      remote.client,
    ).download(parseEntry(secondPath, actor));
    expect(readBack.document.toJson(), second.document.toJson());
  }

  group('MergeRemote entry parsing and quoted strong ETag', () {
    test('parses only four-segment Pack commit paths', () {
      final digest = 'a' * 64;
      const actor = 'uuid-actor-123-456';
      const path = 'VeneraPlus/Workstation 机/commits/7-';
      final entry = MergeRemoteEntry.tryParsePackCommit(
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
      expect(entry.layout, MergeRemoteLayout.packCommit);
      expect(entry.filename, '$path$digest.json');

      for (final oldPath in [
        'VeneraPlus/Workstation 机/7-$digest.json',
        'VeneraPlus/sync-v4/Workstation 机/commits/7-$digest.json',
        'VeneraPlus/sync-v5/Workstation 机/commits/7-$digest.json',
      ]) {
        expect(
          MergeRemoteEntry.tryParsePackCommit(oldPath, actor: actor),
          isNull,
          reason: oldPath,
        );
      }
    });
    test('strictly rejects traversal, old layouts, and unsafe actors', () {
      final digest = 'a' * 64;
      for (final path in [
        '../../etc/commits/1-$digest.json',
        'VeneraPlus/../Device/commits/1-$digest.json',
        'VeneraPlus/Device/../commits/1-$digest.json',
        'VeneraPlus/Device/commits/uuid-actor-1-$digest.json',
        'VeneraPlus/Device/1-$digest.json',
        'VeneraPlus/sync-v4/Device/commits/1-$digest.json',
        'VeneraPlus/sync-v5/Device/commits/1-$digest.json',
        'sync-v2/Device/commits/1-$digest.json',
        '.venera',
      ]) {
        expect(
          MergeRemoteEntry.tryParsePackCommit(path, actor: 'uuid-actor'),
          isNull,
          reason: path,
        );
      }
      expect(
        MergeRemoteEntry.tryParsePackCommit(
          'VeneraPlus/Device/commits/1-$digest.json',
          actor: '../other',
        ),
        isNull,
      );
    });

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

    test('rejects non-commit filenames', () {
      for (final path in [
        'VeneraPlus/Device/commits/device.json',
        'VeneraPlus/Device/commits/actor-notnum-hash.json',
        'VeneraPlus/Device/commits/1-short.json',
        '',
      ]) {
        expect(
          MergeRemoteEntry.tryParsePackCommit(path, actor: 'actor'),
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
      server.getStatuses['/dav/VeneraPlus/${path.split('/')[1]}/device.json'] =
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
        '/dav/VeneraPlus/Device',
        actor: 'base_owner',
        name: 'Device',
      );
      server.injectOwnership(
        '/dav/VeneraPlus/Device-$suffix',
        actor: 'fallback_owner',
        name: 'Device-$suffix',
      );

      await expectLater(
        remote.upload(createTestBatch(actor: attemptedActor, counter: 1)),
        throwsA(isA<MergeRemoteConflictException>()),
      );
      expect(server.commitPutCount, 0);
      expect(server.objectPutCount, 0);
      expect(server.hasFile('/dav/VeneraPlus/Device/device.json'), isTrue);
      expect(
        server.hasFile('/dav/VeneraPlus/Device-$suffix/device.json'),
        isTrue,
      );
    },
  );

  group('Device-directory ownership and discovery', () {
    test('renamed device keeps its prior Pack commits discoverable', () async {
      final oldDevice = MergeRemote(remote.client, deviceName: 'Old Device');
      final newDevice = MergeRemote(remote.client, deviceName: 'New Device');
      final oldBatch = createTestBatch(actor: 'renamed_actor', counter: 1);
      final newBatch = createTestBatch(actor: 'renamed_actor', counter: 2);

      final oldPath = await oldDevice.upload(oldBatch);
      final newPath = await newDevice.upload(newBatch);

      expect(oldPath, startsWith('VeneraPlus/Old Device/commits/1-'));
      expect(newPath, startsWith('VeneraPlus/New Device/commits/2-'));
      expect(server.hasFile('/dav/VeneraPlus/Old Device/device.json'), isTrue);
      expect(server.hasFile('/dav/VeneraPlus/New Device/device.json'), isTrue);

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
      'ignores retired directories and preserves root Venera backups',
      () async {
        const oldV4Root = 'VeneraPlus/sync-v4';
        const oldV5Root = 'VeneraPlus/sync-v5';
        final oldV4Marker = utf8.encode(
          jsonEncode({'actor': 'legacy_v4', 'name': 'sync-v4'}),
        );
        final oldV5Marker = utf8.encode(
          jsonEncode({'actor': 'legacy_v5', 'name': 'sync-v5'}),
        );
        final oldCommit = utf8.encode('legacy checkpoint bytes');
        final legacyBackup = Uint8List.fromList([1, 2, 3, 4]);
        server.injectOwnership(
          '/dav/$oldV4Root',
          actor: 'legacy_v4',
          name: 'sync-v4',
        );
        server.injectOwnership(
          '/dav/$oldV5Root',
          actor: 'legacy_v5',
          name: 'sync-v5',
        );
        server.injectFile(
          '/dav/$oldV4Root/commits/1-${'a' * 64}.json',
          oldCommit,
        );
        server.injectFile(
          '/dav/$oldV5Root/commits/1-${'b' * 64}.json',
          oldCommit,
        );
        server.injectFile('/dav/.venera', legacyBackup);

        final batch = createTestBatch(actor: 'current_actor', counter: 1);
        await remote.upload(batch);
        final reservedNameRemote = MergeRemote(
          remote.client,
          deviceName: 'sync-v5',
        );
        await reservedNameRemote.upload(
          createTestBatch(actor: 'reserved_name_actor', counter: 1),
        );

        final entries = await remote.list();
        expect(entries.map((entry) => entry.actor).toSet(), {
          'current_actor',
          'reserved_name_actor',
        });
        expect(
          entries.any((entry) => entry.filename.startsWith('$oldV4Root/')),
          isFalse,
        );
        expect(
          entries.any((entry) => entry.filename.startsWith('$oldV5Root/')),
          isFalse,
        );
        expect(
          server._files['/dav/$oldV4Root/device.json'],
          orderedEquals(oldV4Marker),
        );
        expect(
          server._files['/dav/$oldV5Root/device.json'],
          orderedEquals(oldV5Marker),
        );
        expect(
          server._files['/dav/$oldV4Root/commits/1-${'a' * 64}.json'],
          orderedEquals(oldCommit),
        );
        expect(
          server._files['/dav/$oldV5Root/commits/1-${'b' * 64}.json'],
          orderedEquals(oldCommit),
        );
        expect(server._files['/dav/.venera'], orderedEquals(legacyBackup));
        expect(server.hasFile('/dav/VeneraPlus/_sync-v5/device.json'), isTrue);
        expect(
          server.receivedRequests.any(
            (request) =>
                request.contains('/$oldV4Root') ||
                request.contains('/$oldV5Root') ||
                request.contains('/.venera'),
          ),
          isFalse,
        );
      },
    );
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
        expect(recoveredPath, startsWith('VeneraPlus/Device/commits/2-'));

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

          expect(uploadedPath, startsWith('VeneraPlus/My Device 机/commits/1-'));

          final entries = await customRemote.list();
          expect(entries.length, 1);
          expect(
            entries.first.filename,
            startsWith('VeneraPlus/My Device 机/commits/1-'),
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
              (request) => request == 'PROPFIND /dav/VeneraPlus/Device/packs',
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
    'does not reuse publication mappings from the former remote root',
    () async {
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'sync-pack-old-layout-map-',
      );
      try {
        const actor = 'old_layout_cache';
        const deviceName = 'Device';
        final batch = createTestBatch(actor: actor, counter: 1);
        final endpoint = sha256
            .convert(utf8.encode(remote.client.c.options.baseUrl))
            .toString();
        final oldKey = '$endpoint/$actor/$deviceName';
        final packCache = SyncPackCache(
          Directory(
            '${cacheDirectory.path}${Platform.pathSeparator}sync-v5-packs',
          ),
        );
        await packCache.writeManifest(
          oldKey,
          SyncPackSnapshot.fromSnapshot(
            MergeSnapshot.fromBatch(batch),
          ).manifest,
        );

        final newRemote = MergeRemote(
          remote.client,
          deviceName: deviceName,
          cacheDirectory: cacheDirectory,
        );
        final path = await newRemote.upload(batch);

        expect(path, startsWith('VeneraPlus/Device/commits/1-'));
        expect(newRemote.transferStats['cacheHits'], 0);
      } finally {
        await cacheDirectory.delete(recursive: true);
      }
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
        expect(server.objectPutCount, firstManifest.packs.length + 1);
        await cachedRemote.list();
        expect(cachedRemote.deviceNames['object_cache'], 'Device');
        final readBack = await MergeRemote(
          remote.client,
        ).download(parseEntry(secondPath, 'object_cache'));
        expect(readBack.document.toJson(), second.document.toJson());
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
        final missingPath = '/dav/VeneraPlus/Device/packs/$missingPack.pack';
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
          contains('GET /dav/VeneraPlus/Device/packs/$firstPack.pack'),
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
            contains('GET /dav/VeneraPlus/Device/packs/$digest.pack'),
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
    'repairs a same-length corrupt Pack only with strong If-Match and readback',
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
        final packPath = '/dav/VeneraPlus/Device/packs/$digest.pack';
        final correctPack = List<int>.of(server._files[packPath]!);
        final corruptedPack = List<int>.of(correctPack)
          ..[0] = correctPack[0] ^ 1;
        expect(corruptedPack, hasLength(correctPack.length));
        server.tamperFile(packPath, corruptedPack);
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
        final requestStart = server.receivedRequests.length;
        await cachedRemote.upload(second);
        expect(
          server.receivedRequests.skip(requestStart),
          contains('GET $packPath'),
          reason: 'A same-size HEAD response cannot prove Pack contents',
        );

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
    const devicePath = 'VeneraPlus/Oversized Device';
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
      '0-byte incomplete Pack commit does not mask older valid data in listLatest',
      () async {
        final validBatch = createTestBatch(
          actor: 'device-fallback',
          counter: 1,
        );
        await remote.upload(validBatch);

        final fakeDigest = 'b' * 64;
        server.injectFile(
          '/dav/VeneraPlus/Device/commits/2-$fakeDigest.json',
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
            '/dav/VeneraPlus/Device/packs/$corruptDigest.pack';
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
          'Skipping a corrupt remote Pack commit candidate',
        ]);
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
        'foreign candidates do not consume the own-actor compaction limit',
        () async {
          const actor = 'own_filtered_compaction';
          final first = createTestBatch(actor: actor, counter: 1);
          final firstPath = await remote.upload(first);

          final secondDocument = first.document.clone();
          final firstRecords = first.document.materialize();
          secondDocument.captureLocal(actor, firstRecords, {
            ...firstRecords,
            '["folder","second"]': {'name': 'Second'},
          });
          final second = MergeBatch.create(
            actor: actor,
            counter: 2,
            document: secondDocument,
          );
          final secondPath = await remote.upload(second);

          final uploadedDocument = second.document.clone();
          final secondRecords = second.document.materialize();
          uploadedDocument.captureLocal(actor, secondRecords, {
            ...secondRecords,
            '["folder","third"]': {'name': 'Third'},
          });
          final uploaded = MergeBatch.create(
            actor: actor,
            counter: 3,
            document: uploadedDocument,
          );
          await remote.upload(uploaded);

          final foreignEntries = <MergeRemoteEntry>[];
          for (var index = 0; index < 70; index++) {
            final foreignActor = 'foreign_$index';
            final digest = sha256.convert(utf8.encode(foreignActor)).toString();
            foreignEntries.add(
              MergeRemoteEntry.tryParsePackCommit(
                'VeneraPlus/Foreign $index/commits/1-$digest.json',
                actor: foreignActor,
                eTag: '"foreign-$index"',
              )!,
            );
          }
          final entries = await remote.list();
          final ownFirst = entries.singleWhere(
            (entry) => entry.filename == firstPath,
          );
          final ownSecond = entries.singleWhere(
            (entry) => entry.filename == secondPath,
          );
          await remote.compact(uploaded, [
            ...foreignEntries,
            ownFirst,
            ownSecond,
          ]);

          expect(server.hasFile('/dav/$firstPath'), isFalse);
          expect(server.hasFile('/dav/$secondPath'), isTrue);
          expect(server.deleteHeaderLogs, hasLength(1));
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
  Map<String, List<String>>? lastPackPutHeaders;
  final List<Map<String, List<String>>> packPutHeaderLogs = [];
  final List<Map<String, List<String>>> markerPutHeaders = [];
  final List<Map<String, String>> deleteHeaderLogs = [];
  final Map<String, int> getStatuses = {};
  int markerPutCount = 0;
  int commitPutCount = 0;
  int objectPutCount = 0;
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
      if (isMarker) {
        markerPutCount++;
        markerPutHeaders.add(headersMap);
      } else {
        if (isCommit) {
          commitPutCount++;
        } else if (isPack) {
          objectPutCount++;
          packPutHeaderLogs.add(headersMap);
          lastPackPutHeaders = headersMap;
        }
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
