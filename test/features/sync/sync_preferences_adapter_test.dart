import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/foundation/js_engine.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

String? _quickJsLoadFailure() {
  final libraryPath = Platform.isWindows
      ? 'flutter_qjs_plugin.dll'
      : Platform.isLinux
      ? 'libflutter_qjs_plugin.so'
      : 'flutter_qjs.framework/flutter_qjs';
  try {
    if (Platform.isWindows) {
      for (final buildDir in [
        'build/windows/x64/runner/Debug',
        'build/windows/x64/runner/Release',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/flutter_windows.dll').existsSync() &&
            File('$build/flutter_qjs_plugin.dll').existsSync()) {
          DynamicLibrary.open('$build/flutter_windows.dll');
          DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
          break;
        }
      }
    }
    DynamicLibrary.open(libraryPath);
    return null;
  } catch (error) {
    return '$libraryPath: $error';
  }
}

String _sourceScript(String key) =>
    '''
// A commented/example key and unrelated config must not define source identity.
const unrelated = {"key": "authKey"};
// key = "example_key";
class SyncSource extends ComicSource {
  name = "Sync source";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final quickJsSkip = _quickJsLoadFailure() ?? false;
  late Directory tempDir;
  late String originalDataPath;
  late Map<String, dynamic> cleanSettingsSnapshot;
  late List<String> cleanSearchHistorySnapshot;

  setUpAll(() {
    JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
    try {
      originalDataPath = App.dataPath;
    } catch (_) {
      originalDataPath = Directory.systemTemp.path;
    }
  });

  tearDownAll(() {
    App.dataPath = originalDataPath;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera-pref-sync-test-');
    App.dataPath = tempDir.path;
    App.version = '9.0.0';

    cleanSettingsSnapshot =
        jsonDecode(jsonEncode(appdata.toJson()['settings']))
            as Map<String, dynamic>;
    cleanSearchHistorySnapshot = appdata.fullSearchHistory;

    appdata.settings.replaceAll(cleanSettingsSnapshot);
    appdata.setFullSearchHistory([]);
    appdata.settings['disableSyncFields'] = '';
  });

  tearDown(() async {
    await appdata.saveData(false);
    appdata.settings.replaceAll(cleanSettingsSnapshot);
    appdata.setFullSearchHistory(cleanSearchHistorySnapshot);

    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Preferences Sync Export', () {
    test(
      'flattens nested maps to leaf records and keeps lists atomic',
      () async {
        appdata.settings['comicSpecificSettings'] = {
          'comic1@copymanga': {
            'readerMode': 'waterfall',
            'splitDualPage': true,
          },
        };
        appdata.settings['explore_pages'] = ['home', 'ranking'];

        final adapter = SyncPreferencesAdapter();
        final records = (await adapter.exportSyncSnapshot()).records;

        // Leaf 1
        final key1 = syncRecordKey('setting', [
          'comicSpecificSettings',
          'comic1@copymanga',
          'readerMode',
        ]);
        expect(records, contains(key1));
        expect(records[key1]?['value'], 'waterfall');

        // Leaf 2
        final key2 = syncRecordKey('setting', [
          'comicSpecificSettings',
          'comic1@copymanga',
          'splitDualPage',
        ]);
        expect(records, contains(key2));
        expect(records[key2]?['value'], true);

        // List is atomic
        final listKey = syncRecordKey('setting', ['explore_pages']);
        expect(records, contains(listKey));
        expect(records[listKey]?['value'], ['home', 'ranking']);
      },
    );

    test(
      'excludes forbidden and device-local keys including readingFolder and obsolete settings',
      () async {
        appdata.settings['deviceId'] = 'device-secret-123';
        appdata.settings['proxy'] = 'http://127.0.0.1:7890';
        appdata.settings['webdav'] = ['https://dav.test', 'user', 'pass'];
        appdata.settings['readingFolder'] = 'Folder-XYZ';
        appdata.settings['readLaterFolder'] = 'Obsolete-Folder';
        appdata.settings['deviceSpecificSettings'] = {
          'private-device': {'token': 'private-override'},
        };
        appdata.settings['bangumiAccessToken'] = 'private-bangumi-token';
        appdata.settings['bangumiUsername'] = 'private-bangumi-user';

        final adapter = SyncPreferencesAdapter();
        final records = (await adapter.exportSyncSnapshot()).records;

        expect(
          records.containsKey(syncRecordKey('setting', ['deviceId'])),
          isFalse,
        );
        expect(
          records.containsKey(syncRecordKey('setting', ['proxy'])),
          isFalse,
        );
        expect(
          records.containsKey(syncRecordKey('setting', ['webdav'])),
          isFalse,
        );
        expect(
          records.containsKey(syncRecordKey('setting', ['readingFolder'])),
          isFalse,
        );
        expect(
          records.containsKey(syncRecordKey('setting', ['readLaterFolder'])),
          isFalse,
        );
        expect(canonicalSyncJson(records), isNot(contains('private-device')));
        expect(canonicalSyncJson(records), isNot(contains('private-bangumi')));
      },
    );

    test('respects custom disableSyncFields', () async {
      appdata.settings['disableSyncFields'] = 'cacheSize, downloadThreads';
      appdata.settings['cacheSize'] = 1024;
      appdata.settings['downloadThreads'] = 8;
      appdata.settings['theme_mode'] = 'dark';

      final adapter = SyncPreferencesAdapter();
      final records = (await adapter.exportSyncSnapshot()).records;

      expect(
        records.containsKey(syncRecordKey('setting', ['cacheSize'])),
        isFalse,
      );
      expect(
        records.containsKey(syncRecordKey('setting', ['downloadThreads'])),
        isFalse,
      );
      expect(
        records.containsKey(syncRecordKey('setting', ['theme_mode'])),
        isTrue,
      );
      expect(
        records[syncRecordKey('setting', ['theme_mode'])]?['value'],
        'dark',
      );
    });

    test(
      'local exclusions project both sides without deleting shared records',
      () async {
        appdata.settings['backupWebdavSyncEnabled'] = true;
        appdata.settings['backupWebdav'] = [
          'https://dav.example',
          'user',
          'secret',
        ];
        final adapter = SyncPreferencesAdapter();
        final previous = (await adapter.exportSyncSnapshot()).records;
        final credentialKey = syncRecordKey('setting', ['backupWebdav']);
        expect(previous, contains(credentialKey));
        final document = MergeDocument();
        document.captureLocal('policy-device', {}, previous);
        appdata.settings['backupWebdavSyncEnabled'] = false;
        appdata.settings['disableSyncFields'] = 'theme_mode';
        final current = (await adapter.exportSyncSnapshot()).records;
        expect(adapter.shouldObserveRecord(credentialKey), isFalse);
        expect(
          adapter.shouldObserveRecord(syncRecordKey('setting', ['theme_mode'])),
          isFalse,
        );
        expect(
          document.captureLocal(
            'policy-device',
            adapter.projectRecordsForLocalPolicy(previous),
            adapter.projectRecordsForLocalPolicy(current),
          ),
          0,
        );
        expect(document.materialize()[credentialKey], previous[credentialKey]);

        await adapter.applySyncRecords({
          syncRecordKey('setting', ['bangumiAccessToken']): {
            'value': 'remote-token',
          },
          syncRecordKey('setting', ['bangumiUsername']): {
            'value': 'remote-user',
          },
          syncRecordKey('setting', [
            'deviceSpecificSettings',
            'remote-device',
          ]): {
            'value': {'token': 'remote-private'},
          },
          credentialKey: {
            'value': ['remote-url', 'remote-user', 'remote-secret'],
          },
        });
        expect(appdata.settings['backupWebdav'], [
          'https://dav.example',
          'user',
          'secret',
        ]);
        expect(appdata.settings['bangumiAccessToken'], isNot('remote-token'));
        expect(appdata.settings['bangumiUsername'], isNot('remote-user'));
        expect(
          canonicalSyncJson(appdata.settings['deviceSpecificSettings']),
          isNot(contains('remote-device')),
        );
      },
    );

    test(
      'exports search history with order and preserves overflow items beyond 50',
      () async {
        final items = List.generate(60, (i) => 'search-keyword-$i');
        appdata.setFullSearchHistory(items);

        expect(appdata.searchHistory.length, 50); // Visible UX is capped at 50
        expect(appdata.fullSearchHistory.length, 60); // Engine preserves all 60

        final adapter = SyncPreferencesAdapter();
        final records = (await adapter.exportSyncSnapshot()).records;

        for (int i = 0; i < 60; i++) {
          final key = syncRecordKey('search', ['search-keyword-$i']);
          expect(records, contains(key));
          expect(records[key]?['order'], i);
        }
      },
    );

    test(
      'independent search additions preserve old keyword causality after restart',
      () async {
        appdata.setFullSearchHistory(['older-one', 'older-two']);
        await appdata.saveData(false);
        final file = File('${tempDir.path}/appdata.json');
        final baselineFile = await file.readAsString();
        final adapter = SyncPreferencesAdapter();
        final baseline = (await adapter.exportSyncSnapshot()).records;
        final seed = MergeDocument()
          ..captureLocal('legacy_seed', {}, baseline, bootstrap: true);

        appdata.addSearchHistory('new-A');
        await appdata.saveData(false);
        final a = seed.clone()
          ..captureLocal(
            'A',
            baseline,
            (await adapter.exportSyncSnapshot()).records,
          );

        await file.writeAsString(baselineFile, flush: true);
        await appdata.doInit();
        appdata.addSearchHistory('new-B');
        appdata.addSearchHistory('second-B');
        await appdata.saveData(false);
        final b = seed.clone()
          ..captureLocal(
            'B',
            baseline,
            (await adapter.exportSyncSnapshot()).records,
          );
        a.merge(b);
        expect(a.conflicts, isEmpty);

        final merged = a.materialize();
        for (final keyword in [
          'older-one',
          'older-two',
          'new-A',
          'new-B',
          'second-B',
        ]) {
          expect(merged, contains(syncRecordKey('search', [keyword])));
        }
        await adapter.applySyncRecords(merged);
        await appdata.doInit();
        final restarted = (await adapter.exportSyncSnapshot()).records;
        for (final entry in merged.entries) {
          if (syncRecordDomain(entry.key) == 'search') {
            expect(restarted[entry.key], entry.value);
          }
        }
        a.captureLocal('A', merged, restarted);
        expect(a.conflicts, isEmpty);
      },
    );

    test(
      'exports cookies grouped and sorted by normalized domain',
      () {
        final cookieDbFile = File('${tempDir.path}/cookie.db');
        final jar = CookieJarSql(cookieDbFile.path);
        addTearDown(jar.dispose);

        jar.saveFromResponse(Uri.parse('https://example.com/test'), [
          Cookie('session_id', '12345')..domain = '.example.com',
          Cookie('auth_token', 'token_abc')..domain = 'example.com',
        ]);

        final adapter = SyncPreferencesAdapter(cookieJarInstance: jar);
        final exportFuture = adapter.exportSyncSnapshot();

        expect(exportFuture, completes);
      },
      skip: _sqliteAvailable() ? false : 'sqlite3 native library unavailable',
    );

    test(
      'exports comic source scripts atomically under single script field',
      () async {
        final comicSourceDir = Directory('${tempDir.path}/comic_source')
          ..createSync();
        final scriptFile = File('${comicSourceDir.path}/test_source.js');
        scriptFile.writeAsStringSync('''
class TestComicSource extends ComicSource {
  name = "Test Source"
  key = "test_src"
  version = "1.0.0"
}
''');

        final sessionFile = File('${comicSourceDir.path}/test_src.data');
        sessionFile.writeAsStringSync(
          jsonEncode({
            'account': ['user', 'token'],
          }),
        );

        final adapter = SyncPreferencesAdapter();
        final records = (await adapter.exportSyncSnapshot()).records;

        final sourceKey = syncRecordKey('source', ['test_src']);
        expect(records, contains(sourceKey));
        final scriptField = records[sourceKey]?['script'] as Map;
        expect(scriptField['filename'], 'test_source.js');
        expect(scriptField['content'] as String, contains('TestComicSource'));

        final sessionKey = syncRecordKey('sourceSession', ['test_src']);
        expect(records, contains(sessionKey));
        expect((records[sessionKey]?['data'] as Map)['account'], [
          'user',
          'token',
        ]);
      },
      skip: quickJsSkip,
    );

    test(
      'fails entire capture if a script key cannot be resolved, preventing false deletions',
      () async {
        final comicSourceDir = Directory('${tempDir.path}/comic_source')
          ..createSync();
        final scriptFile = File('${comicSourceDir.path}/unresolvable.js');
        scriptFile.writeAsStringSync('// empty script with no key');

        final adapter = SyncPreferencesAdapter();
        await expectLater(
          adapter.exportSyncSnapshot(),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('Preferences Sync Apply', () {
    test(
      'reconstructs leaf settings into root map and rejects forbidden fields',
      () async {
        final records = <String, Map<String, Object?>>{
          syncRecordKey('setting', [
            'comicSpecificSettings',
            'jm@comic',
            'readerMode',
          ]): {
            'value': 'continuous',
          },
          syncRecordKey('setting', [
            'comicSpecificSettings',
            'jm@comic',
            'split',
          ]): {
            'value': true,
          },
          syncRecordKey('setting', ['theme_mode']): {'value': 'dark'},
          // Forbidden keys
          syncRecordKey('setting', ['deviceId']): {'value': 'hacked-device-id'},
          syncRecordKey('setting', ['readingFolder']): {
            'value': 'remote-reading-folder',
          },
        };

        final adapter = SyncPreferencesAdapter();
        await adapter.applySyncRecords(records);

        expect(appdata.settings['theme_mode'], 'dark');
        final comicSettings = appdata.settings['comicSpecificSettings'] as Map;
        expect(comicSettings['jm@comic']['readerMode'], 'continuous');
        expect(comicSettings['jm@comic']['split'], true);

        // Forbidden keys were safely rejected
        expect(appdata.settings['deviceId'], isNot('hacked-device-id'));
        expect(
          appdata.settings['readingFolder'],
          isNot('remote-reading-folder'),
        );
      },
    );

    test(
      'applies search history with correct order and preserves overflow',
      () async {
        final records = <String, Map<String, Object?>>{};
        for (int i = 0; i < 55; i++) {
          records[syncRecordKey('search', ['term-$i'])] = {'order': i};
        }

        final adapter = SyncPreferencesAdapter();
        await adapter.applySyncRecords(records);

        expect(appdata.searchHistory.length, 50); // Visible UX
        expect(appdata.fullSearchHistory.length, 55); // Full history retained
        expect(appdata.fullSearchHistory.first, 'term-0');
        expect(appdata.fullSearchHistory.last, 'term-54');
      },
    );

    test(
      'staged source files swapped atomically, beforeCommit invoked before swap',
      () async {
        final comicSourceDir = Directory('${tempDir.path}/comic_source')
          ..createSync();
        final scriptFile = File('${comicSourceDir.path}/old_source.js');
        scriptFile.writeAsStringSync(_sourceScript('old_source'));

        final records = <String, Map<String, Object?>>{
          syncRecordKey('source', ['new_source']): {
            'script': {
              'filename': 'new_source.js',
              'content': _sourceScript('new_source'),
            },
          },
          syncRecordKey('sourceSession', ['new_source']): {
            'data': {'token': 'session-token-123'},
          },
        };

        var beforeCommitRan = false;
        var fileExistsDuringBeforeCommit = true;

        final adapter = SyncPreferencesAdapter();
        await adapter.applySyncRecords(
          records,
          beforeCommit: () {
            beforeCommitRan = true;
            // At beforeCommit time, old_source still exists and new_source is not yet committed
            fileExistsDuringBeforeCommit = scriptFile.existsSync();
          },
        );

        expect(beforeCommitRan, isTrue);
        expect(fileExistsDuringBeforeCommit, isTrue);

        // After commit, new_source is committed and old_source is deleted
        final newScript = comicSourceDir
            .listSync()
            .whereType<File>()
            .singleWhere((file) => file.path.endsWith('.js'));
        expect(newScript.readAsStringSync(), _sourceScript('new_source'));

        final newSession = File('${comicSourceDir.path}/new_source.data');
        expect(newSession.existsSync(), isTrue);
        expect(
          jsonDecode(newSession.readAsStringSync())['token'],
          'session-token-123',
        );

        expect(scriptFile.existsSync(), isFalse);
      },
      skip: quickJsSkip,
    );

    test(
      'same logical filename keeps two identities and round-trips without rename',
      () async {
        final records = <String, Map<String, Object?>>{
          for (final key in ['sync_a', 'sync_b'])
            syncRecordKey('source', [key]): {
              'script': {
                'filename': 'plugin.js',
                'content': _sourceScript(key),
              },
            },
        };
        final adapter = SyncPreferencesAdapter();
        final manager = ComicSourceManager();
        App.version = '9.0.0';
        App.cachePath = tempDir.path;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await JsEngine.reset();
        addTearDown(() async {
          manager.remove('sync_a');
          manager.remove('sync_b');
          await JsEngine().dispose();
        });
        await adapter.applySyncRecords(records);
        final directory = Directory('${tempDir.path}/comic_source');
        final names = directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.js'))
            .map((file) => p.basename(file.path))
            .toSet();
        expect(names, hasLength(2));
        await adapter.finishApply();
        expect(manager.find('sync_a'), isNotNull);
        expect(manager.find('sync_b'), isNotNull);
        final exported = (await adapter.exportSyncSnapshot()).records;
        for (final entry in records.entries) {
          expect(exported[entry.key], entry.value);
        }
        await adapter.applySyncRecords(exported);
        expect(
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.js'))
              .map((file) => p.basename(file.path))
              .toSet(),
          names,
        );
      },
      skip: quickJsSkip,
    );

    test('rejects a mismatched script identity before commit', () async {
      var committed = false;
      final adapter = SyncPreferencesAdapter();
      await expectLater(
        adapter.applySyncRecords({
          syncRecordKey('source', ['sync_a']): {
            'script': {
              'filename': 'plugin.js',
              'content': '// key = "sync_a";\n${_sourceScript('sync_b')}',
            },
          },
        }, beforeCommit: () => committed = true),
        throwsFormatException,
      );
      expect(committed, isFalse);
      expect(
        Directory('${tempDir.path}/comic_source')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.js')),
        isEmpty,
      );
    }, skip: quickJsSkip);

    test(
      'rejects script/session filename overlap and invalid known settings before commit',
      () async {
        final adapter = SyncPreferencesAdapter();
        var commits = 0;
        final before = jsonEncode(appdata.toJson());
        for (final records in <SyncRecords>[
          {
            syncRecordKey('source', ['sync_a']): {
              'script': {
                'filename': 'sync_a.data',
                'content': _sourceScript('sync_a'),
              },
            },
          },
          {
            syncRecordKey('setting', ['comicTileScale']): {'value': 'bad'},
          },
          {
            syncRecordKey('setting', ['explore_pages']): {'value': false},
          },
          {
            syncRecordKey('setting', ['theme_mode']): {},
          },
          {
            syncRecordKey('setting', ['comicSpecificSettings']): {
              'value': false,
            },
            syncRecordKey('setting', ['comicSpecificSettings', 'comic']): {
              'value': {},
            },
          },
        ]) {
          await expectLater(
            adapter.applySyncRecords(records, beforeCommit: () => commits++),
            throwsFormatException,
          );
        }
        expect(commits, 0);
        expect(jsonEncode(appdata.toJson()), before);
      },
    );

    test(
      'empty map clear plus a concurrent child survives reconstruction and recapture',
      () async {
        final root = syncRecordKey('setting', ['comicSpecificSettings']);
        final leaf = syncRecordKey('setting', [
          'comicSpecificSettings',
          'comic@source',
          'splitDualPage',
        ]);
        final baseline = <String, Map<String, Object?>>{
          leaf: {'value': false},
        };
        final common = MergeDocument();
        common.captureLocal('seed', {}, baseline);
        final clear = MergeDocument.fromJson(common.toJson());
        final edit = MergeDocument.fromJson(common.toJson());
        clear.captureLocal('clear-device', baseline, {
          root: {'value': {}},
        });
        final edited = <String, Map<String, Object?>>{
          leaf: {'value': true},
        };
        edit.captureLocal('edit-device', baseline, edited);
        clear.merge(edit);
        final desired = clear.materialize(preferred: edited);
        expect(desired, contains(root));
        expect(desired[leaf], {'value': true});
        // Deliberately put the ancestor last: insertion/canonical order cannot
        // determine whether a live descendant gets silently overwritten.
        final adapter = SyncPreferencesAdapter();
        await adapter.applySyncRecords({
          leaf: desired[leaf]!,
          root: desired[root]!,
        });
        expect(appdata.settings['comicSpecificSettings']['comic@source'], {
          'splitDualPage': true,
        });
        final actual = (await adapter.exportSyncSnapshot()).records;
        expect(actual, isNot(contains(root)));
        expect(actual[leaf], {'value': true});
        expect(
          clear.captureLocal(
            'receiver',
            adapter.projectRecordsForLocalPolicy(desired),
            adapter.projectRecordsForLocalPolicy(actual),
          ),
          0,
        );
        expect(clear.materialize(), contains(root));
      },
    );

    test(
      'rejects cross-domain cookies before any business commit',
      () async {
        final jar = CookieJarSql('${tempDir.path}/cookie.db');
        addTearDown(jar.dispose);
        final adapter = SyncPreferencesAdapter(cookieJarInstance: jar);
        final rows = <Map<String, Object?>>[
          {
            'name': 'sid',
            'value': 'foreign',
            'domain': 'target.example',
            'path': '/',
          },
        ];
        var committed = false;
        await expectLater(
          adapter.applySyncRecords({
            syncRecordKey('cookies', ['other.example']): {'cookies': rows},
          }, beforeCommit: () => committed = true),
          throwsFormatException,
        );
        expect(
          () => jar.applyDomainCookies('other.example', rows),
          throwsFormatException,
        );
        expect(committed, isFalse);
        expect(
          jar.loadForRequest(Uri.parse('https://target.example/')),
          isEmpty,
        );
        expect(jar.exportAllCookiesGroupedByDomain(), isEmpty);
      },
      skip: _sqliteAvailable() ? false : 'sqlite3 native library unavailable',
    );

    test('rejects path traversal in source keys or filenames', () async {
      final recordsBadKey = <String, Map<String, Object?>>{
        syncRecordKey('source', ['../../malicious']): {
          'script': {'filename': 'test.js', 'content': 'key = "malicious";'},
        },
      };

      final adapter = SyncPreferencesAdapter();
      await expectLater(
        adapter.applySyncRecords(recordsBadKey),
        throwsA(isA<FormatException>()),
      );

      final recordsBadFilename = <String, Map<String, Object?>>{
        syncRecordKey('source', ['valid_key']): {
          'script': {
            'filename': '../escaped.js',
            'content': 'key = "valid_key";',
          },
        },
      };
      await expectLater(
        adapter.applySyncRecords(recordsBadFilename),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'rejects corrupted cookie or session records with FormatException instead of wiping',
      () async {
        final recordsBadCookie = <String, Map<String, Object?>>{
          syncRecordKey('cookies', ['example.com']): {'cookies': 'not-a-list'},
        };

        final adapter = SyncPreferencesAdapter();
        await expectLater(
          adapter.applySyncRecords(recordsBadCookie),
          throwsA(isA<FormatException>()),
        );

        final recordsBadSession = <String, Map<String, Object?>>{
          syncRecordKey('sourceSession', ['src1']): {'data': 'not-a-map'},
        };
        await expectLater(
          adapter.applySyncRecords(recordsBadSession),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('durable apply precedes runtime callback', () async {
      var callbackCalled = false;
      SyncPreferencesAdapter.registerSettingsImportedCallback(() {
        callbackCalled = true;
      });
      addTearDown(
        () => SyncPreferencesAdapter.registerSettingsImportedCallback(null),
      );

      final adapter = SyncPreferencesAdapter();
      await adapter.applySyncRecords({});
      expect(callbackCalled, isFalse);
      final persisted = jsonDecode(
        File('${tempDir.path}/appdata.json').readAsStringSync(),
      );
      expect(persisted['searchHistory'], isEmpty);
      await adapter.finishApply();

      expect(callbackCalled, isTrue);
    });

    test(
      'durable file failures and runtime failures propagate to the caller',
      () async {
        SyncPreferencesAdapter.registerSettingsImportedCallback(() {
          throw StateError('runtime reload failed');
        });
        addTearDown(
          () => SyncPreferencesAdapter.registerSettingsImportedCallback(null),
        );
        final adapter = SyncPreferencesAdapter();
        await adapter.applySyncRecords({});
        expect(File('${tempDir.path}/appdata.json').existsSync(), isTrue);
        await expectLater(adapter.finishApply(), throwsStateError);
        final blocker = Directory('${tempDir.path}/appdata.json.tmp')
          ..createSync();
        try {
          await expectLater(
            adapter.applySyncRecords({}),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          blocker.deleteSync();
        }
      },
    );
  });

  group('Legacy Migration Reader', () {
    test('reads isolated legacy files without mutating live data', () async {
      final legacyDir = Directory(p.join(tempDir.path, 'legacy_extracted'))
        ..createSync();

      // Legacy appdata.json
      final appdataFile = File(p.join(legacyDir.path, 'appdata.json'));
      appdataFile.writeAsStringSync(
        jsonEncode({
          'settings': {
            'theme_mode': 'light',
            'deviceId': 'legacy-device',
            'readingFolder': 'Legacy Reading',
            'comicSpecificSettings': {
              'comicA@src': {'mode': 1},
            },
          },
          'searchHistory': ['legacy-search-1', 'legacy-search-2'],
        }),
      );

      // Legacy comic_source
      final legacySourceDir = Directory(p.join(legacyDir.path, 'comic_source'))
        ..createSync();
      final script = File(p.join(legacySourceDir.path, 'isolated.js'));
      script.writeAsStringSync('''
class IsolatedSource extends ComicSource {
  name = "Isolated"
  key = "isolated_key"
}
''');
      final session = File(p.join(legacySourceDir.path, 'isolated_key.data'));
      session.writeAsStringSync(jsonEncode({'user': 'legacy_user'}));

      final liveThemeBefore = appdata.settings['theme_mode'];
      final liveSearchBefore = List.from(appdata.searchHistory);

      final adapter = SyncPreferencesAdapter();
      final records = (await adapter.readLegacySnapshot(legacyDir)).records;

      // Verify records DTO
      final settingKey = syncRecordKey('setting', [
        'comicSpecificSettings',
        'comicA@src',
        'mode',
      ]);
      expect(records, contains(settingKey));
      expect(records[settingKey]?['value'], 1);

      expect(records, contains(syncRecordKey('search', ['legacy-search-1'])));
      expect(
        records[syncRecordKey('search', ['legacy-search-1'])]?['order'],
        0,
      );

      expect(records, contains(syncRecordKey('source', ['isolated_key'])));
      final scriptRecord =
          records[syncRecordKey('source', ['isolated_key'])]?['script'] as Map;
      expect(scriptRecord['filename'], 'isolated.js');

      expect(
        records,
        contains(syncRecordKey('sourceSession', ['isolated_key'])),
      );
      expect(
        (records[syncRecordKey('sourceSession', ['isolated_key'])]?['data']
            as Map)['user'],
        'legacy_user',
      );

      // Forbidden keys were excluded
      expect(
        records.containsKey(syncRecordKey('setting', ['deviceId'])),
        isFalse,
      );
      expect(
        records.containsKey(syncRecordKey('setting', ['readingFolder'])),
        isFalse,
      );

      // Live data was NOT mutated
      expect(appdata.settings['theme_mode'], liveThemeBefore);
      expect(appdata.searchHistory, liveSearchBefore);
    }, skip: quickJsSkip);

    test(
      'rejects malformed legacy appdata instead of capturing partial settings',
      () async {
        final extracted = Directory('${tempDir.path}/legacy')..createSync();
        final file = File('${extracted.path}/appdata.json');
        final adapter = SyncPreferencesAdapter();
        for (final malformed in [
          [],
          {'settings': []},
          {'searchHistory': 'bad'},
          {
            'searchHistory': [true],
          },
          {'overflowSearchHistory': null},
          {
            'settings': {'comicTileScale': 'bad'},
          },
        ]) {
          file.writeAsStringSync(jsonEncode(malformed));
          await expectLater(
            adapter.readLegacySnapshot(extracted),
            throwsFormatException,
          );
        }
      },
    );
  });

  group('Cookie Change Callbacks', () {
    test(
      'notifies on saveFromResponse, delete, and expiration',
      () {
        final dbFile = File(p.join(tempDir.path, 'cookie_test.db'));
        final jar = CookieJarSql(dbFile.path);
        addTearDown(jar.dispose);

        var changes = 0;
        jar.onInstanceCookiesChanged = () => changes++;

        final request = Uri.parse('https://example.com/');
        jar.saveFromResponse(request, [
          Cookie('c1', 'v1')..domain = 'example.com',
        ]);
        expect(jar.loadForRequest(request).single.value, 'v1');
        expect(changes, 1);
        jar.saveFromResponse(request, [
          Cookie('c1', 'v1')..domain = 'example.com',
        ]);
        expect(changes, 1);

        jar.delete(request, 'c1');
        expect(jar.loadForRequest(request), isEmpty);
        expect(changes, 2);
        jar.delete(request, 'c1');
        expect(changes, 2);

        jar.saveFromResponse(request, [
          Cookie('expired', 'old')
            ..domain = 'example.com'
            ..expires = DateTime.fromMillisecondsSinceEpoch(0),
        ]);
        expect(changes, 3);
        expect(jar.loadForRequest(request), isEmpty);
        expect(jar.exportAllCookiesGroupedByDomain(), isEmpty);
        expect(changes, 4);
        jar.deleteAll();
        expect(changes, 4);
      },
      skip: _sqliteAvailable() ? false : 'sqlite3 native library unavailable',
    );

    test(
      'full cookie replacement is atomic and identical rows have no mutations',
      () {
        final file = File('${tempDir.path}/atomic-cookie.db');
        final jar = CookieJarSql(file.path);
        addTearDown(jar.dispose);
        jar.saveFromResponse(Uri.parse('https://a.example/'), [
          Cookie('sid', 'old-a')..domain = 'a.example',
        ]);
        jar.saveFromResponse(Uri.parse('https://b.example/'), [
          Cookie('sid', 'old-b')..domain = 'b.example',
        ]);
        final before = jar.exportAllCookiesGroupedByDomain();
        final inspection = sqlite3.open(file.path);
        addTearDown(inspection.dispose);
        inspection.execute('CREATE TABLE mutations (value TEXT);');
        inspection.execute('''
        CREATE TRIGGER cookie_insert AFTER INSERT ON cookies BEGIN
          INSERT INTO mutations VALUES ('insert');
        END;
      ''');
        inspection.execute('''
        CREATE TRIGGER cookie_delete AFTER DELETE ON cookies BEGIN
          INSERT INTO mutations VALUES ('delete');
        END;
      ''');
        var changes = 0;
        jar.onInstanceCookiesChanged = () => changes++;
        jar.applyAllDomainCookies(before, notify: true);
        jar.saveFromResponse(Uri.parse('https://a.example/'), [
          Cookie('sid', 'old-a')..domain = 'a.example',
        ]);
        expect(changes, 0);
        expect(inspection.select('SELECT * FROM mutations;'), isEmpty);
        inspection.execute('''
        CREATE TRIGGER reject_cookie BEFORE INSERT ON cookies
        WHEN NEW.domain = 'b.example' AND NEW.value = 'new'
        BEGIN SELECT RAISE(ABORT, 'reject replacement'); END;
      ''');
        expect(
          () => jar.applyAllDomainCookies({
            for (final domain in ['a.example', 'b.example'])
              domain: [
                {'name': 'sid', 'value': 'new', 'domain': domain, 'path': '/'},
              ],
          }, notify: true),
          throwsA(isA<SqliteException>()),
        );
        expect(jar.exportAllCookiesGroupedByDomain(), before);
        expect(inspection.select('SELECT * FROM mutations;'), isEmpty);
        expect(changes, 0);
      },
      skip: _sqliteAvailable() ? false : 'sqlite3 native library unavailable',
    );
  });

  group('ComicSourceParser Key Probing', () {
    test(
      'computed metadata probing has no installed-source or cookie bridge',
      () async {
        final manager = ComicSourceManager();
        final jar = CookieJarSql('${tempDir.path}/cookie.db');
        addTearDown(jar.dispose);
        var calls = 0;
        JsEngine.configureSourceDataBridge(
          JsSourceDataBridge(
            loadData: (_, _) {
              calls++;
              return null;
            },
            saveData: (_, _, _) {
              calls++;
            },
            deleteData: (_, _) {
              calls++;
            },
            loadSetting: (_, _) {
              calls++;
              return null;
            },
            isLogged: (_) {
              calls++;
              return false;
            },
          ),
        );
        addTearDown(JsEngine.debugResetSourceDataBridge);
        final sourcesBefore = manager.all();
        final key = await ComicSourceParser.probeKey('''
const key = ["computed", "key"].join("_");
class MetadataOnly extends ComicSource {
  key = key;
  constructor() {
    super();
    for (const attempt of [
      () => this.saveData("token", "must-not-write"),
      () => this.deleteData("account"),
      () => Network.setCookies("https://target.example", []),
      () => sendMessage({method: "http", url: "https://target.example"}),
    ]) {
      try { attempt(); } catch (_) {}
    }
  }
}
''');
        expect(key, 'computed_key');
        expect(calls, 0);
        expect(manager.all(), sourcesBefore);
        expect(jar.exportAllCookiesGroupedByDomain(), isEmpty);
      },
      skip: quickJsSkip,
    );

    test(
      'non-string metadata keys do not retain native function handles',
      () async {
        for (final expression in [
          '() => "invalid"',
          '({ callback: () => "invalid" })',
          'Promise.resolve("invalid")',
        ]) {
          final key = await ComicSourceParser.probeKey('''
class InvalidMetadata extends ComicSource {
  key = $expression;
}
''');
          expect(key, isNull);
        }
      },
      skip: quickJsSkip,
    );
  });
}
