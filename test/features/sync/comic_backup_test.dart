import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  setUp(() {
    appdata.settings['backupWebdav'] = [];
    appdata.settings['backupWebdavPath'] = '/venera_backup/';
    appdata.settings['backupWebdavSyncEnabled'] = false;
    appdata.settings['backupRemoteLocation'] = null;
    appdata.settings[remoteStorageAccountsSetting] = const [];
    App.dataPath = Directory.systemTemp.createTempSync('venera_data').path;
    App.cachePath = Directory.systemTemp.createTempSync('venera_cache').path;
    ComicBackupManager.exportComic = null;
    ComicBackupManager.importComic = null;
    ComicBackupManager.registerImportedComic = null;
    ComicBackupManager.ops = _FakeBackupOps();
  });

  tearDown(() {
    ComicBackupManager.exportComic = null;
    ComicBackupManager.importComic = null;
    ComicBackupManager.registerImportedComic = null;
    ComicBackupManager.resetOps();
  });

  group('BackupConfig', () {
    test('is invalid when WebDAV archive config is empty', () {
      final config = BackupConfig.fromSettings();

      expect(config.isValid, isFalse);
      expect(config.remotePath, '/venera_backup/');
    });

    test('normalizes remote path with leading and trailing slash', () {
      appdata.settings['backupWebdav'] = [
        'https://example.com/dav',
        'u',
        ' p ',
      ];
      appdata.settings['backupWebdavPath'] = 'archive';

      final config = BackupConfig.fromSettings();

      expect(config.isValid, isTrue);
      expect(config.pass, 'p');
      expect(config.remotePath, '/archive/');
      expect(config.remoteFilePath('A.cbz'), '/archive/A.cbz');
    });
  });

  group('archive WebDAV config sync setting', () {
    test('exports only accounts used by libraries and opted-in backup', () {
      final accounts = [
        {'id': 'library'},
        {'id': 'backup'},
        {'id': 'sync-only'},
      ];
      final result = filterRemoteStorageAccountsForSync(accounts, {
        'remoteLibraries': [
          {'accountId': 'library'},
        ],
        'backupWebdavSyncEnabled': true,
        'backupRemoteLocation': {'accountId': 'backup'},
      });
      expect(result.map((item) => (item as Map)['id']), ['library', 'backup']);
    });

    test('does not sync archive WebDAV config when disabled', () async {
      appdata.settings['backupWebdavSyncEnabled'] = false;
      appdata.settings['backupWebdav'] = [
        'https://local.example/dav',
        'local',
        'pass',
      ];
      appdata.settings['backupWebdavPath'] = '/local/';

      await appdata.syncData({
        'settings': {
          'backupWebdavSyncEnabled': true,
          'backupWebdav': ['https://remote.example/dav', 'remote', 'pass'],
          'backupWebdavPath': '/remote/',
        },
        'searchHistory': [],
      });

      // The opt-in is device-local, so a remote profile cannot enable
      // credential synchronization on this device.
      expect(appdata.settings['backupWebdavSyncEnabled'], isFalse);
      expect(appdata.settings['backupWebdav'], [
        'https://local.example/dav',
        'local',
        'pass',
      ]);
      expect(appdata.settings['backupWebdavPath'], '/local/');
    });

    test('syncs archive WebDAV config when enabled locally', () async {
      appdata.settings['backupWebdavSyncEnabled'] = true;
      appdata.settings['backupWebdav'] = [
        'https://local.example/dav',
        'local',
        'pass',
      ];
      appdata.settings['backupWebdavPath'] = '/local/';

      await appdata.syncData({
        'settings': {
          'backupWebdavSyncEnabled': true,
          'backupWebdav': ['https://remote.example/dav', 'remote', 'pass'],
          'backupWebdavPath': '/remote/',
        },
        'searchHistory': [],
      });

      expect(appdata.settings['backupWebdavSyncEnabled'], isTrue);
      expect(appdata.settings['backupWebdav'], [
        'https://remote.example/dav',
        'remote',
        'pass',
      ]);
      expect(appdata.settings['backupWebdavPath'], '/remote/');
    });
  });

  group('ComicBackupManager.listBackups', () {
    test('does not delete a file listed for an old backup target', () async {
      appdata.settings['backupWebdav'] = ['https://one.example/dav', 'u', 'p'];
      final fake = _FakeBackupOps();
      ComicBackupManager.ops = fake;
      final listed = await ComicBackupManager.listBackups();
      final file = BackupFile(
        name: 'old.cbz',
        size: 1,
        modified: DateTime(2024),
        targetIdentity: 'https://one.example/dav|u|/venera_backup/',
      );
      appdata.settings['backupWebdav'] = ['https://two.example/dav', 'u', 'p'];
      final result = await ComicBackupManager.deleteBackup(file);
      expect(listed.success, isTrue);
      expect(result.error, isTrue);
      expect(fake.deletedRemotePaths, isEmpty);
    });

    test('lists only cbz files sorted by modified time desc', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = 'archive';
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 2, 1);
      ComicBackupManager.ops = _FakeBackupOps(
        listResult: [
          BackupFile(name: 'not-a-comic.txt', size: 10, modified: newer),
          BackupFile(name: 'old.cbz', size: 20, modified: older),
          BackupFile(name: 'new.CBZ', size: 30, modified: newer),
        ],
      );

      final result = await ComicBackupManager.listBackups();

      expect(result.success, isTrue);
      expect(result.data.map((e) => e.name), ['new.CBZ', 'old.cbz']);
      expect(
        (ComicBackupManager.ops as _FakeBackupOps).listedPath,
        '/archive/',
      );
    });

    test('refuses restore and delete from a stale cloud backup list', () async {
      final rpc = _CloudBackupRpc()
        ..files.add(_CloudFile('/old/old.cbz', DateTime(2024)));
      _configureCloudBackup(rpc, directory: '/old/');
      final listed = await ComicBackupManager.listBackups();
      appdata.settings['backupRemoteLocation'] = const RemoteLocation(
        accountId: _cloudAccountId,
        directory: '/new/',
      ).toJson();
      var imported = false;
      ComicBackupManager.importComic = (_) async {
        imported = true;
        return _comic('unexpected');
      };

      final restored = await ComicBackupManager.restore(listed.data);
      final deleted = await ComicBackupManager.deleteBackup(listed.data.single);

      expect(listed.success, isTrue);
      expect(restored.failed, 1);
      expect(deleted.error, isTrue);
      expect(rpc.downloaded, isEmpty);
      expect(rpc.deleted, isEmpty);
      expect(imported, isFalse);
    });

    test('tests connection through configured WebDAV path', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = 'archive';
      ComicBackupManager.ops = _FakeBackupOps();

      final result = await ComicBackupManager.testConnection(
        BackupConfig.fromSettings(),
      );

      expect(result.success, isTrue);
      expect(
        (ComicBackupManager.ops as _FakeBackupOps).testedPath,
        '/archive/',
      );
    });
  });

  group('ComicBackupManager.backup', () {
    test(
      'counts success and skipped files and deletes temporary exports',
      () async {
        appdata.settings['backupWebdav'] = [
          'https://example.com/dav',
          'u',
          'p',
        ];
        final uploadedPaths = <String>[];
        final dupComic = _comic('Dup');
        final freshComic = _comic('Fresh');
        final dupFileName = ComicBackupManager.backupFileName(dupComic);
        final fakeOps = _FakeBackupOps(
          listResult: [
            BackupFile(name: dupFileName, size: 0, modified: DateTime(2024)),
          ],
        );
        ComicBackupManager.ops = fakeOps;
        ComicBackupManager.exportComic = (comic, path) async {
          File(path).writeAsStringSync(comic.title);
        };

        final result = await ComicBackupManager.backup([
          dupComic,
          freshComic,
        ], onProgress: (_, _, _) {});
        uploadedPaths.addAll(fakeOps.uploadedRemotePaths);

        expect(result.success, 1);
        expect(result.skipped, 1);
        expect(result.failed, 0);
        expect(uploadedPaths, hasLength(1));
        expect(uploadedPaths.single, startsWith('/venera_backup/Fresh_'));
        expect(uploadedPaths.single, endsWith('.cbz'));
        expect(Directory(App.cachePath).listSync().whereType<File>(), isEmpty);
      },
    );

    test('stops before next comic when cancelled', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      var exportCount = 0;
      var uploadCount = 0;
      ComicBackupManager.ops = _FakeBackupOps(onUpload: () => uploadCount++);
      ComicBackupManager.exportComic = (comic, path) async {
        exportCount++;
        File(path).writeAsStringSync(comic.title);
      };

      final result = await ComicBackupManager.backup([
        _comic('One'),
        _comic('Two'),
      ], isCancelled: () => uploadCount > 0);

      expect(result.success, 1);
      expect(result.skipped, 0);
      expect(result.failed, 0);
      expect(exportCount, 1);
    });

    test(
      'cancels an active cloud upload and does not upload the next comic',
      () async {
        final rpc = _CloudBackupRpc();
        _configureCloudBackup(rpc);
        ComicBackupManager.exportComic = (comic, path) async {
          await File(path).writeAsString(comic.title);
        };

        final backup = ComicBackupManager.backup([
          _comic('One'),
          _comic('Two'),
        ]);
        await rpc.uploadStarted.future;
        await ComicBackupManager.cancelActiveTasks();
        final result = await backup;

        expect(rpc.cancelled, isNotEmpty);
        expect(rpc.uploaded, hasLength(1));
        expect(result.success, 0);
      },
    );

    test(
      'does not upload after cancellation while CBZ export is pending',
      () async {
        final rpc = _CloudBackupRpc();
        _configureCloudBackup(rpc);
        final exportStarted = Completer<void>();
        final exportGate = Completer<void>();
        ComicBackupManager.exportComic = (comic, path) async {
          exportStarted.complete();
          await exportGate.future;
          await File(path).writeAsString(comic.title);
        };

        final backup = ComicBackupManager.backup([
          _comic('One'),
          _comic('Two'),
        ]);
        await exportStarted.future;
        await ComicBackupManager.cancelActiveTasks();
        exportGate.complete();
        final result = await backup;

        expect(rpc.uploaded, isEmpty);
        expect(result.success, 0);
      },
    );
  });

  group('ComicBackupManager.restore', () {
    test('downloads and imports selected backups', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      final importedPaths = <String>[];
      final registeredComics = <LocalComic>[];
      final fakeOps = _FakeBackupOps();
      ComicBackupManager.ops = fakeOps;
      ComicBackupManager.importComic = (path) async {
        importedPaths.add(path);
        return _comic('Imported');
      };
      ComicBackupManager.registerImportedComic = (comic) async {
        registeredComics.add(comic);
      };

      final result = await ComicBackupManager.restore([
        BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
      ]);

      expect(result.success, 1);
      expect(result.failed, 0);
      expect(fakeOps.downloadedRemotePaths, ['/venera_backup/A.cbz']);
      expect(importedPaths.single, endsWith('A.cbz'));
      expect(registeredComics.single.title, 'Imported');
      expect(File(importedPaths.single).existsSync(), isFalse);
    });

    test('deletes a backup file through WebDAV', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      final fakeOps = _FakeBackupOps();
      ComicBackupManager.ops = fakeOps;

      final result = await ComicBackupManager.deleteBackup(
        BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
      );

      expect(result.success, isTrue);
      expect(fakeOps.deletedRemotePaths, ['/venera_backup/A.cbz']);
    });
  });
}

LocalComic _comic(String title) {
  return LocalComic(
    id: title.toLowerCase(),
    title: title,
    subtitle: '',
    tags: const [],
    directory: title,
    chapters: null,
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: const [],
    createdAt: DateTime(2024),
  );
}

const _cloudAccountId = 'backup-cloud';

void _configureCloudBackup(
  _CloudBackupRpc rpc, {
  String directory = '/backup/',
}) {
  RemoteStorageAccounts.instance.configureOpenList(rpc);
  appdata.settings[remoteStorageAccountsSetting] = const [
    {
      'id': _cloudAccountId,
      'backend': 'openlist',
      'driver': 'GoogleDrive',
      'name': 'Backup cloud',
      'authorization': <String, dynamic>{},
    },
  ];
  appdata.settings['backupRemoteLocation'] = RemoteLocation(
    accountId: _cloudAccountId,
    directory: directory,
  ).toJson();
}

class _CloudFile {
  const _CloudFile(this.path, this.modified);

  final String path;
  final DateTime modified;
}

class _CloudBackupRpc implements OpenListRpcClient {
  final files = <_CloudFile>[];
  final uploaded = <String>[];
  final downloaded = <String>[];
  final deleted = <String>[];
  final cancelled = <String>[];
  final uploadStarted = Completer<void>();

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    switch (method) {
      case 'list':
        return {
          'data': {
            'entries': [
              for (final file in files)
                {
                  'name': file.path.split('/').last,
                  'path': file.path,
                  'isDirectory': false,
                  'size': 1,
                  'modifiedAt': file.modified.millisecondsSinceEpoch,
                },
            ],
          },
        };
      case 'upload':
        final path = request['path'] as String;
        uploaded.add(path);
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        return const {'data': {}};
      case 'download':
        downloaded.add(request['path'] as String);
        await File(request['localPath'] as String).writeAsString('backup');
        return const {'data': {}};
      case 'delete':
        deleted.add(request['path'] as String);
        return const {'data': {}};
      case 'taskStatus':
        return const {
          'data': {'done': false},
        };
      case 'cancel':
        final taskId = request['taskId'] as String;
        cancelled.add(taskId);
        return const {'data': {}};
      case 'mkdir':
      case 'releaseTask':
        return const {'data': {}};
      default:
        return const {'data': {}};
    }
  }
}

class _FakeBackupOps implements ComicBackupWebDavOps {
  _FakeBackupOps({this.listResult = const [], this.onUpload});

  final List<BackupFile> listResult;
  final void Function()? onUpload;
  String? listedPath;
  String? testedPath;
  final uploadedRemotePaths = <String>[];
  final downloadedRemotePaths = <String>[];
  final deletedRemotePaths = <String>[];

  @override
  Future<void> test(BackupConfig config) async {
    testedPath = config.remotePath;
  }

  @override
  @override
  Future<List<BackupFile>> list(BackupConfig config) async {
    listedPath = config.remotePath;
    return listResult;
  }

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async => false;

  @override
  Future<void> ensureDirectory(BackupConfig config) async {}

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) async {
    uploadedRemotePaths.add(remotePath);
    onUpload?.call();
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) async {
    downloadedRemotePaths.add(remotePath);
    File(localPath).writeAsStringSync(remotePath);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) async {
    deletedRemotePaths.add(remotePath);
  }
}
