import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_source/source_repositories.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/request_scope.dart';

const bool _ciRequireQuickJs = bool.fromEnvironment(
  'CI_REQUIRE_QUICKJS',
  defaultValue: false,
);

Map<String, Object?> _sourcePageSnapshot() => {
  for (final key in [
    'explore_pages',
    'categories',
    'favorites',
    'searchSources',
  ])
    key: appdata.settings[key] == null
        ? null
        : List.from(appdata.settings[key]),
};

int _holdNoDeleteHandle(String filePath) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getProcessHeap = kernel32
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      );
  final heapAlloc = kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  final heapFree = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  final createFileW = kernel32
      .lookupFunction<
        IntPtr Function(
          Pointer<Uint16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  final heap = getProcessHeap();
  final units = filePath.codeUnits;
  final memory = heapAlloc(heap, 0, (units.length + 1) * sizeOf<Uint16>());
  if (memory.address == 0) throw StateError('HeapAlloc failed');
  final buffer = memory.cast<Uint16>().asTypedList(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    buffer[i] = units[i];
  }
  buffer[units.length] = 0;
  final handle = createFileW(
    memory.cast<Uint16>(),
    0x80000000,
    0x00000001 | 0x00000002,
    nullptr,
    3,
    0x80,
    0,
  );
  heapFree(heap, 0, memory);
  if (handle == -1 || handle == 0) {
    throw StateError('CreateFileW failed for source target');
  }
  return handle;
}

void _closeHandle(int handle) {
  DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle')(
    handle,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  Object? nativeLoadError;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    nativeAvailable = true;
  } catch (e) {
    nativeAvailable = false;
    nativeLoadError = e;
  }

  group(
    'source runtime transactions',
    () {
      late Directory directory;
      late Map<String, dynamic> settings;
      final manager = ComicSourceManager();
      setUp(() async {
        if (_ciRequireQuickJs && !nativeAvailable) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires QuickJS native library, '
            'but it failed to load: $nativeLoadError',
          );
        }
        directory = Directory.systemTemp.createTempSync(
          'venera-source-transaction-',
        );
        Directory('${directory.path}/comic_source').createSync();
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        App.version = '9.0.0';
        settings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await JsEngine().init();
      });
      tearDown(() async {
        for (final key in ['transaction_a', 'transaction_b']) {
          manager.remove(key);
        }
        await appdata.saveData(false);
        JsEngine().dispose();
        settings.forEach((key, value) => appdata.settings[key] = value);
        Log.isMuted = false;
        directory.deleteSync(recursive: true);
      });

      Future<ComicSource> install(String key) => manager.installScript(
        js: script(key),
        fileName: '$key.js',
        origin: const SourceOrigin(kind: 'file'),
        beforeInstall: () {},
      );

      test(
        'failed parse and failed init preserve installed source and unrelated runtime',
        () async {
          final original = await install('transaction_a');
          final other = await install('transaction_b');
          final oldText = await File(original.filePath).readAsString();
          original.data['token'] = 'keep';
          await original.saveData();
          JsEngine().runCode('ComicSource.sources.transaction_b.marker = 42');
          for (final replacement in [
            'broken JavaScript',
            script(
              original.key,
              version: '2.0.0',
              init:
                  'this.saveData("token", "bad"); throw new Error("init failed");',
            ),
          ]) {
            await expectLater(
              manager.replaceScript(original, replacement, validate: () {}),
              throwsA(anything),
            );
            expect(manager.find(original.key), same(original));
            expect(await File(original.filePath).readAsString(), oldText);
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a.version'),
              '1.0.0',
            );
            expect(
              jsonDecode(
                await File(
                  '${directory.path}/comic_source/${original.key}.data',
                ).readAsString(),
              )['token'],
              'keep',
            );
            expect(manager.find(other.key), same(other));
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_b.marker'),
              42,
            );
          }
          await manager.replaceScript(
            original,
            script(original.key, version: '2.0.0'),
            validate: () {},
          );
          expect(manager.find(original.key)!.version, '2.0.0');
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_b.marker'),
            42,
          );
          expect(
            await File(original.filePath).readAsString(),
            contains('2.0.0'),
          );
        },
      );

      test(
        'committed replacement and session survive publication replay and reload',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'persistent_login';
          await original.saveData();
          final replacement = script(original.key, version: '2.0.0');

          await manager.replaceScript(original, replacement, validate: () {});

          final sourceDir = Directory('${directory.path}/comic_source');
          final committedMetadata = (await SourceFileMetadata.read(
            sourceDir,
          ))[original.key]!;
          expect(committedMetadata['publicationId'], isA<String>());
          expect(await File(original.filePath).readAsString(), replacement);
          await ComicSourceManager.recoverInterruptedPublications(sourceDir);
          await manager.reload();

          final reloaded = manager.find(original.key)!;
          expect(reloaded.version, '2.0.0');
          expect(reloaded.data['token'], 'persistent_login');
          expect(await File(reloaded.filePath).readAsString(), replacement);
        },
      );

      test(
        'publication preserves a session edit made while replacement is staged',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'persistent_login';
          await original.saveData();
          final oldScript = await File(original.filePath).readAsString();
          final sessionFile = File(
            '${directory.path}/comic_source/${original.key}.data',
          );
          final journal = SourcePublicationJournal(
            Directory('${directory.path}/comic_source'),
          );
          var validations = 0;

          await expectLater(
            manager.replaceScript(
              original,
              script(
                original.key,
                version: '2.0.0',
                init: 'this.saveData("token", "candidate_session");',
              ),
              validate: () {
                validations++;
                if (validations == 2) {
                  sessionFile.writeAsStringSync(
                    '{"token":"manual_session_edit"}',
                    flush: true,
                  );
                }
              },
            ),
            throwsA(isA<FileSystemException>()),
          );

          const manualSession = '{"token":"manual_session_edit"}';
          expect(await File(original.filePath).readAsString(), oldScript);
          expect(await sessionFile.readAsString(), manualSession);
          expect(await journal.read(), isNotNull);

          await ComicSourceManager.recoverInterruptedPublications(
            Directory('${directory.path}/comic_source'),
          );

          expect(await File(original.filePath).readAsString(), oldScript);
          expect(await sessionFile.readAsString(), manualSession);
          expect(await journal.read(), isNotNull);
        },
      );

      test(
        'locked target keeps a replayable rollback journal until restart recovery',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'persistent_login';
          await original.saveData();
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final originalScript = await activeFile.readAsString();
          final sessionFile = File('${sourceDir.path}/${original.key}.data');
          final journal = SourcePublicationJournal(sourceDir);
          var validationCount = 0;
          int? lockedTarget;

          try {
            await expectLater(
              manager.replaceScript(
                original,
                script(original.key, version: '2.0.0'),
                validate: () {
                  validationCount++;
                  if (validationCount == 2) {
                    lockedTarget = _holdNoDeleteHandle(activeFile.path);
                    throw StateError(
                      'simulate interruption while target locked',
                    );
                  }
                },
              ),
              throwsA(isA<StateError>()),
            );
          } finally {
            if (lockedTarget != null) _closeHandle(lockedTarget!);
          }

          expect(await activeFile.readAsString(), contains('2.0.0'));
          expect(
            jsonDecode(await sessionFile.readAsString())['token'],
            'persistent_login',
          );
          expect(await journal.read(), isNotNull);

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);
          await manager.reload();

          expect(await activeFile.readAsString(), originalScript);
          expect(manager.find(original.key)!.version, '1.0.0');
          expect(manager.find(original.key)!.data['token'], 'persistent_login');
          expect(await journal.read(), isNull);
        },
        skip: Platform.isWindows ? false : 'Windows replacement lock semantics',
      );
      test('duplicate import preserves the working source', () async {
        final original = await install('transaction_a');
        await expectLater(
          install('transaction_a'),
          throwsA(isA<SourceAlreadyInstalledException>()),
        );
        expect(manager.find(original.key), same(original));
        expect(
          JsEngine().runCode('ComicSource.sources.transaction_a.version'),
          '1.0.0',
        );
      });

      test(
        'failed install init leaves neither a published script nor metadata',
        () async {
          await expectLater(
            manager.installScript(
              js: script(
                'transaction_a',
                init:
                    'this.saveData("token", "uncommitted"); throw new Error("init failed");',
              ),
              fileName: 'transaction_a.js',
              origin: const SourceOrigin(kind: 'file'),
              beforeInstall: () {},
            ),
            throwsA(anything),
          );

          final sourceDir = Directory('${directory.path}/comic_source');
          expect(manager.find('transaction_a'), isNull);
          expect(
            File('${sourceDir.path}/transaction_a.js').existsSync(),
            isFalse,
          );
          expect(await SourceFileMetadata.read(sourceDir), isEmpty);
          expect(
            File('${sourceDir.path}/transaction_a.data').existsSync(),
            isFalse,
          );
        },
      );

      test('reloading persists new search page registration', () async {
        final original = await install('transaction_a');
        final replacement = script(original.key).replaceFirst(
          'comic =',
          'search = {load: async () => ({comics: []})}; comic =',
        );
        await manager.replaceScript(original, replacement, validate: () {});
        final saved = jsonDecode(
          await File('${directory.path}/appdata.json').readAsString(),
        );
        expect(saved['settings']['searchSources'], contains(original.key));
      });

      test(
        'adding a search source preserves all defaults when selection is null',
        () async {
          String searchable(String key) => script(key).replaceFirst(
            'comic =',
            'search = {load: async () => ({comics: []})}; comic =',
          );
          await manager.installScript(
            js: searchable('transaction_a'),
            fileName: 'transaction_a.js',
            origin: const SourceOrigin(kind: 'file'),
            beforeInstall: () {},
          );
          appdata.settings['searchSources'] = null;
          await manager.installScript(
            js: searchable('transaction_b'),
            fileName: 'transaction_b.js',
            origin: const SourceOrigin(kind: 'file'),
            beforeInstall: () {},
          );
          expect(appdata.settings['searchSources'], [
            'transaction_a',
            'transaction_b',
          ]);
        },
      );
      test(
        'ordinary source install appends browse and category pages after existing order',
        () async {
          appdata.settings['explore_pages'] = [
            'manual browse second',
            'manual browse first',
          ];
          appdata.settings['categories'] = [
            'manual category second',
            'manual category first',
          ];

          await manager.installScript(
            js: script('transaction_a').replaceFirst('comic =', '''
              explore = [
                {title: "New Browse One", type: "multiPageComicList", load: async () => ({comics: [], maxPage: 1})},
                {title: "New Browse Two", type: "multiPageComicList", load: async () => ({comics: [], maxPage: 1})}
              ];
              category = {title: "New Categories", parts: []};
              comic ='''),
            fileName: 'transaction_a.js',
            origin: const SourceOrigin(kind: 'file'),
            beforeInstall: () {},
          );

          expect(appdata.settings['explore_pages'], [
            'manual browse second',
            'manual browse first',
            'New Browse One',
            'New Browse Two',
          ]);
          expect(appdata.settings['categories'], [
            'manual category second',
            'manual category first',
            'New Categories',
          ]);
        },
      );

      test(
        'failed staged data write rolls back script, runtime and origin',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'keep';
          await original.saveData();
          final blocker = Directory(
            '${directory.path}/comic_source/${original.key}.data.update',
          )..createSync();
          await expectLater(
            manager.replaceScript(
              original,
              script(
                original.key,
                version: '2.0.0',
                init: 'this.saveData("token", "bad");',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://example.test/test.js',
              ),
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(manager.find(original.key), same(original));
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.version'),
            '1.0.0',
          );
          expect(
            await File(original.filePath).readAsString(),
            contains('1.0.0'),
          );
          expect(
            SourceRepositories.instance.originFor(original.key)!.kind,
            'file',
          );
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/${original.key}.data',
              ).readAsString(),
            )['token'],
            'keep',
          );
          blocker.deleteSync();
          await manager.replaceScript(
            original,
            script(
              original.key,
              version: '2.0.0',
              init: 'this.saveData("token", "new");',
            ),
            validate: () {},
          );
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/${original.key}.data',
              ).readAsString(),
            )['token'],
            'new',
          );
        },
      );

      test(
        'full source reload keeps complete sessions shared with old callbacks',
        () async {
          final original = await install('transaction_a');
          original.data = {
            'account': ['before', 'password'],
            'token': 'before-token',
            'settings': {'mode': 'before'},
            '_localStorage': {'sid': 'before-storage'},
          };
          await original.saveData();
          await manager.reload();
          final replacement = manager.find(original.key)!;
          expect(replacement, isNot(same(original)));
          original.data['account'] = ['new', 'password'];
          original.data['token'] = 'new-token';
          original.data['settings']['mode'] = 'new';
          original.data['_localStorage']['sid'] = 'new-storage';
          await original.saveData();
          expect(replacement.data, same(original.data));
          expect(replacement.data, {
            'account': ['new', 'password'],
            'token': 'new-token',
            'settings': {'mode': 'new'},
            '_localStorage': {'sid': 'new-storage'},
          });
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/${original.key}.data',
              ).readAsString(),
            ),
            replacement.data,
          );
        },
      );

      test(
        'read bridge retries transient errors at most twice and stops on cancellation',
        () async {
          JsEngine().runCode('this.readAttempts = 0;');
          const operation =
              '(() => { this.readAttempts++; throw new Error("connection reset"); })()';
          await expectLater(
            JsEngine().runReadCode(operation),
            throwsA(anything),
          );
          expect(JsEngine().runCode('this.readAttempts'), 3);
          JsEngine().runCode('this.readAttempts = 0;');
          final scope = RequestScope();
          final reading = scope.run(() => JsEngine().runReadCode(operation));
          final cancelled = expectLater(
            reading,
            throwsA(isA<RequestCancelled>()),
          );
          scope.cancel();
          await cancelled;
          expect(JsEngine().runCode('this.readAttempts'), 1);
          scope.dispose();
        },
      );

      test(
        'recoverInterruptedPublications preserves nonempty uncommitted manual edit without overwriting from backup',
        () async {
          final original = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');

          final originalScript = await activeFile.readAsString();
          final originalDigest = SourceFileMetadata.digest(originalScript);
          backupFile.writeAsStringSync(originalScript, flush: true);

          const userEdit = '''
class TestSource extends ComicSource {
  name = "User Custom Edit";
  key = "transaction_a";
  version = "1.0.5";
  minAppVersion = "1.0.0";
  comic = {loadInfo: async () => ({title: "Custom", cover: "", tags: {}}), loadEp: async () => []};
}
''';
          activeFile.writeAsStringSync(userEdit, flush: true);

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_manual_edit',
              key: 'transaction_a',
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              originalDigest: originalDigest,
              newDigest: SourceFileMetadata.digest('some_failed_new_script'),
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: true,
              originalOrigin: const SourceOrigin(kind: 'file').toJson(),
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );
          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), userEdit);
          expect(await journal.read(), isNotNull);
          expect(await backupFile.readAsString(), originalScript);
        },
      );

      test(
        'actual journal replay rolls back uncommitted renamed stage to verified backup',
        () async {
          final original = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');

          final goodScript = await activeFile.readAsString();
          final origDigest = SourceFileMetadata.digest(goodScript);
          backupFile.writeAsStringSync(goodScript, flush: true);

          const uncommittedNew = '''
class TestSource extends ComicSource {
  name = "Uncommitted New";
  key = "transaction_a";
  version = "2.0.0";
  minAppVersion = "1.0.0";
  comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
}
''';
          activeFile.writeAsStringSync(uncommittedNew, flush: true);

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_uncommitted',
              key: 'transaction_a',
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              originalDigest: origDigest,
              newDigest: SourceFileMetadata.digest(uncommittedNew),
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: true,
              originalOrigin: const SourceOrigin(kind: 'file').toJson(),
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), goodScript);
          expect(await journal.read(), isNull);
        },
      );

      test(
        'interrupted swapped-but-staged journal rolls back to verified backup',
        () async {
          final original = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');

          final goodScript = await activeFile.readAsString();
          final origDigest = SourceFileMetadata.digest(goodScript);
          backupFile.writeAsStringSync(goodScript, flush: true);

          const swappedNew = '''
class TestSource extends ComicSource {
  name = "Swapped New";
  key = "transaction_a";
  version = "2.0.0";
  minAppVersion = "1.0.0";
  comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
}
''';
          activeFile.writeAsStringSync(swappedNew, flush: true);

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_staged_swap',
              key: 'transaction_a',
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              originalDigest: origDigest,
              newDigest: SourceFileMetadata.digest(swappedNew),
              stage: SourcePublicationStage.staged,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), goodScript);
          expect(await journal.read(), isNull);
        },
      );

      test(
        'interrupted publication after session commit but before metadata commit restores original session',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'original_secret_token';
          await original.saveData();

          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');
          final sessionFile = File('${sourceDir.path}/${original.key}.data');
          final sessionBackupFile = File(
            '${sourceDir.path}/${original.key}.data.bak',
          );

          final goodScript = await activeFile.readAsString();
          final origDigest = SourceFileMetadata.digest(goodScript);
          backupFile.writeAsStringSync(goodScript, flush: true);

          final origSession = await sessionFile.readAsString();
          final origSessionDigest = SourceFileMetadata.digest(origSession);
          sessionBackupFile.writeAsStringSync(origSession, flush: true);

          const newScript = '''
class TestSource extends ComicSource {
  name = "New Script";
  key = "transaction_a";
  version = "2.0.0";
  minAppVersion = "1.0.0";
  comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
}
''';
          activeFile.writeAsStringSync(newScript, flush: true);
          sessionFile.writeAsStringSync(
            jsonEncode({'token': 'overwritten_uncommitted_token'}),
            flush: true,
          );

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_session_test',
              key: 'transaction_a',
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              sessionBackupPath: sessionBackupFile.path,
              originalDigest: origDigest,
              newDigest: SourceFileMetadata.digest(newScript),
              originalSessionDigest: origSessionDigest,
              newSessionDigest: SourceFileMetadata.digest(
                jsonEncode({'token': 'overwritten_uncommitted_token'}),
              ),
              sessionWriteExpected: true,
              hadOriginalSession: true,
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: true,
              originalOrigin: const SourceOrigin(kind: 'file').toJson(),
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), goodScript);
          expect(
            jsonDecode(await sessionFile.readAsString())['token'],
            'original_secret_token',
          );
          expect(await journal.read(), isNull);
        },
      );

      test(
        'replay restores script but preserves independently edited session and journal',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'original_secret_token';
          await original.saveData();

          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');
          final sessionFile = File('${sourceDir.path}/${original.key}.data');
          final sessionBackupFile = File(
            '${sourceDir.path}/${original.key}.data.bak',
          );
          final originalScript = await activeFile.readAsString();
          final originalSession = await sessionFile.readAsString();
          final originalDigest = SourceFileMetadata.digest(originalScript);
          final originalSessionDigest = SourceFileMetadata.digest(
            originalSession,
          );
          backupFile.writeAsStringSync(originalScript, flush: true);
          sessionBackupFile.writeAsStringSync(originalSession, flush: true);

          final failedScript = script(original.key, version: '2.0.0');
          activeFile.writeAsStringSync(failedScript, flush: true);
          const manualSessionEdit = '{"token":"manual_user_edit"}';
          sessionFile.writeAsStringSync(manualSessionEdit, flush: true);
          const expectedSession = '{"token":"candidate_session"}';
          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_manual_session',
              key: original.key,
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              sessionBackupPath: sessionBackupFile.path,
              originalDigest: originalDigest,
              newDigest: SourceFileMetadata.digest(failedScript),
              originalSessionDigest: originalSessionDigest,
              newSessionDigest: SourceFileMetadata.digest(expectedSession),
              sessionWriteExpected: true,
              hadOriginalSession: true,
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: true,
              originalOrigin: const SourceOrigin(kind: 'file').toJson(),
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), originalScript);
          expect(await sessionFile.readAsString(), manualSessionEdit);
          expect(await journal.read(), isNotNull);
          expect(await sessionBackupFile.readAsString(), originalSession);
        },
      );

      test(
        'replay without a journal leaves unrecognized publication artifacts alone',
        () async {
          final source = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final artifacts = {
            File('${source.filePath}.bak'): 'unknown-script-backup',
            File('${source.filePath}.stage'): 'unknown-script-stage',
            File('${source.filePath}.old'): 'unknown-old-script',
            File('${sourceDir.path}/${source.key}.data.old'):
                'unknown-session-backup',
          };
          for (final entry in artifacts.entries) {
            entry.key.writeAsStringSync(entry.value, flush: true);
          }

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          for (final entry in artifacts.entries) {
            expect(await entry.key.readAsString(), entry.value);
          }
        },
      );

      test(
        'actual journal replay completes publication when sidecar metadata was committed',
        () async {
          final original = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');

          final goodScript = await activeFile.readAsString();
          final origDigest = SourceFileMetadata.digest(goodScript);
          backupFile.writeAsStringSync(goodScript, flush: true);

          const committedNew = '''
class TestSource extends ComicSource {
  name = "Committed New";
  key = "transaction_a";
  version = "2.0.0";
  minAppVersion = "1.0.0";
  comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
}
''';
          activeFile.writeAsStringSync(committedNew, flush: true);
          final newDigest = SourceFileMetadata.digest(committedNew);
          const pubId = 'pub_committed_test';

          await SourceFileMetadata.recordValidated(
            sourceDir,
            key: 'transaction_a',
            filename: 'transaction_a.js',
            content: committedNew,
            publicationId: pubId,
          );

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: pubId,
              key: 'transaction_a',
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              originalDigest: origDigest,
              newDigest: newDigest,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), committedNew);
          expect(await journal.read(), isNull);
          expect(backupFile.existsSync(), isFalse);
        },
      );

      test(
        'matching publication id with a different active body preserves manual script and journal',
        () async {
          final original = await install('transaction_a');
          final sourceDir = Directory('${directory.path}/comic_source');
          final activeFile = File(original.filePath);
          final backupFile = File('${original.filePath}.bak');
          final originalScript = await activeFile.readAsString();
          backupFile.writeAsStringSync(originalScript, flush: true);
          final candidate = script(original.key, version: '2.0.0');
          final manualEdit = script(original.key, version: '1.5.0');
          activeFile.writeAsStringSync(candidate, flush: true);
          const pubId = 'pub_manual_after_commit';
          await SourceFileMetadata.recordValidated(
            sourceDir,
            key: original.key,
            filename: activeFile.uri.pathSegments.last,
            content: candidate,
            publicationId: pubId,
          );
          activeFile.writeAsStringSync(manualEdit, flush: true);

          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: pubId,
              key: original.key,
              targetPath: activeFile.path,
              stagePath: '${activeFile.path}.stage',
              backupPath: backupFile.path,
              originalDigest: SourceFileMetadata.digest(originalScript),
              newDigest: SourceFileMetadata.digest(candidate),
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: true,
              originalOrigin: const SourceOrigin(kind: 'file').toJson(),
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await ComicSourceManager.recoverInterruptedPublications(sourceDir);

          expect(await activeFile.readAsString(), manualEdit);
          expect(await backupFile.readAsString(), originalScript);
          expect(await journal.read(), isNotNull);
        },
      );

      test(
        'parser rollback restores live JS registry and session if subsequent publication step fails',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'session_preserved';
          await original.saveData();

          final sidecar = File(
            '${directory.path}/comic_source/${SourceFileMetadata.sidecarFileName}',
          );
          sidecar.writeAsStringSync('corrupt invalid json {{{');

          final oldScript = await File(original.filePath).readAsString();

          await expectLater(
            manager.replaceScript(
              original,
              script(original.key, version: '2.0.0'),
              validate: () {},
            ),
            throwsA(isA<FormatException>()),
          );

          expect(manager.find(original.key), same(original));
          expect(await File(original.filePath).readAsString(), oldScript);
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.version'),
            '1.0.0',
          );
          expect(original.data['token'], 'session_preserved');
        },
      );
      test(
        'startup restores interrupted publication before loading the source',
        () async {
          await appdata.init();
          final sourceDir = Directory('${directory.path}/comic_source');
          final target = File('${sourceDir.path}/transaction_a.js');
          final backup = File('${target.path}.bak');
          final original = script('transaction_a');
          final interrupted = script('transaction_a', version: '2.0.0');
          backup.writeAsStringSync(original, flush: true);
          target.writeAsStringSync(interrupted, flush: true);
          final journal = SourcePublicationJournal(sourceDir);
          await journal.record(
            SourcePublicationJournalEntry(
              publicationId: 'pub_startup',
              key: 'transaction_a',
              targetPath: target.path,
              stagePath: '${target.path}.stage',
              backupPath: backup.path,
              originalDigest: SourceFileMetadata.digest(original),
              newDigest: SourceFileMetadata.digest(interrupted),
              originalPages: _sourcePageSnapshot(),
              newPages: _sourcePageSnapshot(),
              hadOriginalOrigin: false,
              originalOrigin: null,
              originChanges: false,
              stage: SourcePublicationStage.renamed,
              timestamp: DateTime.now(),
            ),
          );

          await manager.init();

          expect(await target.readAsString(), original);
          expect(manager.find('transaction_a')?.version, '1.0.0');
          expect(await journal.read(), isNull);
        },
      );
    },
    skip: nativeAvailable
        ? false
        : (_ciRequireQuickJs
              ? false
              : 'QuickJS native library unavailable; run with platform build DLLs on PATH.'),
  );
}

String script(String key, {String version = '1.0.0', String init = ''}) =>
    '''
  class TestSource extends ComicSource {
    name = "Test Source";
    key = "$key";
    version = "$version";
    minAppVersion = "1.0.0";
    comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
    init() { $init }
  }
''';
