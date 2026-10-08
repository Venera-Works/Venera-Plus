import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/source_files.dart';

void main() {
  group('SourceFileMetadata and PublicationJournal', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('source_files_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('read returns empty map when sidecar does not exist', () async {
      final meta = await SourceFileMetadata.read(tempDir);
      expect(meta, isEmpty);
    });

    test(
      'read never substitutes a backup for a missing or empty primary',
      () async {
        final bakFile = File(
          '${tempDir.path}/${SourceFileMetadata.sidecarFileName}.bak',
        );
        final content = {
          'my_key': {'filename': 'my_key.js', 'revisions': <String, String>{}},
        };
        await bakFile.writeAsString(jsonEncode(content));

        await expectLater(
          SourceFileMetadata.read(tempDir),
          throwsA(isA<FormatException>()),
        );
        final sidecar = File(
          '${tempDir.path}/${SourceFileMetadata.sidecarFileName}',
        );
        await sidecar.writeAsString('');
        await expectLater(
          SourceFileMetadata.read(tempDir),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('read propagates FormatException when sidecar is corrupted', () async {
      final file = File(
        '${tempDir.path}/${SourceFileMetadata.sidecarFileName}',
      );
      await file.writeAsString('corrupted json {{{');
      await expectLater(
        SourceFileMetadata.read(tempDir),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'read throws FormatException on zero-byte sidecar file with no valid backup',
      () async {
        final sidecar = File(
          '${tempDir.path}/${SourceFileMetadata.sidecarFileName}',
        );
        await sidecar.writeAsString('');
        await expectLater(
          SourceFileMetadata.read(tempDir),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'recordValidated keeps logical revisions separate from physical file evidence',
      () async {
        const key = 'test_source';
        const scriptV1 =
            'class TestSource extends ComicSource { key = "test_source"; }';
        const scriptV2 =
            'class TestSource extends ComicSource { key = "test_source"; version = "2"; }';

        await File('${tempDir.path}/test_source.js').writeAsString(scriptV1);
        await SourceFileMetadata.recordValidated(
          tempDir,
          key: key,
          filename: 'test_source.js',
          content: scriptV1,
          originFilename: 'downloaded.js',
          publicationId: 'publication_test',
        );

        var metadata = await SourceFileMetadata.read(tempDir);
        expect(metadata[key]!['filename'], 'downloaded.js');
        final v1Hash = SourceFileMetadata.digest(scriptV1);
        final revisions1 = metadata[key]!['revisions'] as Map<String, String>;
        final files1 = metadata[key]!['files'] as Map<String, String>;
        expect(revisions1[v1Hash], 'downloaded.js');
        expect(files1['test_source.js'], v1Hash);
        expect(metadata[key]!['publicationId'], 'publication_test');

        await File('${tempDir.path}/test_source(0).js').writeAsString(scriptV2);
        await SourceFileMetadata.recordValidated(
          tempDir,
          key: key,
          filename: 'test_source(0).js',
          content: scriptV2,
        );

        metadata = await SourceFileMetadata.read(tempDir);
        expect(metadata[key]!['filename'], 'downloaded.js');
        final v2Hash = SourceFileMetadata.digest(scriptV2);
        final revisions2 = metadata[key]!['revisions'] as Map<String, String>;
        final files2 = metadata[key]!['files'] as Map<String, String>;
        expect(revisions2[v1Hash], 'downloaded.js');
        expect(revisions2[v2Hash], 'downloaded.js');
        expect(files2['test_source.js'], v1Hash);
        expect(files2['test_source(0).js'], v2Hash);
        expect(metadata[key]!['publicationId'], 'publication_test');

        final backup =
            jsonDecode(
                  await File(
                    '${tempDir.path}/${SourceFileMetadata.sidecarFileName}.bak',
                  ).readAsString(),
                )
                as Map;
        expect(backup[key]['publicationId'], 'publication_test');
      },
    );

    test(
      'recordValidated propagates FormatException and does not reset sidecar on corruption',
      () async {
        final file = File(
          '${tempDir.path}/${SourceFileMetadata.sidecarFileName}',
        );
        await file.writeAsString('corrupted content');

        await File('${tempDir.path}/new_key.js').writeAsString(
          'class NewKey extends ComicSource { key = "new_key"; }',
        );
        await expectLater(
          SourceFileMetadata.recordValidated(
            tempDir,
            key: 'new_key',
            filename: 'new_key.js',
            content: 'class NewKey extends ComicSource { key = "new_key"; }',
          ),
          throwsA(isA<FormatException>()),
        );

        // Verify corrupted content was preserved and not quietly wiped to {}
        expect(await file.readAsString(), 'corrupted content');
      },
    );

    test('recordValidated rejects path traversal filenames', () async {
      for (final badName in [
        '../escaped.js',
        'sub/a.js',
        'sub\\b.js',
        '.',
        '..',
      ]) {
        await expectLater(
          SourceFileMetadata.recordValidated(
            tempDir,
            key: 'test_key',
            filename: badName,
            content: 'script',
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test(
      'atomicReplace preserves the target until a same-directory stage commits',
      () async {
        final target = File('${tempDir.path}/target.js')
          ..writeAsStringSync('old bytes');
        final staged = File('${tempDir.path}/.target.js.stage')
          ..writeAsStringSync('new bytes');
        await SourceFileMetadata.atomicReplace(staged, target);
        expect(target.readAsStringSync(), 'new bytes');
        expect(staged.existsSync(), isFalse);
      },
    );

    test(
      'SourcePublicationJournal records, updates stage, and clears journal',
      () async {
        final journal = SourcePublicationJournal(tempDir);
        expect(await journal.read(), isNull);

        final entry = SourcePublicationJournalEntry(
          publicationId: 'pub_1',
          key: 'journal_key',
          targetPath: p.canonicalize('${tempDir.path}/test.js'),
          stagePath: p.canonicalize('${tempDir.path}/test.js.stage'),
          backupPath: p.canonicalize('${tempDir.path}/test.js.bak'),
          originalDigest: 'a' * 64,
          newDigest: 'b' * 64,
          originalSessionDigest: 'c' * 64,
          newSessionDigest: 'd' * 64,
          hadOriginalSession: true,
          sessionWriteExpected: true,
          originalPages: {
            'categories': ['old'],
            'explore_pages': null,
          },
          newPages: {
            'categories': ['new'],
          },
          hadOriginalOrigin: true,
          originalOrigin: {
            'catalog': {'enabled': true},
          },
          originChanges: true,
          newOrigin: {
            'catalog': {'enabled': false},
          },
          stage: SourcePublicationStage.staged,
          timestamp: DateTime.now(),
        );

        await journal.record(entry);
        var loaded = await journal.read();
        expect(loaded, isNotNull);
        expect(loaded!.key, 'journal_key');
        expect(loaded.stage, SourcePublicationStage.staged);
        expect(loaded.newSessionDigest, 'd' * 64);
        expect(loaded.sessionWriteExpected, isTrue);
        expect(
          loaded.originalPages,
          equals({
            'categories': ['old'],
            'explore_pages': null,
          }),
        );
        expect(
          loaded.newPages,
          equals({
            'categories': ['new'],
          }),
        );
        expect(loaded.hadOriginalOrigin, isTrue);
        expect(
          loaded.originalOrigin,
          equals({
            'catalog': {'enabled': true},
          }),
        );
        expect(loaded.originChanges, isTrue);
        expect(
          loaded.newOrigin,
          equals({
            'catalog': {'enabled': false},
          }),
        );

        await journal.updateStage(SourcePublicationStage.renamed);
        loaded = await journal.read();
        expect(loaded!.stage, SourcePublicationStage.renamed);

        await journal.clear();
        expect(await journal.read(), isNull);
      },
    );

    test(
      'SourcePublicationJournal throws FormatException on zero-byte journal file',
      () async {
        final journalFile = File(
          '${tempDir.path}/${SourcePublicationJournal.journalFileName}',
        );
        await journalFile.writeAsString('');
        final journal = SourcePublicationJournal(tempDir);
        await expectLater(journal.read(), throwsA(isA<FormatException>()));
      },
    );

    test(
      'SourcePublicationJournalEntry.fromJson rejects paths outside expected directory and invalid siblings',
      () {
        final target = p.canonicalize('${tempDir.path}/test.js');
        final validJson = {
          'publicationId': 'pub_1',
          'key': 'valid_key',
          'targetPath': target,
          'stagePath': '$target.stage',
          'backupPath': '$target.bak',
          'newDigest': 'b' * 64,
          'stage': 'staged',
          'timestamp': DateTime.now().toIso8601String(),
        };

        expect(
          SourcePublicationJournalEntry.fromJson(validJson, tempDir).key,
          'valid_key',
        );

        final escapingJson = Map<String, Object?>.from(validJson)
          ..['targetPath'] = p.canonicalize(
            '${Directory.systemTemp.path}/escaped.js',
          );
        expect(
          () => SourcePublicationJournalEntry.fromJson(escapingJson, tempDir),
          throwsA(isA<FormatException>()),
        );

        final badStageJson = Map<String, Object?>.from(validJson)
          ..['stagePath'] = p.canonicalize('${tempDir.path}/other.stage');
        expect(
          () => SourcePublicationJournalEntry.fromJson(badStageJson, tempDir),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}
