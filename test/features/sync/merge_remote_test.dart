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

  MergeRemoteEntry parseEntry(String path, String actor, {String? eTag}) {
    return MergeRemoteEntry.tryParse(path, actor: actor, eTag: eTag)!;
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

  test(
    'real HTTP wire digest roundtrips exact business records without embedded id',
    () async {
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
      expect(sha256.convert(raw).toString(), batch.id);
      final payload = jsonDecode(utf8.decode(raw)) as Map;
      expect(payload.keys.toSet(), {'actor', 'counter', 'document'});
      final downloaded = await remote.download(parseEntry(path, batch.actor));
      expect(downloaded.document.materialize(), records);
      expect(downloaded.toJson(), batch.toJson());
    },
  );

  for (final extraKey in ['id', 'unknown']) {
    test(
      'hash-valid wire payload with $extraKey is rejected, not overwritten',
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
          remote.download(parseEntry(path, batch.actor)),
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
        expect(gammaEntries.map((e) => e.digest).toSet(), {
          batchA.id,
          batchB.id,
        });
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
      expect(server.checkpointPutCount, 0);
      expect(server.hasFile('/dav/VeneraPlus/Device/device.json'), isTrue);
      expect(
        server.hasFile('/dav/VeneraPlus/Device-$suffix/device.json'),
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

      expect(oldPath, startsWith('VeneraPlus/Old Device/1-'));
      expect(newPath, startsWith('VeneraPlus/New Device/2-'));
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
      expect(server.checkpointPutCount, 2);
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
        expect(recoveredPath, startsWith('VeneraPlus/Device/2-'));

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
    test('preserves mixed-case directory and filename over HTTP', () async {
      final customRemote = MergeRemote(
        remote.client,
        deviceName: 'My Device 机',
      );

      final batch = createTestBatch(actor: 'MyDevice-Actor', counter: 1);
      final uploadedPath = await customRemote.upload(batch);

      expect(uploadedPath, startsWith('VeneraPlus/My Device 机/1-'));

      final entries = await customRemote.list();
      expect(entries.length, 1);
      expect(entries.first.filename, startsWith('VeneraPlus/My Device 机/1-'));

      final putRequests = server.receivedRequests
          .where((r) => r.startsWith('PUT '))
          .toList();
      expect(
        putRequests.any((r) => r.contains('/VeneraPlus/My Device 机/1-')),
        isTrue,
      );
    });
  });

  group('Streamed PUT upload and post-upload verification', () {
    test(
      'uploads streamed bytes with content-length, content-type, and If-None-Match',
      () async {
        final batch = createTestBatch(actor: 'device-stream', counter: 3);
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
          batch.serializeBytes().length.toString(),
        );

        // Ping (OPTIONS) must not contain conditional headers
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
          '/dav/VeneraPlus/Device/2-$fakeDigest.json',
          Uint8List(0),
          eTag: '"etag-2"',
        );

        final entries = await remote.listLatest();
        final deviceEntry = entries.firstWhere(
          (e) => e.actor == 'device-fallback',
        );
        expect(deviceEntry.counter, 1);
        expect(deviceEntry.digest, validBatch.id);
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
          () => remote.download(entry),
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

          // Set legitimate quoted strong ETag on batch1, weak ETag on batch2, strong ETag on batchOther
          server.setFileEtag('/dav/$path1', '"strong-etag-1"');
          server.setFileEtag('/dav/$path2', 'W/"weak-etag-2"');
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
            MergeRemoteEntry.tryParse(
              path1,
              actor: 'owner-actor',
              eTag: '"strong-etag-1"',
            )!,
            MergeRemoteEntry.tryParse(
              path2,
              actor: 'owner-actor',
              eTag: 'W/"weak-etag-2"',
            )!,
            MergeRemoteEntry.tryParse(
              pathOther,
              actor: 'other-actor',
              eTag: '"strong-etag-other"',
            )!,
            // Forged listing identity cannot authorize deleting another owner's file.
            MergeRemoteEntry.tryParse(
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

          // batch2 had weak ETag W/"weak-etag-2" => RETAINED
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
  final List<Map<String, List<String>>> optionsHeaders = [];
  Map<String, List<String>>? lastPutHeaders;
  Map<String, List<String>>? lastCheckpointPutHeaders;
  final List<Map<String, List<String>>> markerPutHeaders = [];
  final List<Map<String, String>> deleteHeaderLogs = [];
  final Map<String, int> getStatuses = {};
  int markerPutCount = 0;
  int checkpointPutCount = 0;

  String? _redirectFrom;
  String? _redirectTo;
  bool _omitRedirectEtag = false;
  bool truncateNextPut = false;

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

  String _canonicalPath(String path) {
    final decoded = Uri.decodeFull(path);
    if (decoded.length > 1 && decoded.endsWith('/')) {
      return decoded.substring(0, decoded.length - 1);
    }
    return decoded;
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
    final path = _canonicalPath(request.uri.path);
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
      final content = _files[path];
      if (content == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      final etag = _etags[path];
      if (etag != null) request.response.headers.set('etag', etag);
      request.response.headers.contentLength = content.length;
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

    if (request.method == 'PUT') {
      final headersMap = <String, List<String>>{};
      request.headers.forEach((name, values) {
        headersMap[name.toLowerCase()] = values;
      });
      lastPutHeaders = headersMap;
      final isMarker = path.endsWith('/device.json');
      if (isMarker) {
        markerPutCount++;
        markerPutHeaders.add(headersMap);
      } else {
        checkpointPutCount++;
        lastCheckpointPutHeaders = headersMap;
      }

      final ifNoneMatch = request.headers.value('if-none-match');
      if (ifNoneMatch == '*' && _files.containsKey(path)) {
        request.response.statusCode = HttpStatus.preconditionFailed;
        await request.response.close();
        return;
      }

      final ifMatch = request.headers.value('if-match');
      if (ifMatch != null) {
        final currentEtag = _etags[path];
        if (currentEtag != null && ifMatch != currentEtag) {
          request.response.statusCode = HttpStatus.preconditionFailed;
          await request.response.close();
          return;
        }
      }

      _addDirectoryTree(_parentPath(path));
      if (truncateNextPut && !isMarker) {
        truncateNextPut = false;
        _files[path] = body.sublist(0, math.min(10, body.length));
      } else {
        _files[path] = body;
      }
      _etags[path] = '"etag-${sha256.convert(_files[path]!)}"';
      request.response.statusCode = HttpStatus.created;
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
