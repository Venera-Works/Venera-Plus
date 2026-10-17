import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_runtime/app_runtime.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup preserves saved storage accounts and comic libraries',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-storage-startup-',
      );
      App.dataPath = dataDir.path;
      Log.isMuted = true;
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const openListChannel = MethodChannel('venera/openlist');
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(openListChannel, (call) async {
        nativeCalls++;
        return '{"data":{"ready":true}}';
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        messenger.setMockMethodCallHandler(openListChannel, null);
        App.isInitialized = false;
        Log.isMuted = false;
        await dataDir.delete(recursive: true);
      });

      appdata.settings.replaceAll({
        'deviceId': 'restart-device',
        'proxy': 'direct',
      });
      const account = StorageAccount(
        id: 'restart-account',
        backend: StorageBackend.openlist,
        driver: 'GoogleDrive',
        name: 'Saved account',
        authorization: {'refresh_token': 'saved-refresh-token'},
      );
      final storage = RemoteStorageAccounts.instance;
      await storage.save(account);
      final library = await storage.saveLibrary(
        const RemoteLibrary(
          id: 'restart-library',
          sourceKey: 'remote_library_restart',
          accountId: 'restart-account',
          directories: ['/Comics/'],
          name: 'Saved library',
        ),
      );
      appdata.settings.replaceAll({});

      var supportPathCalls = 0;
      messenger.setMockMethodCallHandler(pathChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory' &&
            ++supportPathCalls > 1) {
          // Stop at cookie initialization, after storage and library migration.
          throw PlatformException(code: 'storage-startup-complete');
        }
        return dataDir.path;
      });
      await expectLater(
        init(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'storage-startup-complete',
          ),
        ),
      );

      expect(storage.accounts.single.toJson(), account.toJson());
      expect(
        nativeCalls,
        0,
        reason: 'Local startup must not connect to OpenList',
      );
      expect(storage.libraries.single.toJson(), library.toJson());
      expect(appdata.settings['proxy'], 'direct');
      final saved =
          jsonDecode(await File('${dataDir.path}/appdata.json').readAsString())
              as Map<String, dynamic>;
      expect(saved['settings'][remoteStorageAccountsSetting], [
        account.toJson(),
      ]);
      expect(saved['settings'][remoteLibrariesSetting], [library.toJson()]);
    },
  );
}
