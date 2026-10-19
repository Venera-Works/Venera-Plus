import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_runtime/app_runtime.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_exit.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';

import '../../widget_test_io.dart';

class _History extends HistoryManager {
  _History() : super.create();

  final firstWrite = Completer<void>();
  final secondWrite = Completer<void>();
  final historySaved = Completer<void>();
  final durations = <Duration>[];
  final events = <String>[];
  int flushes = 0;
  Object? flushFailure;

  @override
  Future<void> addReadDuration(History item, Duration duration) async {
    durations.add(duration);
    final number = durations.length;
    events.add('duration-$number-start');
    await (number == 1 ? firstWrite.future : secondWrite.future);
    events.add('duration-$number-end');
  }

  @override
  Future<void> flushReadingProgress({String? id, ComicType? type}) async {
    flushes++;
    events.add('flush');
    if (flushFailure case final failure?) throw failure;
    await historySaved.future;
  }

  void release() {
    if (!firstWrite.isCompleted) firstWrite.complete();
    if (!secondWrite.isCompleted) secondWrite.complete();
    if (!historySaved.isCompleted) historySaved.complete();
  }
}

class _PersistedHistory extends HistoryManager {
  _PersistedHistory() : super.create();

  int flushes = 0;

  @override
  Future<void> flushReadingProgress({String? id, ComicType? type}) async {
    flushes++;
    await super.flushReadingProgress(id: id, type: type);
  }
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Reader extends Reader {
  _Reader({required super.key})
    : super(
        type: ComicType.local,
        cid: 'shutdown-book',
        name: 'Shutdown book',
        chapters: null,
        history: History.fromMap({
          'id': 'shutdown-book',
          'type': ComicType.local.value,
          'time': 1000,
          'title': 'Shutdown book',
          'ep': 1,
          'page': 1,
        }),
        author: '',
        tags: const [],
      );

  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  Duration elapsed = Duration.zero;
  late ReadingSessionTracker session;

  @override
  ReadingSessionTracker createReadingSessionTracker({
    Duration Function()? elapsedNow,
  }) => session = super.createReadingSessionTracker(elapsedNow: () => elapsed);

  @override
  void setImageCacheSize() {}

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryManager? previousHistory;
  late LocalFavoritesManager? previousFavorites;
  late Map<String, dynamic> previousSettings;
  late _History histories;

  setUp(() {
    previousHistory = HistoryManager.cache;
    previousFavorites = LocalFavoritesManager.cache;
    previousSettings =
        jsonDecode(jsonEncode(appdata.toJson()['settings']))
            as Map<String, dynamic>;
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['webdav'] = <String>[];
    appdata.settings['enableTurnPageByVolumeKey'] = false;
    appdata.implicitData['webdavAutoSync'] = false;
    appdata.implicitData['webdavSyncMode'] = 'manual';
    LocalFavoritesManager.cache = _Favorites();
    histories = _History();
    HistoryManager.cache = histories;
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    Log.isMuted = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
    configureAppExitPreparation(prepareReadingDataForExit);
  });

  tearDown(() async {
    histories.release();
    await ReadingSessionTracker.finishAll().catchError((Object _) {});
    ReadingSessionTracker.debugResetForTesting();
    configureAppExitPreparation(null);
    debugExitProcess = null;
    DataSync.resetForTesting();
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    Log.clear();
    Log.isMuted = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets(
    'Reader pop then rapid close drains both session periods before history and exit',
    (tester) async {
      // setUp runs outside testWidgets' fakeAsync zone. Create the gates here
      // so completing a writer can be drained by tester.pump().
      histories = _History();
      HistoryManager.cache = histories;
      var exits = 0;
      debugExitProcess = (_) => exits++;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (_, child) => WindowFrame(child!),
          home: const SizedBox.shrink(),
        ),
      );
      addTearDown(() async {
        histories.release();
        await tester.pumpWidget(const SizedBox.shrink());
      });
      final key = GlobalKey<_ReaderState>();
      unawaited(
        App.rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => _Reader(key: key)),
        ),
      );
      await tester.pumpAndSettle();
      final reader = key.currentState!;
      reader.onReaderContentReady();
      reader.elapsed = const Duration(seconds: 10);
      final checkpoint = reader.session.checkpoint();
      await tester.pump();
      expect(histories.durations, const [Duration(seconds: 10)]);
      reader.elapsed = const Duration(seconds: 15);
      expect(reader.session.isRunning, isTrue);

      await tester.tap(find.byType(WindowButton).last);
      await tester.pumpAndSettle();
      expect(key.currentState, isNull);
      expect(reader.session.isRunning, isFalse);
      expect(exits, 0);
      expect(histories.flushes, 0);
      await tester.tap(find.byType(WindowButton).last);
      await tester.tap(find.byType(WindowButton).last);
      expect(exits, 0);
      expect(histories.durations, const [Duration(seconds: 10)]);
      expect(histories.flushes, 0);
      final closing = exitApp();

      histories.firstWrite.complete();
      await tester.pump();
      expect(histories.durations, const [
        Duration(seconds: 10),
        Duration(seconds: 5),
      ]);
      expect(histories.flushes, 0);
      expect(exits, 0);
      histories.secondWrite.complete();
      await tester.pump();
      expect(histories.events.take(4), [
        'duration-1-start',
        'duration-1-end',
        'duration-2-start',
        'duration-2-end',
      ]);
      expect(histories.flushes, greaterThan(0));
      expect(exits, 0);
      histories.historySaved.complete();
      await runWidgetIo(tester, () async {
        await Future.wait([checkpoint, closing]);
      });
      await tester.pump();
      expect(exits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'runtime exit persists both queued duration periods and the final page',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'reader-exit-history-',
      );
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      final manager = _PersistedHistory();
      HistoryManager.cache = manager;
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final firstWrite = Completer<void>();
      final secondWrite = Completer<void>();
      final durations = <Duration>[];
      Future<void>? closing;
      addTearDown(() async {
        if (!firstWrite.isCompleted) firstWrite.complete();
        if (!secondWrite.isCompleted) secondWrite.complete();
        if (closing != null) await closing;
        await ReadingSessionTracker.finishAll();
        await manager.flushReadingProgress();
        manager.close();
        await directory.delete(recursive: true);
      });
      await manager.init();
      final item = History.fromMap({
        'id': 'persisted-exit',
        'type': ComicType.local.value,
        'time': 1000,
        'title': 'Persisted exit',
        'ep': 1,
        'page': 2,
      });
      manager.addHistory(item);
      var elapsed = Duration.zero;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          durations.add(duration);
          if (durations.length == 1) {
            firstStarted.complete();
            await firstWrite.future;
          } else {
            secondStarted.complete();
            await secondWrite.future;
          }
          await manager.addReadDuration(item, duration);
        },
      );
      var exits = 0;
      debugExitProcess = (_) => exits++;
      tracker.start();
      elapsed = const Duration(seconds: 10);
      final checkpoint = tracker.checkpoint();
      await firstStarted.future;
      elapsed = const Duration(seconds: 15);
      final disposing = tracker.dispose();
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 9),
        source: ReadingNavigationSource.automatic,
      );
      final shutdown = exitApp();
      closing = shutdown;
      expect(manager.flushes, 0);
      expect(exits, 0);
      firstWrite.complete();
      await secondStarted.future;
      expect(durations, const [Duration(seconds: 10), Duration(seconds: 5)]);
      expect(exits, 0);
      secondWrite.complete();
      await Future.wait([checkpoint, disposing, shutdown]);
      expect(exits, 1);
      expect(manager.flushes, greaterThan(0));
      final saved = manager.getAll().single;
      expect(saved.readDurationMs, 15000);
      expect(saved.resumePosition?.page, 9);
    },
  );

  test(
    'runtime preparation refuses a failed duration without retrying it',
    () async {
      var elapsed = Duration.zero;
      var writes = 0;
      var exits = 0;
      final failure = StateError('duration failed');
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (_) async {
          writes++;
          throw failure;
        },
      );
      debugExitProcess = (_) => exits++;
      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.checkpoint();
      await expectLater(exitApp(), throwsA(same(failure)));
      await expectLater(exitApp(), throwsA(same(failure)));
      expect(writes, 1);
      expect(histories.flushes, 0);
      expect(exits, 0);
    },
  );

  test(
    'runtime preparation propagates history failure and releases exit for another request',
    () async {
      var exits = 0;
      debugExitProcess = (_) => exits++;
      final failure = StateError('history failed');
      histories.flushFailure = failure;
      await expectLater(exitApp(), throwsA(same(failure)));
      expect(exits, 0);
      histories.flushFailure = null;
      histories.historySaved.complete();
      await exitApp();
      expect(histories.flushes, 2);
      expect(exits, 1);
    },
  );
}
