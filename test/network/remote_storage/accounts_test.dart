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
}

const _account = StorageAccount(
  id: 'account',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Drive',
  authorization: {'refresh_token': 'refresh'},
);
