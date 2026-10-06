import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
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
      DataSync.resetForTesting();
      DataSync.debugDisableWindowCloseHandler = true;
      DataSync.debugNow = clock.now;
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
      try {
        await runZoned(
          () => body(clock, calls),
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
        sync.onDataChanged();
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

  scheduleTest('manual is idle; realtime reacts to local edits', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncTiming'] = 'manual';
    final sync = DataSync()..onDataChanged();
    await clock.elapse(const Duration(hours: 2));
    expect(calls.uploads, 0);
    await sync.syncNow();
    expect(calls.uploads, 1);
    appdata.implicitData['webdavSyncTiming'] = 'realtime';
    sync.onDataChanged();
    await sync.waitForSync();
    expect(calls.uploads, 2);
  });

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
      final sync = DataSync();
      expect(
        (await sync.configure(
          config: config,
          excludedFields: '',
          direction: SyncDirection.uploadOnly,
          timing: SyncTiming.manual,
          minutes: 15,
          initialUpload: true,
        )).success,
        isTrue,
      );
      await clock.elapse(const Duration(hours: 1));
      expect(calls.uploads, 0);
      expect(
        (await sync.configure(
          config: config,
          excludedFields: '',
          direction: SyncDirection.uploadOnly,
          timing: SyncTiming.scheduled,
          minutes: 15,
          initialUpload: true,
        )).success,
        isTrue,
      );
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
  void install() {
    DataSync.debugUploadOverride = () async {
      uploads++;
      return const Res(true);
    };
    DataSync.debugDownloadOverride = () async {
      downloads++;
      return const Res(true);
    };
  }
}
