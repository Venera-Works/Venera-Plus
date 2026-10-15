import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory dataDir;
  late RemoteStorageAccounts storage;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('venera-remote-accounts-');
    App.dataPath = dataDir.path;
    appdata.settings.replaceAll({});
    storage = RemoteStorageAccounts();
  });

  tearDown(() async {
    storage.dispose();
    await dataDir.delete(recursive: true);
  });

  test('saves the first library when no library setting exists', () async {
    appdata.settings[remoteStorageAccountsSetting] = [_account.toJson()];
    expect(appdata.settings[remoteLibrariesSetting], isNull);

    final library = await storage.saveLibrary(
      const RemoteLibrary(
        id: '',
        sourceKey: '',
        accountId: 'account',
        directories: ['/Comics'],
        name: 'Comics',
      ),
    );

    expect(library.id, isNotEmpty);
    expect(library.sourceKey, 'remote_library_${library.id}');
    expect(library.directories, ['/Comics/']);
    expect(storage.libraries.single.toJson(), library.toJson());
    final saved =
        jsonDecode(await File('${dataDir.path}/appdata.json').readAsString())
            as Map<String, dynamic>;
    expect(saved['settings'][remoteLibrariesSetting], [library.toJson()]);
  });

  test('saves the first account when no account setting exists', () async {
    expect(appdata.settings[remoteStorageAccountsSetting], isNull);

    await storage.save(_account);

    expect(storage.accounts.single.toJson(), _account.toJson());
    final saved =
        jsonDecode(await File('${dataDir.path}/appdata.json').readAsString())
            as Map<String, dynamic>;
    expect(saved['settings'][remoteStorageAccountsSetting], [
      _account.toJson(),
    ]);
  });

  test(
    'legacy WebDAV locations reuse accounts and preserve remote paths',
    () async {
      const account = StorageAccount(
        id: 'shared-webdav',
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: 'Shared WebDAV',
        authorization: {
          'url': 'https://example.com/dav',
          'user': 'user',
          'password': 'password',
        },
      );
      await storage.save(account);
      for (final key in ['webdav', 'backupWebdav']) {
        appdata.settings[key] = [
          'https://example.com/dav/',
          ' user ',
          'password',
        ];
      }
      appdata.settings['backupWebdavPath'] = '/漫画 100%/CBZ/';
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts.single.toJson(), account.toJson());
      expect(appdata.settings['syncRemoteLocation'], {
        'accountId': account.id,
        'directory': '/VeneraPlus/',
      });
      expect(appdata.settings['backupRemoteLocation'], {
        'accountId': account.id,
        'directory': '/漫画 100%/CBZ/',
      });
      await storage.migrateLegacyWebDavLocations();
      await appdata.loadDataForTesting(dataDir.path);
      expect(storage.accounts.single.toJson(), account.toJson());
      expect(
        appdata.settings['backupRemoteLocation']['directory'],
        '/漫画 100%/CBZ/',
      );
      await storage.remove(account.id);
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, isEmpty);
      expect(appdata.settings['webdav'], isEmpty);
      expect(appdata.settings['backupWebdav'], isEmpty);
    },
  );

  test(
    'legacy migration keeps distinct credentials and explicit destinations',
    () async {
      appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'one'];
      appdata.settings['backupWebdav'] = [
        'https://example.com/dav',
        'user',
        'two',
      ];
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      final destination = Map<String, dynamic>.from(
        appdata.settings['syncRemoteLocation'],
      );
      appdata.settings['webdav'] = ['https://other.example.com', 'new', 'new'];
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      expect(appdata.settings['syncRemoteLocation'], destination);
    },
  );
}

const _account = StorageAccount(
  id: 'account',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Drive',
  authorization: {'refresh_token': 'refresh'},
);
