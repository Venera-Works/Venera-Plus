import 'dart:async';

import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';

const config = ['https://example.com/dav/VeneraPlus', 'user', 'password'];

void main() {
  void scheduleTest(
    String name,
    Future<void> Function(_ScheduleClock, _Calls) body,
  ) {
    test(name, () async {
      final clock = _ScheduleClock();
      final directory = Directory.systemTemp.createTempSync('sync-schedule-');
      var oldPath = Directory.systemTemp.path;
      try {
        oldPath = App.dataPath;
      } catch (_) {}
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'],
      );
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      final oldMuted = Log.isMuted;
      _ScheduleDavClient.readDirCalls = 0;
      DataSync.resetForTesting();
      DataSync.debugDisableWindowCloseHandler = true;
      DataSync.debugNow = clock.now;
      DataSync.debugExportRecords = () async => {};
      DataSync.debugApplyRecords = (records, {beforeCommit}) async {
        beforeCommit?.call();
      };
      DataSync.debugClientFactory = (_) => _ScheduleDavClient();
      App.dataPath = directory.path;
      Log.isMuted = true;
      appdata.settings['webdav'] = config;
      appdata.implicitData
        ..clear()
        ..addAll({
          'webdavSyncDirection': 'uploadOnly',
          'webdavSyncTiming': 'scheduled',
          'webdavSyncLastAttempt': clock.now().millisecondsSinceEpoch,
        });
      final calls = _Calls()..install();
      DataSync.debugExportRecords = () async => cloneSyncRecords(calls.records);
      try {
        await runZoned(
          () async {
            await DataSync().waitForStartupMerge();
            await body(clock, calls);
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration == Duration.zero) {
                return parent.createTimer(zone, duration, callback);
              }
              return clock.createTimer(duration, zone.bindCallback(callback));
            },
          ),
        );
      } finally {
        if (DataSync.instance != null) await DataSync.instance!.waitForSync();
        DataSync.resetForTesting();
        // Flush earlier dirty writes before restoring process-global paths.
        await appdata.writeImplicitData();
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        (appdata.toJson()['settings'] as Map)
          ..clear()
          ..addAll(previousSettings);
        App.dataPath = oldPath;
        directory.deleteSync(recursive: true);
        Log.clear();
        Log.isMuted = oldMuted;
      }
    });
  }

  scheduleTest(
    'scheduled changes wait for due time and resume preserves interval',
    (clock, calls) async {
      final sync = DataSync();
      for (var i = 0; i < 10; i++) {
        calls.edit(sync);
      }
      await clock.elapse(const Duration(minutes: 29));
      sync.checkForAutomaticSync();
      expect(calls.uploads, 0);
      await clock.elapse(const Duration(minutes: 1));
      await sync.waitForSync();
      expect(calls.uploads, 1);
      expect(sync.hasPendingChanges, isFalse);
      await clock.elapse(const Duration(minutes: 30));
      await sync.waitForSync();
      expect(calls.uploads, 2);
      expect(calls.downloads, 0);
    },
  );

  scheduleTest('manual bypasses throttling; realtime reacts to local edits', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncTiming'] = 'manual';
    final sync = DataSync()..onDataChanged();
    await clock.elapse(const Duration(hours: 2));
    expect(calls.uploads, 0);
    await sync.syncNow();
    expect(calls.uploads, 1);
    await sync.syncNow();
    expect(calls.uploads, 2);
    appdata.implicitData['webdavSyncTiming'] = 'realtime';
    calls.edit(sync);
    await clock.elapse(const Duration(minutes: 2));
    await sync.waitForSync();
    expect(calls.uploads, 3);
  });
  scheduleTest(
    'a local notification with no captured records does not sync remotely',
    (clock, calls) async {
      appdata.implicitData['webdavSyncTiming'] = 'realtime';
      appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
      DataSync.debugUploadOverride = null;
      final sync = DataSync();
      await sync.waitForStartupMerge();
      final remoteDiscoveryCount = _ScheduleDavClient.readDirCalls;
      final lastAttempt = sync.statusSnapshot.lastSyncTime;
      final lastSuccess = sync.statusSnapshot.lastSuccessTime;

      sync.onDataChanged(domains: const {'setting'});
      await clock.elapse(const Duration(minutes: 3));
      await sync.waitForSync();

      expect(sync.hasPendingChanges, isFalse);
      expect(sync.statusSnapshot.lastSyncTime, lastAttempt);
      expect(sync.statusSnapshot.lastSuccessTime, lastSuccess);
      expect(_ScheduleDavClient.readDirCalls, remoteDiscoveryCount);
    },
  );

  scheduleTest('realtime changes coalesce and sustained edits still publish', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncTiming'] = 'realtime';
    appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
    DataSync.debugUploadOverride = null;
    final sync = DataSync();
    await sync.waitForStartupMerge();
    await sync.waitForSync();
    calls.install();

    for (var i = 0; i < 8; i++) {
      calls.edit(sync);
    }
    await clock.elapse(const Duration(minutes: 3));
    await sync.waitForSync();
    expect(calls.uploads, 1);

    for (var i = 0; i < 40; i++) {
      calls.edit(sync);
      await clock.elapse(const Duration(seconds: 5));
    }
    // 持续编辑期间，至少发生一次额外同步
    await sync.waitForSync();
    expect(calls.uploads, greaterThanOrEqualTo(2));
    // 停止编辑后，等待 10 秒防抖期结束
    await clock.elapse(const Duration(seconds: 10));
    await sync.waitForSync();

    // 包含最初的上传，总计应至少上传 3 次
    expect(calls.uploads, greaterThanOrEqualTo(3));
  });
  scheduleTest(
    'changes made during upload remain pending for the next capture',
    (clock, calls) async {
      appdata.implicitData['webdavSyncTiming'] = 'realtime';
      appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
      final firstUpload = Completer<Res<bool>>();
      final started = Completer<void>();
      DataSync.debugUploadOverride = () {
        calls.uploads++;
        if (calls.uploads == 1) started.complete();
        return calls.publish(
          calls.uploads == 1
              ? firstUpload.future
              : Future.value(const Res(true)),
        );
      };
      final sync = DataSync();
      await sync.waitForStartupMerge();
      calls.edit(sync);
      await clock.elapse(const Duration(minutes: 3));
      await started.future;
      expect(calls.uploads, 1);

      calls.edit(sync);
      firstUpload.complete(const Res(true));
      await sync.waitForSync();
      expect(sync.hasPendingChanges, isTrue);

      await clock.elapse(const Duration(seconds: 30));
      expect(calls.uploads, 1);
      await clock.elapse(const Duration(minutes: 2));
      await sync.waitForSync();
      expect(calls.uploads, 2);
      expect(sync.hasPendingChanges, isFalse);
    },
  );

  scheduleTest(
    'realtime failures back off and authentication stops automatic retries',
    (clock, calls) async {
      appdata.implicitData['webdavSyncTiming'] = 'manual';
      appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
      var failWithAuth = false;
      DataSync.debugUploadOverride = () async {
        calls.uploads++;
        if (failWithAuth) {
          throw StateError('HTTP 401 Unauthorized');
        }
        if (calls.uploads == 1) {
          throw StateError('temporary network failure');
        }
        return calls.publish(Future.value(const Res(true)));
      };
      final sync = DataSync();
      await sync.waitForStartupMerge();
      final lastSuccess = sync.statusSnapshot.lastSuccessTime;
      appdata.implicitData['webdavSyncTiming'] = 'realtime';
      calls.edit(sync);
      await clock.elapse(const Duration(minutes: 3));
      expect((await sync.waitForSync()).error, isTrue);
      expect(calls.uploads, 1);
      expect(sync.statusSnapshot.lastSuccessTime, lastSuccess);
      expect(
        sync.statusSnapshot.lastSyncTime,
        clock.now().millisecondsSinceEpoch,
      );

      calls.edit(sync);
      await clock.elapse(const Duration(seconds: 30));
      expect(calls.uploads, 1);
      await clock.elapse(const Duration(minutes: 2));
      await sync.waitForSync();
      expect(calls.uploads, 2);

      failWithAuth = true;
      calls.edit(sync);
      await clock.elapse(const Duration(minutes: 3));
      expect((await sync.waitForSync()).error, isTrue);
      expect(calls.uploads, 3);
      calls.edit(sync);
      await clock.elapse(const Duration(hours: 2));
      expect(calls.uploads, 3);
    },
  );

  scheduleTest('downloadOnly scheduling never uploads dirty local changes', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';
    final sync = DataSync()..onDataChanged();
    await clock.elapse(const Duration(minutes: 30));
    await sync.waitForSync();
    expect(calls.uploads, 0);
    expect(calls.downloads, 1);
    expect((await sync.uploadData()).error, isTrue);
  });

  scheduleTest('failure stays dirty and waits until next interval', (
    clock,
    calls,
  ) async {
    DataSync.debugUploadOverride = () async {
      calls.uploads++;
      throw StateError('network failed');
    };
    final sync = DataSync()..onDataChanged();
    await clock.elapse(const Duration(minutes: 30));
    expect((await sync.waitForSync()).error, isTrue);
    expect(sync.hasPendingChanges, isTrue);
    expect(calls.uploads, 1);
    sync.checkForAutomaticSync();
    await clock.elapse(const Duration(minutes: 29));
    expect(calls.uploads, 1);
    calls.install();
    await clock.elapse(const Duration(minutes: 1));
    await sync.waitForSync();
    expect(calls.uploads, 2);
  });

  scheduleTest(
    'manual configuration cancels timers; scheduled confirmation reschedules',
    (clock, calls) async {
      appdata.implicitData[appdataSyncExcludedDomainsKey] = ['search'];
      final sync = DataSync();
      final invalidScope = await sync.configure(
        config: config,
        excludedFields: '',
        direction: SyncDirection.uploadOnly,
        timing: SyncTiming.manual,
        minutes: 15,
        excludedDomains: const {'not-a-domain'},
      );
      expect(invalidScope.error, isTrue);
      expect(appdata.implicitData[appdataSyncExcludedDomainsKey], ['search']);

      expect(
        (await sync.configure(
          config: config,
          excludedFields: '',
          direction: SyncDirection.uploadOnly,
          timing: SyncTiming.manual,
          minutes: 15,
          excludedDomains: const {'historyChapter'},
        )).success,
        isTrue,
      );
      expect(appdata.implicitData[appdataSyncExcludedDomainsKey], [
        'history',
        'historyChapter',
      ]);
      await clock.elapse(const Duration(hours: 1));
      expect(calls.uploads, 0);
      expect(
        (await sync.configure(
          config: config,
          excludedFields: '',
          direction: SyncDirection.uploadOnly,
          timing: SyncTiming.scheduled,
          minutes: 15,
          excludedDomains: null,
        )).success,
        isTrue,
      );
      expect(appdata.implicitData[appdataSyncExcludedDomainsKey], [
        'history',
        'historyChapter',
      ]);
      // Saved configuration queues a separate transfer. Finish that task (and
      // its disk writes) before advancing the fake wall clock.
      await sync.waitForSync();
      expect(calls.uploads, 1);
      await clock.elapse(const Duration(minutes: 14));
      expect(calls.uploads, 1);
      await clock.elapse(const Duration(minutes: 1));
      await sync.waitForSync();
      expect(calls.uploads, 2);
    },
  );

  scheduleTest('future timestamps recover and dispose cancels timers', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncLastAttempt'] = clock
        .now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch;
    final sync = DataSync();
    // The shared fixture has already completed startup. Re-evaluate the changed
    // persisted timestamp through the same resume/startup scheduler entrypoint.
    sync.checkForAutomaticSync();
    await sync.waitForSync();
    expect(calls.uploads, 1);
    sync.dispose();
    DataSync.instance = null;
    await clock.elapse(const Duration(hours: 2));
    expect(calls.uploads, 1);
  });
}

class _ScheduleClock {
  DateTime current = DateTime(2026, 9, 27);
  final timers = <_ScheduledTimer>[];
  DateTime now() => current;

  Timer createTimer(Duration duration, void Function() callback) {
    final timer = _ScheduledTimer(current.add(duration), callback);
    timers.add(timer);
    return timer;
  }

  Future<void> elapse([Duration duration = Duration.zero]) async {
    current = current.add(duration);
    for (final timer in timers.toList()) {
      if (timer.isActive && !timer.due.isAfter(current)) timer.fire();
    }
    await pumpEventQueue();
  }
}

class _ScheduledTimer implements Timer {
  _ScheduledTimer(this.due, this.callback);
  final DateTime due;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    isActive = false;
    tick++;
    callback();
  }
}

class _Calls {
  int uploads = 0;
  int downloads = 0;
  final SyncRecords records = {};
  int _revision = 0;

  void edit(DataSync sync) {
    records[syncRecordKey('setting', ['testPreference'])] = {
      'value': ++_revision,
    };
    sync.onDataChanged(domains: {'setting'});
  }

  Future<Res<bool>> publish(Future<Res<bool>> completion) async {
    final store = DataSync().coordinator!.store;
    final pending = store.pendingBatchIds;
    final result = await completion;
    if (result.success) {
      for (final id in pending) {
        await store.acknowledge(id);
      }
    }
    return result;
  }

  void install() {
    DataSync.debugUploadOverride = () async {
      uploads++;
      return publish(Future.value(const Res(true)));
    };
    DataSync.debugDownloadOverride = () async {
      downloads++;
      return const Res(true);
    };
  }
}

class _ScheduleDavClient extends dav.Client {
  static int readDirCalls = 0;

  _ScheduleDavClient()
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(),
        auth: dav.Auth(user: 'user', pwd: 'password'),
      );

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    readDirCalls++;
    return const [];
  }

  @override
  Future<void> ping([CancelToken? cancelToken]) async {}
}
