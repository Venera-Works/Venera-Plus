import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

const bool _ciRequireQuickJs = bool.fromEnvironment(
  'CI_REQUIRE_QUICKJS',
  defaultValue: false,
);

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
    } else if (Platform.isLinux) {
      for (final buildDir in [
        'build/linux/x64/debug/bundle/lib',
        'build/linux/x64/release/bundle/lib',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/libflutter_qjs_plugin.so').existsSync()) {
          DynamicLibrary.open('$build/libflutter_qjs_plugin.so');
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

class _VirtualDavTransport implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('', 404);
  }
}

class _VirtualDavClient extends dav.Client {
  _VirtualDavClient()
    : super(
        uri: 'https://virtual.invalid/dav/',
        c: dav.WdDio(httpAdapter: _VirtualDavTransport()),
        auth: dav.Auth(user: 'test_user', pwd: 'test_pass'),
      );

  @override
  Future<void> ping([CancelToken? cancelToken]) async {}

  @override
  Future<void> mkdirAll(String path, [CancelToken? cancelToken]) async {}

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    return const [];
  }
}

String _generateComputedSourceScript({
  required String classPrefix,
  required List<String> keyParts,
  required String version,
  String name = 'Test Source',
  String? extraCode,
}) {
  final partsJson = jsonEncode(keyParts);
  return '''
class ${classPrefix}ComicSource extends ComicSource {
  name = "$name";
  key = $partsJson.join('_');
  version = "$version";
  minAppVersion = "1.0.0";
  ${extraCode ?? ''}
}
''';
}

int _holdNoDeleteHandle(String filePath) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getProcessHeap = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
  final heapAlloc = kernel32
      .lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)
      >('HeapAlloc');
  final heapFree = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
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
  final byteLength = (units.length + 1) * 2;
  final mem = heapAlloc(heap, 0, byteLength);
  final uint16List = mem.cast<Uint16>().asTypedList(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    uint16List[i] = units[i];
  }
  uint16List[units.length] = 0;

  final handle = createFileW(
    mem.cast<Uint16>(),
    0x80000000, // GENERIC_READ
    0x00000001 |
        0x00000002, // FILE_SHARE_READ | FILE_SHARE_WRITE (NO FILE_SHARE_DELETE)
    nullptr,
    3, // OPEN_EXISTING
    0x80, // FILE_ATTRIBUTE_NORMAL
    0,
  );
  heapFree(heap, 0, mem);

  if (handle == -1 || handle == 0) {
    throw StateError('CreateFileW failed for $filePath');
  }
  return handle;
}

void _closeHandle(int handle) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  closeHandle(handle);
}

void main() {
  final httpOverridesBefore = HttpOverrides.current;
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = httpOverridesBefore;

  final quickJsFailure = _quickJsLoadFailure();
  final quickJsAvailable = quickJsFailure == null;

  late Directory tempDir;
  late String originalDataPath;
  late String originalCachePath;

  setUpAll(() {
    JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
    try {
      originalDataPath = App.dataPath;
    } catch (_) {
      originalDataPath = Directory.systemTemp.path;
    }
    try {
      originalCachePath = App.cachePath;
    } catch (_) {
      originalCachePath = Directory.systemTemp.path;
    }
  });

  tearDownAll(() async {
    try {
      await JsEngine().dispose();
    } catch (_) {}
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera-source-recovery-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    App.version = '9.0.0';
    Directory(p.join(tempDir.path, 'comic_source')).createSync(recursive: true);
    if (quickJsAvailable) {
      JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
      await JsEngine().init();
    }
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group(
    'SourceIdentityRecovery QuickJS',
    () {
      setUp(() {
        if (_ciRequireQuickJs && quickJsFailure != null) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires QuickJS native library, '
            'but it failed to load: $quickJsFailure',
          );
        }
      });

      test(
        'identical aliases normalize to canonical file, preserve session intact and logical name',
        () async {
          final profileDir = Directory(p.join(tempDir.path, 'profile_case1'))
            ..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const keyParts = ['alias', 'norm', 'key'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'AliasNorm',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Alias Comic Source',
          );

          final canonicalName =
              'sync_${sha256.convert(utf8.encode(computedKey))}.js';
          final canonicalFile = File(p.join(sourceDir.path, canonicalName));
          final aliasFile = File(p.join(sourceDir.path, 'alias_copy.js'));
          canonicalFile.writeAsStringSync(scriptContent);
          aliasFile.writeAsStringSync(scriptContent);

          final sidecarFile = File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          );
          sidecarFile.writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'my_custom_source.js',
                'revisions': <String, String>{},
              },
            }),
          );

          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'));
          const sessionData = {
            'token': 'session_token_123',
            'user': 'alias_user',
          };
          sessionFile.writeAsStringSync(jsonEncode(sessionData));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);

          final preSnapshot = await adapter.exportSyncSnapshot();
          expect(preSnapshot.needsSourceNormalization, isTrue);
          final sourceKey = syncRecordKey('source', [computedKey]);
          final sessionKey = syncRecordKey('sourceSession', [computedKey]);
          expect(preSnapshot.records, contains(sourceKey));
          expect(preSnapshot.records, contains(sessionKey));
          expect(preSnapshot.sourceVariants[sourceKey] ?? const [], isEmpty);

          final stateDir = Directory(p.join(profileDir.path, 'sync_state'));
          final coordinator = MergeSyncCoordinator(
            endpointHash: 'hash_alias_norm',
            stateDirectory: stateDir,
            actor: 'device_norm',
            store: MergeStore(stateDir, 'device_norm'),
            remote: MergeRemote(_VirtualDavClient()),
            preferencesAdapter: adapter,
            exportFavoritesOverride: () => {},
            applyFavoritesOverride: (_) {},
            exportHistoryOverride: () async => {},
            applyHistoryOverride: (_) {},
            getGenerationOverride: () => 0,
          );

          await coordinator.startupRecovery();

          final jsFiles = sourceDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.js'))
              .toList();
          expect(jsFiles, hasLength(1));
          expect(jsFiles.first.readAsStringSync(), equals(scriptContent));

          expect(sessionFile.existsSync(), isTrue);
          expect(
            jsonDecode(sessionFile.readAsStringSync()),
            equals(sessionData),
          );

          final postSnapshot = await adapter.exportSyncSnapshot();
          expect(postSnapshot.needsSourceNormalization, isFalse);
          final scriptRecord =
              postSnapshot.records[sourceKey]!['script'] as Map;
          expect(scriptRecord['filename'], equals('my_custom_source.js'));
          expect(
            postSnapshot.records[sessionKey]!['data'],
            equals(sessionData),
          );
          expect(coordinator.store.document.conflicts, isEmpty);
        },
      );

      test(
        'differing same-key contents persist as conflict candidates across restart, explicit resolution applies chosen content without resurrection',
        () async {
          final profileDir = Directory(p.join(tempDir.path, 'profile_case2'))
            ..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const keyParts = ['conflict', 'eval', 'key'];
          final computedKey = keyParts.join('_');
          final contentA = _generateComputedSourceScript(
            classPrefix: 'ConflictA',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Conflict Version A',
          );
          final contentB = _generateComputedSourceScript(
            classPrefix: 'ConflictB',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Conflict Version B',
          );

          File(
            p.join(sourceDir.path, 'z_alias_a1.js'),
          ).writeAsStringSync(contentA);
          File(
            p.join(sourceDir.path, 'y_alias_a2.js'),
          ).writeAsStringSync(contentA);
          File(
            p.join(sourceDir.path, 'x_variant_b.js'),
          ).writeAsStringSync(contentB);

          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'));
          const sessionData = {'auth': 'conflict_session_data'};
          sessionFile.writeAsStringSync(jsonEncode(sessionData));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final snapshot = await adapter.exportSyncSnapshot();
          expect(snapshot.needsSourceNormalization, isTrue);
          final sourceKey = syncRecordKey('source', [computedKey]);
          expect(snapshot.sourceVariants, contains(sourceKey));
          expect(snapshot.sourceVariants[sourceKey], hasLength(2));

          final stateDir = Directory(p.join(profileDir.path, 'sync_state'));
          MergeSyncCoordinator makeCoordinator() => MergeSyncCoordinator(
            endpointHash: 'hash_conflict_test',
            stateDirectory: stateDir,
            actor: 'device_conflict',
            store: MergeStore(stateDir, 'device_conflict'),
            remote: MergeRemote(_VirtualDavClient()),
            preferencesAdapter: adapter,
            exportFavoritesOverride: () => {},
            applyFavoritesOverride: (_) {},
            exportHistoryOverride: () async => {},
            applyHistoryOverride: (_) {},
            getGenerationOverride: () => 0,
          );

          var coordinator = makeCoordinator();
          await coordinator.startupRecovery();

          final initialConflict = coordinator.store.document.conflicts
              .singleWhere(
                (c) => c.recordKey == sourceKey && c.field == 'script',
              );
          final initialContents = initialConflict.candidates
              .map((c) => (c.value as Map)['content'] as String)
              .toSet();
          expect(initialContents, equals({contentA, contentB}));

          coordinator = makeCoordinator();
          await coordinator.startupRecovery();

          final restartedConflict = coordinator.store.document.conflicts
              .singleWhere(
                (c) => c.recordKey == sourceKey && c.field == 'script',
              );
          final restartedContents = restartedConflict.candidates
              .map((c) => (c.value as Map)['content'] as String)
              .toSet();
          expect(restartedContents, equals({contentA, contentB}));

          final chosenCandidate = restartedConflict.candidates.firstWhere(
            (c) => (c.value as Map)['content'] == contentB,
          );

          final resolveRes = await coordinator.resolveConflict(
            recordKey: sourceKey,
            field: 'script',
            candidateId: chosenCandidate.id,
            direction: SyncDirection.downloadOnly,
          );
          expect(resolveRes.success, isTrue);
          expect(
            coordinator.store.document.conflicts.where(
              (c) => c.recordKey == sourceKey,
            ),
            isEmpty,
          );

          final jsFiles = sourceDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.js'))
              .toList();
          expect(jsFiles, hasLength(1));
          expect(jsFiles.first.readAsStringSync(), equals(contentB));
          expect(sessionFile.existsSync(), isTrue);

          coordinator = makeCoordinator();
          await coordinator.startupRecovery();

          expect(
            coordinator.store.document.conflicts.where(
              (c) => c.recordKey == sourceKey,
            ),
            isEmpty,
          );
          final postRestartSnapshot = await adapter.exportSyncSnapshot();
          expect(postRestartSnapshot.needsSourceNormalization, isFalse);
          expect(
            (postRestartSnapshot.records[sourceKey]!['script']
                as Map)['content'],
            equals(contentB),
          );
        },
      );

      test(
        'Windows failed old-file delete after canonical write retains journal and recovers without duplicate-key fatal error',
        () async {
          final profileDir = Directory(p.join(tempDir.path, 'profile_case3'))
            ..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const keyParts = ['win', 'lock', 'recovery'];
          final computedKey = keyParts.join('_');
          final contentA = _generateComputedSourceScript(
            classPrefix: 'WinLockA',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Windows Lock Source A',
          );
          final contentB = _generateComputedSourceScript(
            classPrefix: 'WinLockB',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Windows Lock Source B',
          );

          final oldFile = File(p.join(sourceDir.path, 'old_script_file.js'));
          oldFile.writeAsStringSync(contentA);

          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'));
          const sessionData = {'login': 'win_lock_user'};
          sessionFile.writeAsStringSync(jsonEncode(sessionData));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final stateDir = Directory(p.join(profileDir.path, 'sync_state'));

          MergeSyncCoordinator makeCoordinator() => MergeSyncCoordinator(
            endpointHash: 'hash_win_lock',
            stateDirectory: stateDir,
            actor: 'device_win_lock',
            store: MergeStore(stateDir, 'device_win_lock'),
            remote: MergeRemote(_VirtualDavClient()),
            preferencesAdapter: adapter,
            exportFavoritesOverride: () => {},
            applyFavoritesOverride: (_) {},
            exportHistoryOverride: () async => {},
            applyHistoryOverride: (_) {},
            getGenerationOverride: () => 0,
          );

          final coordinator = makeCoordinator();
          await coordinator.store.load();

          final snapshotA = await adapter.exportSyncSnapshot();
          await coordinator.store.capture(snapshotA.records);

          final sourceKey = syncRecordKey('source', [computedKey]);
          final incomingBRecords = <String, Map<String, Object?>>{
            sourceKey: {
              'script': {'filename': 'new_canonical.js', 'content': contentB},
            },
          };
          final seedDocB = MergeDocument()
            ..captureLocal('remote_b', {}, incomingBRecords);
          coordinator.store.document.merge(seedDocB);
          final desiredB = cloneSyncRecords(snapshotA.records);
          desiredB[sourceKey] = {
            ...?desiredB[sourceKey],
            'script': incomingBRecords[sourceKey]!['script'],
          };
          await coordinator.store.stageApply(desiredB);

          final holdHandle = _holdNoDeleteHandle(oldFile.path);

          try {
            await coordinator.applyAllRecords(desiredB);
            fail('Expected FileSystemException when deleting locked old file');
          } on FileSystemException {
            // OS sharing violation propagated as expected
          } finally {
            _closeHandle(holdHandle);
          }

          final canonicalName =
              'sync_${sha256.convert(utf8.encode(computedKey))}.js';
          final canonicalFile = File(p.join(sourceDir.path, canonicalName));

          expect(oldFile.existsSync(), isTrue);
          expect(oldFile.readAsStringSync(), equals(contentA));
          expect(canonicalFile.existsSync(), isTrue);
          expect(canonicalFile.readAsStringSync(), equals(contentB));
          expect(coordinator.store.pendingApply, isNotNull);

          final recoveryCoordinator = makeCoordinator();
          await recoveryCoordinator.startupRecovery();

          expect(recoveryCoordinator.store.pendingApply, isNull);
          final conflict = recoveryCoordinator.store.document.conflicts
              .singleWhere(
                (c) => c.recordKey == sourceKey && c.field == 'script',
              );
          final conflictContents = conflict.candidates
              .map((c) => (c.value as Map)['content'] as String)
              .toSet();
          expect(conflictContents, equals({contentA, contentB}));

          expect(sessionFile.existsSync(), isTrue);
          expect(
            jsonDecode(sessionFile.readAsStringSync()),
            equals(sessionData),
          );
        },
        skip: Platform.isWindows ? null : 'Windows-only OS lock recovery',
      );

      test(
        'interrupted alias normalization after explicit resolution does not resurrect old content on recovery',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_case_interrupted_alias'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['win', 'no_resurrect', 'key'];
          final computedKey = keyParts.join('_');
          final contentA = _generateComputedSourceScript(
            classPrefix: 'WinNoResurrectA',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Win No Resurrect Source A',
          );
          final contentB = _generateComputedSourceScript(
            classPrefix: 'WinNoResurrectB',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Win No Resurrect Source B',
          );

          final selectedFile = File(p.join(sourceDir.path, 'a_selected.js'))
            ..writeAsStringSync(contentA);
          final staleFile = File(p.join(sourceDir.path, 'z_stale.js'))
            ..writeAsStringSync(contentA);

          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'));
          const sessionData = {'login': 'win_interrupted_user'};
          sessionFile.writeAsStringSync(jsonEncode(sessionData));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final stateDir = Directory(p.join(profileDir.path, 'sync_state'));

          MergeSyncCoordinator makeCoordinator() => MergeSyncCoordinator(
            endpointHash: 'hash_win_interrupted',
            stateDirectory: stateDir,
            actor: 'device_win_interrupted',
            store: MergeStore(stateDir, 'device_win_interrupted'),
            remote: MergeRemote(_VirtualDavClient()),
            preferencesAdapter: adapter,
            exportFavoritesOverride: () => {},
            applyFavoritesOverride: (_) {},
            exportHistoryOverride: () async => {},
            applyHistoryOverride: (_) {},
            getGenerationOverride: () => 0,
          );

          final coordinator = makeCoordinator();
          await coordinator.store.load();

          final snapshotA = await adapter.exportSyncSnapshot();
          await coordinator.store.capture(snapshotA.records);

          final sourceKey = syncRecordKey('source', [computedKey]);
          final incomingBRecords = <String, Map<String, Object?>>{
            sourceKey: {
              'script': {'filename': 'new_b.js', 'content': contentB},
            },
          };
          final seedDocB = MergeDocument()
            ..captureLocal('remote_b', {}, incomingBRecords);
          coordinator.store.document.merge(seedDocB);

          final conflict = coordinator.store.document.conflicts.singleWhere(
            (c) => c.recordKey == sourceKey && c.field == 'script',
          );
          final candidateB = conflict.candidates.firstWhere(
            (c) => (c.value as Map)['content'] == contentB,
          );
          await coordinator.store.resolve(sourceKey, 'script', candidateB.id);

          final desiredB = coordinator.store.document.materialize(
            preferred: coordinator.store.observed,
          );
          await coordinator.store.stageApply(desiredB);
          expect(coordinator.store.pendingApply, isNotNull);

          final holdHandle = _holdNoDeleteHandle(staleFile.path);

          try {
            await coordinator.applyAllRecords(
              coordinator.store.pendingApply!,
              beforeCommit: () => selectedFile.deleteSync(),
            );
            fail(
              'Expected FileSystemException when deleting locked stale file',
            );
          } on FileSystemException {
            // OS sharing violation when deleting locked z_stale.js propagated as expected
          } finally {
            _closeHandle(holdHandle);
          }

          final canonicalName =
              'sync_${sha256.convert(utf8.encode(computedKey))}.js';
          final canonicalFile = File(p.join(sourceDir.path, canonicalName));

          expect(selectedFile.existsSync(), isFalse);
          expect(staleFile.existsSync(), isTrue);
          expect(staleFile.readAsStringSync(), equals(contentA));
          expect(canonicalFile.existsSync(), isTrue);
          expect(canonicalFile.readAsStringSync(), equals(contentB));
          expect(coordinator.store.pendingApply, isNotNull);

          final recoveryCoordinator = makeCoordinator();
          await recoveryCoordinator.startupRecovery();

          final jsFiles = sourceDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.js'))
              .toList();
          expect(jsFiles, hasLength(1));
          expect(jsFiles.first.readAsStringSync(), equals(contentB));
          expect(
            recoveryCoordinator.store.document.conflicts.where(
              (c) => c.recordKey == sourceKey,
            ),
            isEmpty,
          );
          expect(sessionFile.existsSync(), isTrue);
          expect(
            jsonDecode(sessionFile.readAsStringSync()),
            equals(sessionData),
          );
          expect(recoveryCoordinator.store.pendingApply, isNull);
        },
        skip: Platform.isWindows ? null : 'Windows-only OS lock recovery',
      );

      test(
        'lack of preservation proof aborts direct destructive apply before business commit',
        () async {
          final profileDir = Directory(p.join(tempDir.path, 'profile_case4'))
            ..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const keyParts = ['guard', 'proof', 'key'];
          final computedKey = keyParts.join('_');
          final content1 = _generateComputedSourceScript(
            classPrefix: 'GuardV1',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Guard Version 1',
          );
          final content2 = _generateComputedSourceScript(
            classPrefix: 'GuardV2',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Guard Version 2',
          );

          final file1 = File(p.join(sourceDir.path, 'guard_1.js'))
            ..writeAsStringSync(content1);
          final file2 = File(p.join(sourceDir.path, 'guard_2.js'))
            ..writeAsStringSync(content2);

          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'));
          sessionFile.writeAsStringSync(jsonEncode({'active': true}));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final sourceKey = syncRecordKey('source', [computedKey]);

          final incomingRecords = <String, Map<String, Object?>>{
            sourceKey: {
              'script': {'filename': 'guard_1.js', 'content': content1},
            },
          };

          var committed = false;
          await expectLater(
            adapter.applySyncRecords(
              incomingRecords,
              beforeCommit: () => committed = true,
              hasPreservedSourceVariant: (recordKey, script) => false,
            ),
            throwsA(isA<StateError>()),
          );
          expect(committed, isFalse);

          expect(file1.existsSync(), isTrue);
          expect(file1.readAsStringSync(), equals(content1));
          expect(file2.existsSync(), isTrue);
          expect(file2.readAsStringSync(), equals(content2));
          expect(sessionFile.existsSync(), isTrue);

          final profileDirAliases = Directory(
            p.join(tempDir.path, 'profile_case4_aliases'),
          )..createSync(recursive: true);
          App.dataPath = profileDirAliases.path;
          App.cachePath = profileDirAliases.path;
          final sourceDirAliases = Directory(
            p.join(profileDirAliases.path, 'comic_source'),
          )..createSync(recursive: true);
          const aliasKeyParts = ['alias', 'guard', 'key'];
          final aliasComputedKey = aliasKeyParts.join('_');
          final localAliasContent = _generateComputedSourceScript(
            classPrefix: 'LocalAlias',
            keyParts: aliasKeyParts,
            version: '1.0.0',
            name: 'Local Alias Source',
          );
          final incomingDiffContent = _generateComputedSourceScript(
            classPrefix: 'IncomingDiff',
            keyParts: aliasKeyParts,
            version: '2.0.0',
            name: 'Incoming Different Source',
          );

          final aliasFile1 = File(
            p.join(sourceDirAliases.path, 'alias_copy1.js'),
          )..writeAsStringSync(localAliasContent);
          final aliasFile2 = File(
            p.join(sourceDirAliases.path, 'alias_copy2.js'),
          )..writeAsStringSync(localAliasContent);
          final aliasSession = File(
            p.join(sourceDirAliases.path, '$aliasComputedKey.data'),
          )..writeAsStringSync(jsonEncode({'alias_active': true}));

          final aliasAdapter = SyncPreferencesAdapter(
            dataPath: profileDirAliases.path,
          );
          final aliasSourceKey = syncRecordKey('source', [aliasComputedKey]);
          final incomingAliasRecords = <String, Map<String, Object?>>{
            aliasSourceKey: {
              'script': {
                'filename': 'incoming.js',
                'content': incomingDiffContent,
              },
            },
          };

          var aliasCommitted = false;
          await expectLater(
            aliasAdapter.applySyncRecords(
              incomingAliasRecords,
              beforeCommit: () => aliasCommitted = true,
              hasPreservedSourceVariant: (recordKey, script) => false,
            ),
            throwsA(isA<StateError>()),
          );
          expect(aliasCommitted, isFalse);
          expect(aliasFile1.existsSync(), isTrue);
          expect(aliasFile1.readAsStringSync(), equals(localAliasContent));
          expect(aliasFile2.existsSync(), isTrue);
          expect(aliasFile2.readAsStringSync(), equals(localAliasContent));
          expect(aliasSession.existsSync(), isTrue);
        },
      );

      test(
        'source-only normalization stages snapshot records without applying unobserved foreign document records',
        () async {
          final profileDir = Directory(p.join(tempDir.path, 'profile_case5'))
            ..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const keyParts = ['source', 'only', 'norm'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'SourceOnly',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Source Only Normalization',
          );

          File(
            p.join(sourceDir.path, 'first_copy.js'),
          ).writeAsStringSync(scriptContent);
          File(
            p.join(sourceDir.path, 'second_copy.js'),
          ).writeAsStringSync(scriptContent);

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final stateDir = Directory(p.join(profileDir.path, 'sync_state'));

          final foreignSettingKey = syncRecordKey('setting', [
            'sourceRecoveryUnappliedSetting',
          ]);
          final foreignRecords = <String, Map<String, Object?>>{
            foreignSettingKey: {'value': 'remote_only_value'},
          };

          final store = MergeStore(stateDir, 'device_local');
          await store.load();
          final initialSnapshot = await adapter.exportSyncSnapshot();
          await store.capture(initialSnapshot.records);
          store.document.captureLocal('foreign_device', {}, foreignRecords);
          await store.save();
          final coordinator = MergeSyncCoordinator(
            endpointHash: 'hash_foreign_isolation',
            stateDirectory: stateDir,
            actor: 'device_local',
            store: store,
            remote: MergeRemote(_VirtualDavClient()),
            preferencesAdapter: adapter,
            exportFavoritesOverride: () => {},
            applyFavoritesOverride: (_) {},
            exportHistoryOverride: () async => {},
            applyHistoryOverride: (_) {},
            getGenerationOverride: () => 0,
          );

          await coordinator.startupRecovery();

          final jsFiles = sourceDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.js'))
              .toList();
          expect(jsFiles, hasLength(1));

          final localSnapshot = await adapter.exportSyncSnapshot();
          expect(localSnapshot.records.containsKey(foreignSettingKey), isFalse);
          final localSourceKey = syncRecordKey('source', [computedKey]);
          expect(localSnapshot.records.containsKey(localSourceKey), isTrue);
          final scriptRecord =
              localSnapshot.records[localSourceKey]!['script'] as Map;
          expect(scriptRecord['content'], equals(scriptContent));
        },
      );
    },
    skip: (_ciRequireQuickJs || quickJsAvailable) ? false : quickJsFailure,
  );
}
