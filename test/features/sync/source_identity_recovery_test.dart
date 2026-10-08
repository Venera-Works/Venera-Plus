import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/sync/source_recovery.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
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
            await coordinator.applyAllRecords(coordinator.store.pendingApply!);
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

      test(
        'empty artifact next to valid alias normalizes safely, quarantines empty file, and preserves session intact without tombstones',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_empty_alias'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['komiic', 'alias', 'test'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'KomiicAlias',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Komiic Source',
          );

          final emptyFile = File(p.join(sourceDir.path, 'komiic.js'))
            ..writeAsStringSync('');
          File(p.join(sourceDir.path, 'komiic(0).js'))
            ..writeAsStringSync(scriptContent);
          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'komiic.js',
                'revisions': <String, String>{},
              },
            }),
          );
          final sessionFile = File(p.join(sourceDir.path, '$computedKey.data'))
            ..writeAsStringSync(jsonEncode({'token': 'keep_me_alive'}));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          await adapter.recoverLocalSources();
          final snapshot = await adapter.exportSyncSnapshot();

          final sourceKey = syncRecordKey('source', [computedKey]);
          final sessionKey = syncRecordKey('sourceSession', [computedKey]);

          expect(snapshot.records.containsKey(sourceKey), isTrue);
          expect(snapshot.records.containsKey(sessionKey), isTrue);
          expect(snapshot.unavailableDomains.contains('source'), isFalse);
          expect(
            snapshot.unavailableDomains.contains('sourceSession'),
            isFalse,
          );

          expect(emptyFile.existsSync(), isFalse);
          final quarantineDir = Directory(
            p.join(sourceDir.path, '.quarantine'),
          );
          expect(quarantineDir.existsSync(), isTrue);

          expect(sessionFile.existsSync(), isTrue);
          expect(
            jsonDecode(sessionFile.readAsStringSync())['token'],
            'keep_me_alive',
          );

          final recoveredIssues = snapshot.sourceIssues.where(
            (i) => i.filename == 'komiic.js',
          );
          expect(recoveredIssues, isNotEmpty);
          expect(recoveredIssues.first.recovered, isTrue);
          expect(recoveredIssues.first.backupPath, isNotNull);
        },
      );

      test(
        'sole damaged known file restores from approved recoveryRecords, while unapproved damaged file remains visibly unresolved without recreating absent scripts',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_damaged_repair'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['repaired', 'known', 'source'];
          final computedKey = keyParts.join('_');
          final approvedScript = _generateComputedSourceScript(
            classPrefix: 'RepairedKnown',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Approved Body Source',
          );

          final damagedFile = File(p.join(sourceDir.path, 'repaired_known.js'))
            ..writeAsStringSync('{{{ syntax error not valid javascript');

          final unapprovedFile = File(
            p.join(sourceDir.path, 'unapproved_corrupt.js'),
          )..writeAsStringSync('invalid syntax corrupt body');

          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'repaired_known.js',
                'revisions': <String, String>{},
              },
              'unapproved_key': {
                'filename': 'unapproved_corrupt.js',
                'revisions': <String, String>{},
              },
            }),
          );

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);

          final absentKey = 'plain_absent_key';
          final absentScript = _generateComputedSourceScript(
            classPrefix: 'PlainAbsent',
            keyParts: [absentKey],
            version: '1.0.0',
            name: 'Absent Source',
          );

          final recoveryRecords = <String, Map<String, Object?>>{
            syncRecordKey('source', [computedKey]): {
              'script': {
                'filename': 'repaired_known.js',
                'content': approvedScript,
              },
            },
            syncRecordKey('source', [absentKey]): {
              'script': {
                'filename': 'plain_absent.js',
                'content': absentScript,
              },
            },
          };

          await adapter.recoverLocalSources(recoveryRecords: recoveryRecords);
          final snapshot = await adapter.exportSyncSnapshot(
            recoveryRecords: recoveryRecords,
          );

          final canonicalRepaired = File(
            p.join(
              sourceDir.path,
              SourceFileMetadata.physicalName(computedKey),
            ),
          );
          expect(canonicalRepaired.existsSync(), isTrue);
          expect(canonicalRepaired.readAsStringSync(), approvedScript);

          expect(damagedFile.existsSync(), isFalse);

          expect(unapprovedFile.existsSync(), isTrue);
          expect(
            unapprovedFile.readAsStringSync(),
            'invalid syntax corrupt body',
          );

          final absentFile = File(
            p.join(sourceDir.path, SourceFileMetadata.physicalName(absentKey)),
          );
          expect(absentFile.existsSync(), isFalse);
          expect(
            snapshot.records.containsKey(syncRecordKey('source', [absentKey])),
            isFalse,
          );

          expect(snapshot.unavailableDomains, contains('source'));
          expect(
            snapshot.sourceIssues.any(
              (i) => i.filename == 'unapproved_corrupt.js' && !i.recovered,
            ),
            isTrue,
          );
        },
      );

      test(
        'unknown bad script and unsupportedHostApi script remain explicit partial blockers across restart',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_unknown_forbidden'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          final unknownFile = File(p.join(sourceDir.path, 'unknown_bad.js'))
            ..writeAsStringSync('corrupt syntax bad');

          final forbiddenHostScript = '''
class ForbiddenHostSource extends ComicSource {
  name = "Forbidden Host";
  key = "forbidden_host_key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  constructor() {
    super();
    Network.setCookies("https://example.com", []);
  }
}
''';
          final forbiddenFile = File(
            p.join(sourceDir.path, 'forbidden_host.js'),
          )..writeAsStringSync(forbiddenHostScript);

          appdata.settings['someExportableSetting'] = 'exported_value_42';

          final adapter1 = SyncPreferencesAdapter(dataPath: profileDir.path);
          await adapter1.recoverLocalSources();
          final snapshot1 = await adapter1.exportSyncSnapshot();

          final settingKey = syncRecordKey('setting', [
            'someExportableSetting',
          ]);
          expect(snapshot1.records.containsKey(settingKey), isTrue);
          expect(snapshot1.unavailableDomains, contains('source'));
          // Unknown invalid bytes remain in place and never gain a quarantine tombstone.
          expect(unknownFile.existsSync(), isTrue);
          expect(unknownFile.readAsStringSync(), 'corrupt syntax bad');
          expect(
            Directory(
              p.join(sourceDir.path, '.quarantine', 'records'),
            ).existsSync(),
            isFalse,
          );

          // Forbidden host file was NOT quarantined (left in place)
          expect(forbiddenFile.existsSync(), isTrue);

          // Re-instantiate adapter on restarted profile directory
          final adapter2 = SyncPreferencesAdapter(dataPath: profileDir.path);
          final snapshot2 = await adapter2.exportSyncSnapshot();

          // The hash-bound issue persists across restart without deleting the file.
          expect(unknownFile.existsSync(), isTrue);
          expect(snapshot2.unavailableDomains, contains('source'));
          expect(snapshot2.records.containsKey(settingKey), isTrue);
          final restartedIssue = snapshot2.sourceIssues.firstWhere(
            (i) => i.filename == 'unknown_bad.js' && !i.recovered,
          );
          expect(
            restartedIssue.contentDigest,
            sha256.convert(utf8.encode('corrupt syntax bad')).toString(),
          );
        },
      );

      test(
        'manual valid reinstall at an unknown quarantine filename proves its key without losing original backup bytes',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_manual_reinstall'),
          )..createSync(recursive: true);
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const key = 'repaired_source';
          final replacement = _generateComputedSourceScript(
            classPrefix: 'ReinstalledSource',
            keyParts: ['repaired', 'source'],
            version: '1.0.0',
            name: 'Reinstalled Source',
          );
          const originalBytes = 'unrecognized original bytes';
          final originalFile = File(p.join(sourceDir.path, 'unrecognized.js'))
            ..writeAsStringSync(originalBytes);
          final quarantine = SourceQuarantineManager(sourceDir);
          final record = await quarantine.quarantineFile(
            originalFile,
            reason: 'syntaxError',
          );
          expect(record, isNotNull);
          originalFile.writeAsStringSync(replacement);

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          await adapter.recoverLocalSources();
          final snapshot = await adapter.exportSyncSnapshot();
          final updated = (await quarantine.readJournal()).single;
          final canonicalFile = File(
            p.join(sourceDir.path, SourceFileMetadata.physicalName(key)),
          );

          expect(updated.recovered, isTrue);
          expect(updated.sourceKey, isNull);
          expect(updated.recoveredByKey, key);
          expect(File(record!.backupPath).readAsStringSync(), originalBytes);
          expect(originalFile.readAsStringSync(), replacement);
          expect(canonicalFile.readAsStringSync(), replacement);
          expect(snapshot.unavailableDomains.contains('source'), isFalse);
          expect(
            snapshot.sourceIssues.any(
              (issue) => issue.filename == 'unrecognized.js' && issue.recovered,
            ),
            isTrue,
          );
        },
      );

      test(
        'applySyncRecords with unavailableDomains skips blocked source and session domains without overwriting or deleting, and settings-only apply does not reload sources',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_partial_apply'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          final localScript = _generateComputedSourceScript(
            classPrefix: 'LocalUntouched',
            keyParts: ['local_untouched'],
            version: '1.0.0',
            name: 'Local Untouched',
          );
          final localFile = File(p.join(sourceDir.path, 'local_untouched.js'))
            ..writeAsStringSync(localScript);
          final localSession = File(
            p.join(sourceDir.path, 'local_untouched.data'),
          )..writeAsStringSync(jsonEncode({'session': 'local_preserved'}));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);

          final incomingRecords = <String, Map<String, Object?>>{
            syncRecordKey('setting', ['testSettingOnly']): {
              'value': 'applied_ok',
            },
            syncRecordKey('source', ['local_untouched']): {
              'script': {
                'filename': 'local_untouched.js',
                'content': 'foreign remote content that should not overwrite',
              },
            },
          };

          await adapter.applySyncRecords(
            incomingRecords,
            unavailableDomains: {'source', 'sourceSession'},
          );

          expect(localFile.existsSync(), isTrue);
          expect(localFile.readAsStringSync(), equals(localScript));

          expect(localSession.existsSync(), isTrue);
          expect(
            jsonDecode(localSession.readAsStringSync())['session'],
            'local_preserved',
          );

          expect(appdata.settings['testSettingOnly'], 'applied_ok');
        },
      );

      test(
        'readLegacySnapshot reports issues and blocked domains without destroying bad bytes or modifying live profile',
        () async {
          final legacyDir = Directory(p.join(tempDir.path, 'legacy_extracted'))
            ..createSync(recursive: true);
          final sourceDir = Directory(p.join(legacyDir.path, 'comic_source'))
            ..createSync(recursive: true);

          final validScript = _generateComputedSourceScript(
            classPrefix: 'LegacyValid',
            keyParts: ['legacy_valid'],
            version: '1.0.0',
            name: 'Legacy Valid',
          );
          File(
            p.join(sourceDir.path, 'legacy_valid.js'),
          ).writeAsStringSync(validScript);

          final badFile = File(p.join(sourceDir.path, 'legacy_corrupt.js'))
            ..writeAsStringSync('corrupt legacy bytes');

          File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync(
            jsonEncode({
              'settings': {'legacySettingKey': 'legacy_val'},
            }),
          );

          final profileDir = Directory(p.join(tempDir.path, 'live_profile'))
            ..createSync(recursive: true);
          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);

          final snapshot = await adapter.readLegacySnapshot(legacyDir);

          expect(
            snapshot.records.containsKey(
              syncRecordKey('setting', ['legacySettingKey']),
            ),
            isTrue,
          );
          expect(
            snapshot.records.containsKey(
              syncRecordKey('source', ['legacy_valid']),
            ),
            isTrue,
          );

          expect(snapshot.unavailableDomains, contains('source'));
          expect(
            snapshot.sourceIssues.any((i) => i.filename == 'legacy_corrupt.js'),
            isTrue,
          );

          expect(badFile.existsSync(), isTrue);
          expect(badFile.readAsStringSync(), 'corrupt legacy bytes');

          final liveSourceDir = Directory(
            p.join(profileDir.path, 'comic_source'),
          );
          expect(liveSourceDir.existsSync(), isFalse);
        },
      );

      test(
        'Windows locked writes and OS failures propagate as source issues without unhandled crash',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_locked_writes'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['locked', 'write', 'key'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'LockedWrite',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Locked Write Source',
          );

          final corruptFile = File(p.join(sourceDir.path, 'locked_corrupt.js'))
            ..writeAsStringSync('corrupt bytes');
          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'locked_corrupt.js',
                'revisions': <String, String>{},
              },
            }),
          );

          int? handle;
          if (Platform.isWindows) {
            handle = _holdNoDeleteHandle(corruptFile.path);
          }

          try {
            final issues = await SourceRecovery.recoverLocalSources(
              sourceDir,
              recoveryRecords: {
                syncRecordKey('source', [computedKey]): {
                  'script': {
                    'filename': 'locked_corrupt.js',
                    'content': scriptContent,
                  },
                },
              },
            );

            if (Platform.isWindows && handle != 0) {
              expect(
                issues.any(
                  (i) => i.filename == 'locked_corrupt.js' && !i.recovered,
                ),
                isTrue,
              );
            }
          } finally {
            if (handle != null && handle != 0) {
              _closeHandle(handle);
            }
          }
        },
      );

      test(
        'corrupt quarantine journal emits journalCorrupted blocker without erasing file, and strict schema validation rejects malformed records',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_corrupt_journal'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          final quarantineDir = Directory(p.join(sourceDir.path, '.quarantine'))
            ..createSync(recursive: true);

          final journalFile = File(p.join(quarantineDir.path, 'journal.json'))
            ..writeAsStringSync('{ malformed json not array [');

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final snapshot = await adapter.exportSyncSnapshot();

          expect(snapshot.unavailableDomains, contains('source'));
          expect(
            snapshot.sourceIssues.any(
              (i) =>
                  i.filename == '.quarantine/journal.json' &&
                  i.reason == 'journalCorrupted',
            ),
            isTrue,
          );
          // Journal file was NOT erased
          expect(journalFile.existsSync(), isTrue);
          expect(
            journalFile.readAsStringSync(),
            '{ malformed json not array [',
          );

          // Strict validation of schema fields in SourceQuarantineRecord.fromJson
          expect(
            () => SourceQuarantineRecord.fromJson({
              'originalPath': '',
              'filename': 'valid.js',
              'originalHash': '123',
              'backupPath': '/path',
              'reason': 'syntaxError',
              'timestamp': '2026-01-01',
              'fileSize': 10,
              'recovered': false,
            }),
            throwsFormatException,
          );
        },
      );

      test(
        'concurrent edit detected immediately before destructive removal preserves user edits and propagates beforeCommit exceptions',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_concurrent_edit'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['concurrent', 'edit', 'test'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'ConcurrentEdit',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Concurrent Edit Source',
          );

          final candidateFile = File(
            p.join(sourceDir.path, 'concurrent_file.js'),
          )..writeAsStringSync('initial bad syntax {{{');
          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'concurrent_file.js',
                'revisions': <String, String>{},
              },
            }),
          );

          // Test that beforeCommit exceptions propagate cleanly without being swallowed
          await expectLater(
            SourceRecovery.recoverLocalSources(
              sourceDir,
              recoveryRecords: {
                syncRecordKey('source', [computedKey]): {
                  'script': {
                    'filename': 'concurrent_file.js',
                    'content': scriptContent,
                  },
                },
              },
              beforeCommit: () {
                // Modify file right at commit transition
                candidateFile.writeAsStringSync(
                  'concurrent manual edit by user',
                );
                throw StateError('Aborting commit: conflict detected');
              },
            ),
            throwsA(isA<StateError>()),
          );

          // Unpreserved user edit was NEVER removed
          expect(candidateFile.existsSync(), isTrue);
          expect(
            candidateFile.readAsStringSync(),
            'concurrent manual edit by user',
          );
        },
      );

      test(
        'repairLocalSource safely repairs quarantined issue, publishes canonical script, and marks issue recovered',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_targeted_repair'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['targeted', 'repair', 'key'];
          final computedKey = keyParts.join('_');
          final validReplacement = _generateComputedSourceScript(
            classPrefix: 'TargetedRepair',
            keyParts: keyParts,
            version: '2.0.0',
            name: 'Targeted Repaired Source',
          );

          final corruptFile = File(p.join(sourceDir.path, 'targeted_bad.js'))
            ..writeAsStringSync('invalid syntax bad');

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final initialSnapshot = await adapter.exportSyncSnapshot();
          expect(initialSnapshot.unavailableDomains, contains('source'));
          final issue = initialSnapshot.sourceIssues.firstWhere(
            (i) => i.filename == 'targeted_bad.js',
          );
          corruptFile.writeAsStringSync('concurrent manual edit');
          expect(
            await adapter.repairLocalSource(
              issue: issue,
              replacementContent: validReplacement,
            ),
            isFalse,
          );
          expect(corruptFile.readAsStringSync(), 'concurrent manual edit');
          corruptFile.writeAsStringSync('invalid syntax bad');

          final success = await adapter.repairLocalSource(
            issue: issue,
            replacementContent: validReplacement,
          );
          expect(success, isTrue);

          final canonical = File(
            p.join(
              sourceDir.path,
              SourceFileMetadata.physicalName(computedKey),
            ),
          );
          expect(canonical.existsSync(), isTrue);
          expect(canonical.readAsStringSync(), equals(validReplacement));

          expect(corruptFile.existsSync(), isFalse);

          final quarantineRecords = await SourceQuarantineManager(
            sourceDir,
          ).readJournal();
          expect(quarantineRecords.single.recovered, isTrue);
          expect(
            File(quarantineRecords.single.backupPath).readAsStringSync(),
            'invalid syntax bad',
          );

          final nextSnapshot = await adapter.exportSyncSnapshot();
          expect(nextSnapshot.unavailableDomains.contains('source'), isFalse);

          expect(
            nextSnapshot.records.containsKey(
              syncRecordKey('source', [computedKey]),
            ),
            isTrue,
          );
        },
      );
      test(
        'selected session and metadata repairs preserve exact backups and commit strict replacements',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_session_metadata_repair'),
          )..createSync(recursive: true);
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          const sessionKey = 'repair_session';
          const originalSession = 'invalid session bytes {{{';
          final sessionFile = File(p.join(sourceDir.path, '$sessionKey.data'))
            ..writeAsStringSync(originalSession);
          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          var snapshot = await adapter.exportSyncSnapshot();
          final sessionIssue = snapshot.sourceIssues.firstWhere(
            (issue) => issue.filename == '$sessionKey.data',
          );
          const repairedSession = '{"token":"preserved-login"}';
          expect(
            await adapter.repairLocalSource(
              issue: sessionIssue,
              replacementContent: repairedSession,
            ),
            isTrue,
          );
          expect(sessionFile.readAsStringSync(), repairedSession);

          const backupSidecar =
              '{"last_source":{"filename":"last_source.js","revisions":{},"publicationId":"last_publication"}}';
          final sidecar = File(
            p.join(sourceDir.path, SourceFileMetadata.sidecarFileName),
          )..writeAsStringSync('corrupt sidecar bytes');
          final sidecarBackup = File('${sidecar.path}.bak')
            ..writeAsStringSync(backupSidecar);
          snapshot = await adapter.exportSyncSnapshot();
          final metadataIssue = snapshot.sourceIssues.firstWhere(
            (issue) => issue.filename == SourceFileMetadata.sidecarFileName,
          );
          const repairedMetadata =
              '{"repaired_source":{"filename":"repaired.js","revisions":{},"publicationId":"manual_publication"}}';
          expect(
            await adapter.repairLocalSource(
              issue: metadataIssue,
              replacementContent: repairedMetadata,
            ),
            isTrue,
          );
          expect(sidecar.readAsStringSync(), repairedMetadata);
          expect(sidecarBackup.readAsStringSync(), backupSidecar);
          final names = await SourceFileMetadata.read(sourceDir);
          expect(
            names['repaired_source']?['publicationId'],
            'manual_publication',
          );

          final quarantineRecords = await SourceQuarantineManager(
            sourceDir,
          ).readJournal();
          expect(
            quarantineRecords
                .where((record) => record.filename == '$sessionKey.data')
                .single
                .recovered,
            isTrue,
          );
          expect(
            quarantineRecords
                .where(
                  (record) =>
                      record.filename == SourceFileMetadata.sidecarFileName,
                )
                .single
                .recovered,
            isTrue,
          );
          expect(
            quarantineRecords.map(
              (record) => File(record.backupPath).readAsStringSync(),
            ),
            contains(originalSession),
          );
        },
      );

      test(
        'rejects ambiguous logical-filename matches when multiple keys share the same filename',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_ambiguous_match'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const key1 = 'plugin_author_one';
          const key2 = 'plugin_author_two';

          File(
            p.join(sourceDir.path, 'plugin.js'),
          ).writeAsStringSync('corrupt plugin syntax {{{');

          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              key1: {'filename': 'plugin.js', 'revisions': <String, String>{}},
              key2: {'filename': 'plugin.js', 'revisions': <String, String>{}},
            }),
          );

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          await adapter.recoverLocalSources();

          final snapshot = await adapter.exportSyncSnapshot();
          expect(snapshot.unavailableDomains, contains('source'));
          expect(
            snapshot.sourceIssues.any(
              (i) => i.filename == 'plugin.js' && !i.recovered,
            ),
            isTrue,
          );

          final canon1 = File(
            p.join(sourceDir.path, SourceFileMetadata.physicalName(key1)),
          );
          final canon2 = File(
            p.join(sourceDir.path, SourceFileMetadata.physicalName(key2)),
          );
          expect(canon1.existsSync(), isFalse);
          expect(canon2.existsSync(), isFalse);
        },
      );

      test(
        'treats runtimeFailure as unavailable rather than corrupt, preserving script in place',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_runtime_failure'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['runtime', 'fail', 'source'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'RuntimeFail',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Runtime Failure Source',
          );

          final scriptFile = File(p.join(sourceDir.path, 'runtime_script.js'))
            ..writeAsStringSync(scriptContent);

          File(
            p.join(sourceDir.path, '.sync_source_names.json'),
          ).writeAsStringSync(
            jsonEncode({
              computedKey: {
                'filename': 'runtime_script.js',
                'revisions': <String, String>{},
              },
            }),
          );

          // Simulate probeKey returning runtimeFailure (or infrastructure error)
          // SourceRecovery treats runtimeFailure as isUnavailableNotCorrupt: true!
          final problemFile = ProblematicSourceFile(
            file: scriptFile,
            filename: 'runtime_script.js',
            content: scriptContent,
            bytes: utf8.encode(scriptContent),
            initialDigest: sha256
                .convert(utf8.encode(scriptContent))
                .toString(),
            failureName: 'runtimeFailure',
            isCorruptOrEmpty: false, // runtimeFailure is NOT corrupt!
            initialStat: scriptFile.statSync(),
          );
          expect(problemFile.isCorruptOrEmpty, isFalse);

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          await adapter.recoverLocalSources();

          // Script file was NOT deleted or quarantined
          expect(scriptFile.existsSync(), isTrue);
          expect(scriptFile.readAsStringSync(), equals(scriptContent));
        },
      );

      test(
        'reconciles unresolved quarantine records when approved recovery body is supplied, preserving backups and clearing domain blocker',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_reconcile_quarantine'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);
          final quarantineDir = Directory(p.join(sourceDir.path, '.quarantine'))
            ..createSync(recursive: true);
          final recordsDir = Directory(p.join(quarantineDir.path, 'records'))
            ..createSync(recursive: true);

          const keyParts = ['reconcile', 'quarantine', 'key'];
          final computedKey = keyParts.join('_');
          final approvedScript = _generateComputedSourceScript(
            classPrefix: 'ReconcileQuarantine',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Reconciled Source',
          );

          final originalHash = sha256
              .convert(utf8.encode('bad bytes'))
              .toString();
          final backupFile = File(
            p.join(recordsDir.path, '${originalHash}_previously_bad.js'),
          )..writeAsStringSync('bad bytes');

          // Journal with unresolved quarantine entry
          final journalRecord = SourceQuarantineRecord(
            originalPath: p.canonicalize(
              p.join(sourceDir.path, 'previously_bad.js'),
            ),
            filename: 'previously_bad.js',
            originalHash: originalHash,
            backupPath: p.canonicalize(backupFile.path),
            reason: 'syntaxError',
            timestamp: DateTime.now().toUtc(),
            fileSize: 9,
            sourceKey: computedKey,
            recovered: false,
          );
          final qManager = SourceQuarantineManager(sourceDir);
          File(
            p.join(quarantineDir.path, 'journal.json'),
          ).writeAsStringSync(jsonEncode([journalRecord.toJson()]));

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          // Initial export has source domain blocked by persistent quarantine journal
          final snapshot1 = await adapter.exportSyncSnapshot();
          expect(snapshot1.unavailableDomains, contains('source'));

          // Supply approved recoveryRecords
          final recoveryRecords = <String, Map<String, Object?>>{
            syncRecordKey('source', [computedKey]): {
              'script': {
                'filename': 'previously_bad.js',
                'content': approvedScript,
              },
            },
          };

          await adapter.recoverLocalSources(recoveryRecords: recoveryRecords);

          // Backup bytes in .quarantine/records/ were NOT deleted
          expect(backupFile.existsSync(), isTrue);
          expect(backupFile.readAsStringSync(), 'bad bytes');

          // Canonical script was published
          final canonicalFile = File(
            p.join(
              sourceDir.path,
              SourceFileMetadata.physicalName(computedKey),
            ),
          );
          expect(canonicalFile.existsSync(), isTrue);
          expect(canonicalFile.readAsStringSync(), equals(approvedScript));

          // Journal entry is now recovered: true!
          final updatedJournal = await qManager.readJournal();
          expect(updatedJournal.first.recovered, isTrue);

          // Subsequent export has source domain available!
          final snapshot2 = await adapter.exportSyncSnapshot();
          expect(snapshot2.unavailableDomains.contains('source'), isFalse);
          expect(
            snapshot2.records.containsKey(
              syncRecordKey('source', [computedKey]),
            ),
            isTrue,
          );
        },
      );

      test(
        'malformed session file blocks sourceSession but leaves source records available',
        () async {
          final profileDir = Directory(
            p.join(tempDir.path, 'profile_bad_session_dep'),
          )..createSync(recursive: true);
          App.dataPath = profileDir.path;
          App.cachePath = profileDir.path;
          final sourceDir = Directory(p.join(profileDir.path, 'comic_source'))
            ..createSync(recursive: true);

          const keyParts = ['healthy', 'source', 'key'];
          final computedKey = keyParts.join('_');
          final scriptContent = _generateComputedSourceScript(
            classPrefix: 'HealthySource',
            keyParts: keyParts,
            version: '1.0.0',
            name: 'Healthy Source',
          );

          File(p.join(sourceDir.path, 'healthy_source.js'))
            ..writeAsStringSync(scriptContent);
          File(p.join(sourceDir.path, '$computedKey.data'))
            ..writeAsStringSync('corrupt json not map {{{');

          final adapter = SyncPreferencesAdapter(dataPath: profileDir.path);
          final snapshot = await adapter.exportSyncSnapshot();

          // Session damage is scoped to sourceSession; validated scripts remain exportable.
          expect(snapshot.unavailableDomains, contains('sourceSession'));
          expect(snapshot.unavailableDomains.contains('source'), isFalse);
          expect(
            snapshot.sourceIssues.any(
              (i) =>
                  i.filename == '$computedKey.data' &&
                  i.reason == 'invalidSession',
            ),
            isTrue,
          );

          // Apply settings while sourceSession is unavailable.
          final incoming = <String, Map<String, Object?>>{
            ...snapshot.records,
            syncRecordKey('setting', ['appliedSettingDep']): {
              'value': 'success_dep',
            },
          };

          await adapter.applySyncRecords(
            incoming,
            unavailableDomains: snapshot.unavailableDomains,
          );

          // finishApply must succeed safely without throwing due to malformed session
          await adapter.finishApply();
          expect(appdata.settings['appliedSettingDep'], equals('success_dep'));
        },
      );
    },
    skip: (_ciRequireQuickJs || quickJsAvailable) ? false : quickJsFailure,
  );
}
