import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

LocalComic _comic(String title) => LocalComic(
  id: title,
  title: title,
  subtitle: '',
  tags: const [],
  directory: title,
  chapters: null,
  cover: 'cover.png',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime(2026),
);

class _Ops implements ComicBackupWebDavOps {
  final remote = <String, List<int>>{};
  int uploads = 0, downloads = 0;
  bool loseAcknowledgement = true;
  @override
  Future<void> test(BackupConfig config) async {}
  @override
  Future<List<BackupFile>> list(BackupConfig config) async => [
    for (final path in remote.keys)
      BackupFile(
        name: path.split('/').last,
        size: remote[path]!.length,
        modified: DateTime(2026),
      ),
  ];
  @override
  Future<bool> exists(BackupConfig config, String path) async =>
      remote.containsKey(path);
  @override
  Future<void> ensureDirectory(BackupConfig config) async {}
  @override
  Future<void> uploadFile(
    BackupConfig config,
    String local,
    String path,
  ) async {
    uploads++;
    remote[path] = await File(local).readAsBytes();
    if (loseAcknowledgement) {
      loseAcknowledgement = false;
      throw const SocketException('response lost');
    }
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String path,
    String local,
  ) async {
    downloads++;
    await File(local).writeAsBytes(remote[path]!);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String path) async =>
      remote.remove(path);
}

void main() {
  late Directory root;
  late _Ops operations;
  setUp(() {
    root = Directory.systemTemp.createTempSync('archive-batch-');
    App.cachePath = App.dataPath = root.path;
    appdata.settings['backupWebdav'] = [
      'https://example.invalid/dav',
      'user',
      'secret-password',
    ];
    appdata.settings['backupWebdavPath'] = '/archive/';
    appdata.settings['backupRemoteLocation'] = null;
    operations = _Ops();
    ComicBackupManager.ops = operations;
    ComicBackupManager.exportComic = (comic, path) =>
        File(path).writeAsString(comic.title).then<void>((_) {});
  });
  tearDown(() {
    ComicBackupManager.resetOps();
    ComicBackupManager.exportComic = null;
    ComicBackupManager.importComic = null;
    ComicBackupManager.registerImportedComic = null;
    root.deleteSync(recursive: true);
  });

  test(
    'lost upload acknowledgement is verified on retry without replaying successes',
    () async {
      final batch = ComicBackupManager.createBackupBatch([
        _comic('One'),
        _comic('Two'),
      ]);
      addTearDown(batch.dispose);
      await batch.run();
      expect(batch.items.map((item) => item.state), [
        ArchiveItemState.failed,
        ArchiveItemState.success,
      ]);
      expect(operations.uploads, 2);
      await batch.run(retryFailed: true);
      expect(batch.count(ArchiveItemState.success), 2);
      expect(operations.uploads, 2);
      expect(operations.downloads, 1);
    },
  );

  test(
    'a same-name conflict is preserved when the retry digest differs',
    () async {
      final batch = ComicBackupManager.createBackupBatch([_comic('One')]);
      addTearDown(batch.dispose);
      await batch.run();
      final path = operations.remote.keys.single;
      operations.remote[path] = [9, 8, 7];
      await batch.run(retryFailed: true);
      expect(batch.items.single.state, ArchiveItemState.failed);
      expect(operations.remote[path], [9, 8, 7]);
      expect(operations.uploads, 1);
    },
  );

  test(
    'an uncertain registration cannot be repeated by retrying the batch',
    () async {
      final file = BackupFile(
        name: 'book.cbz',
        size: 1,
        modified: DateTime(2026),
      );
      operations.remote['/archive/book.cbz'] = [1];
      var registrations = 0;
      ComicBackupManager.importComic = (_) async => _comic('Imported');
      ComicBackupManager.registerImportedComic = (_) async {
        registrations++;
        throw StateError('acknowledgement lost');
      };
      final batch = ComicBackupManager.createRestoreBatch([file]);
      addTearDown(batch.dispose);
      await batch.run();
      expect(batch.items.single.canRetry, isFalse);
      await batch.run(retryFailed: true);
      expect(registrations, 1);
    },
  );

  testWidgets('result dialog stays open and retries only the failed item', (
    tester,
  ) async {
    final calls = [0, 0];
    final batch = ComicArchiveBatch(
      items: [
        ArchiveItem(title: 'One', fileName: 'one.cbz'),
        ArchiveItem(title: 'Two', fileName: 'two.cbz'),
      ],
      errorText: (error) => error.toString(),
      action: (index, retry, cancelled) async {
        calls[index]++;
        if (index == 0 && !retry) throw StateError('temporary failure');
        return ArchiveItemState.success;
      },
    );
    addTearDown(batch.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicArchiveTransferDialog(title: 'Archive', batch: batch),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry this item'), findsOneWidget);
    expect(find.textContaining('temporary failure'), findsOneWidget);
    await tester.tap(find.text('Retry this item'));
    await tester.pumpAndSettle();
    expect(calls, [2, 1]);
    expect(find.text('Retry this item'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
