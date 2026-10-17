import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
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
    'replacing QuarkOpen keeps account references and requires the same provider',
    () async {
      const previous = StorageAccount(
        id: 'quark',
        backend: StorageBackend.openlist,
        driver: 'QuarkOpen',
        name: 'Quark',
        authorization: {'refresh_token': 'old'},
      );
      await storage.save(previous);
      appdata.settings['syncRemoteLocation'] = {
        'accountId': previous.id,
        'directory': '/Comics/',
      };
      final replacement = StorageAccount(
        id: previous.id,
        backend: previous.backend,
        driver: 'Quark',
        name: previous.name,
        authorization: const {'cookie': '__pus=session; __puus=secret'},
      );
      await storage.save(replacement);
      expect(storage.accounts.single.toJson(), replacement.toJson());
      expect(appdata.settings['syncRemoteLocation']['accountId'], previous.id);
      await expectLater(storage.save(previous), throwsArgumentError);
      expect(storage.accounts.single.driver, 'Quark');
    },
  );

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
      final syncAccountId = appdata.settings['syncRemoteLocation']['accountId'];
      expect(storage.account(syncAccountId)?.name, 'WebDAV同步');
      final destination = Map<String, dynamic>.from(
        appdata.settings['syncRemoteLocation'],
      );
      appdata.settings['webdav'] = ['https://other.example.com', 'new', 'new'];
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      expect(appdata.settings['syncRemoteLocation'], destination);
    },
  );

  for (final sharedCredentials in [false, true]) {
    test(
      'legacy library and sync get distinct names, shared=$sharedCredentials',
      () async {
        appdata.settings['webdavComicLibrary'] = [
          'https://example.com/dav',
          'user',
          'library-password',
        ];
        appdata.settings['webdavComicLibraryPath'] = '/漫画/';
        appdata.settings['webdav'] = [
          'https://example.com/dav',
          'user',
          sharedCredentials ? 'library-password' : 'sync-password',
        ];

        await RemoteComicLibraryRegistry.migrateLegacyWebDavLibrary();
        await storage.migrateLegacyWebDavLocations();

        final library = storage.libraries.single;
        final sync = RemoteLocation.fromJson(
          appdata.settings['syncRemoteLocation'],
        );
        expect(storage.accounts, hasLength(2));
        expect(storage.account(library.accountId)?.name, 'WebDAV漫画库');
        expect(storage.account(sync.accountId)?.name, 'WebDAV同步');
        expect(sync.accountId, isNot(library.accountId));
        expect(library.directories, ['/漫画/']);
        expect(sync.directory, '/VeneraPlus/');
        final before = storage.accounts.map((a) => a.toJson()).toList();
        await RemoteComicLibraryRegistry.migrateLegacyWebDavLibrary();
        await storage.migrateLegacyWebDavLocations();
        await appdata.loadDataForTesting(dataDir.path);
        expect(storage.accounts.map((a) => a.toJson()).toList(), before);
      },
    );
  }

  test(
    'repairs a missing sync account from retained legacy credentials',
    () async {
      appdata.settings['legacyWebDavAccountNamesMigrated'] = true;
      appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'pass'];
      final location = {
        'accountId': 'lost-sync',
        'directory': '/Existing sync/',
      };
      appdata.settings['syncRemoteLocation'] = location;

      await storage.migrateLegacyWebDavLocations();

      expect(appdata.settings['syncRemoteLocation'], location);
      expect(storage.account('lost-sync')?.authorization, {
        'url': 'https://example.com/dav',
        'user': 'user',
        'password': 'pass',
      });
      expect(storage.account('lost-sync')?.name, 'WebDAV同步');
    },
  );

  test(
    'repairs previously migrated shared account without changing library ids',
    () async {
      const account = StorageAccount(
        id: 'legacy-library-account',
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: 'WebDAV',
        authorization: {
          'url': 'https://example.com/dav',
          'user': 'user',
          'password': 'pass',
        },
        status: StorageAuthorizationStatus.invalid,
        statusMessage: 'Existing authorization error',
      );
      await storage.save(account);
      final library = await storage.saveLibrary(
        RemoteLibrary(
          id: 'library',
          sourceKey: 'webdav_library',
          accountId: account.id,
          directories: ['/Comics/'],
          name: 'Library',
        ),
      );
      appdata.settings['syncRemoteLocation'] = {
        'accountId': account.id,
        'directory': '/Existing sync/',
      };

      await storage.migrateLegacyWebDavLocations();

      final sync = RemoteLocation.fromJson(
        appdata.settings['syncRemoteLocation'],
      );
      final syncAccount = storage.account(sync.accountId)!;
      expect(storage.libraries.single.toJson(), library.toJson());
      expect(storage.account(account.id)?.name, 'WebDAV漫画库');
      expect(syncAccount.name, 'WebDAV同步');
      expect(syncAccount.authorization, account.authorization);
      expect(syncAccount.status, account.status);
      expect(syncAccount.statusMessage, account.statusMessage);
      expect(sync.directory, '/Existing sync/');
      expect(sync.accountId, isNot(account.id));
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      expect(
        appdata.settings['syncRemoteLocation']['accountId'],
        sync.accountId,
      );
    },
  );

  test(
    'repairs separate default names once and preserves user account names',
    () async {
      for (final (id, name) in [('sync', 'WebDAV'), ('custom', 'My WebDAV')]) {
        await storage.save(
          StorageAccount(
            id: id,
            backend: StorageBackend.webdav,
            driver: 'webdav',
            name: name,
            authorization: const {},
          ),
        );
      }
      appdata.settings['syncRemoteLocation'] = {
        'accountId': 'sync',
        'directory': '/sync/',
      };
      await storage.migrateLegacyWebDavLocations();
      expect(storage.account('sync')?.name, 'WebDAV同步');
      expect(storage.account('custom')?.name, 'My WebDAV');

      await storage.save(storage.account('sync')!.copyWith(name: 'WebDAV'));
      await storage.migrateLegacyWebDavLocations();
      expect(storage.account('sync')?.name, 'WebDAV');
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
