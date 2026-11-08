import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/follow_updates/follow_update_queue.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/network/request_scope.dart';

void main() {
  group('Follow updates', () {
    const sourceKey = 'follow_updates_test_source';

    setUp(() {
      Log.isMuted = true;
    });

    tearDown(() {
      Log.isMuted = false;
      ComicSourceManager().remove(sourceKey);
    });

    for (final throwsError in [false, true]) {
      test(
        'updateComic does not repeat a failed source load ($throwsError)',
        () async {
          var attempts = 0;
          final source = _source(
            sourceKey,
            loadComicInfo: (id) async {
              attempts++;
              if (throwsError) throw 'network unavailable';
              return const Res.error('network unavailable');
            },
          );
          ComicSourceManager().add(source);

          final item = FavoriteItemWithUpdateInfo(
            FavoriteItem(
              id: 'comic-1',
              name: 'Comic 1',
              coverPath: 'cover.jpg',
              author: 'Author',
              type: ComicType.fromKey(sourceKey),
              tags: const [],
            ),
            null,
            false,
            null,
          );

          final result = await updateComic(item, 'folder');

          expect(result.updated, isFalse);
          expect(result.errorMessage, contains('network unavailable'));
          expect(attempts, 1);
        },
      );
    }

    test(
      'updateComic for local comic returns immediately without network request',
      () async {
        final localItem = FavoriteItemWithUpdateInfo(
          FavoriteItem(
            id: 'local-1',
            name: 'Local Comic',
            coverPath: 'cover.jpg',
            author: 'Author',
            type: ComicType.local,
            tags: const [],
          ),
          null,
          false,
          null,
        );

        final result = await updateComic(localItem, 'folder');
        expect(result.updated, isFalse);
        expect(result.errorMessage, isNull);
      },
    );

    test(
      'updateComic for missing source returns immediately without retrying',
      () async {
        final missingSourceItem = FavoriteItemWithUpdateInfo(
          FavoriteItem(
            id: 'comic-missing',
            name: 'Missing Source Comic',
            coverPath: 'cover.jpg',
            author: 'Author',
            type: ComicType.fromKey('non_existent_source'),
            tags: const [],
          ),
          null,
          false,
          null,
        );

        final result = await updateComic(missingSourceItem, 'folder');
        expect(result.updated, isFalse);
        expect(result.errorMessage, contains('Comic source not found'));
      },
    );

    group(
      'real scoped metadata refresh',
      () {
        test(
          'overlapping consumers fetch once and apply fresh metadata to all memberships',
          () async {
            final response = Completer<Res<ComicDetails>>();
            final started = Completer<void>();
            var calls = 0;
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) {
                  calls++;
                  started.complete();
                  return response.future;
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'shared');
              manager.createFolder('other');
              manager.addComic('在读', item, null, _oldSnapshot);
              manager.addComic('other', item, null, _oldSnapshot);
              final first = updateComic(item, '在读');
              await started.future;
              final second = updateComic(item, 'other');
              final remote = refreshComic(item.id, item.type);
              response.complete(Res(_details(sourceKey, item.id)));
              final results = await Future.wait([first, second, remote]);
              expect(calls, 1);
              expect(
                results.every((result) => result.errorMessage == null),
                isTrue,
              );
              for (final folder in manager.folderNames) {
                final stored = manager.getComicWithUpdatesInfo(
                  folder,
                  item.id,
                  item.type,
                );
                expect(stored.name, 'Fresh title');
                expect(stored.coverPath, 'fresh.jpg');
                expect(stored.updateTime, _newTime);
                expect(stored.hasNewUpdate, isTrue);
              }
            });
          },
        );

        test(
          'folder refresh excludes other folders and local comics and notifies unchanged metadata',
          () async {
            final requested = <String>[];
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async {
                  requested.add(id);
                  return Res(_details(sourceKey, id, updateTime: _oldTime));
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              manager.createFolder('other');
              final item = _tracked(sourceKey, 'inside');
              manager.addComic('在读', item, null, _oldSnapshot);
              manager.addComic(
                'other',
                _tracked(sourceKey, 'outside'),
                null,
                _oldSnapshot,
              );
              manager.addComic('在读', _tracked('local', 'local'));
              await manager.waitForPendingReads();
              var notifications = 0;
              void listener() => notifications++;
              manager.addListener(listener);
              try {
                final progress = await updateFolder('在读', true).toList();
                expect(requested, ['inside']);
                expect(progress.last.errors, 0);
                expect(progress.last.updated, 0);
                expect(notifications, greaterThan(0));
                expect(
                  manager.getComic('在读', item.id, item.type).name,
                  'Fresh title',
                );
                expect(
                  manager.getComic('other', 'outside', item.type).name,
                  'Old title',
                );
              } finally {
                manager.removeListener(listener);
              }
            });
          },
        );

        test(
          'mixed folder refresh starts other sources while the first source is pending',
          () async {
            const otherSourceKey = 'follow_updates_test_other_source';
            final slowResponse = Completer<void>();
            final otherStarted = Completer<void>();
            final requested = <(String, String)>[];
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async {
                  requested.add((sourceKey, id));
                  await slowResponse.future;
                  return Res(_details(sourceKey, id));
                },
              ),
            );
            ComicSourceManager().add(
              _source(
                otherSourceKey,
                loadComicInfo: (id) async {
                  requested.add((otherSourceKey, id));
                  otherStarted.complete();
                  return Res(_details(otherSourceKey, id));
                },
              ),
            );
            addTearDown(() => ComicSourceManager().remove(otherSourceKey));
            await _withLiveFavorites((manager) async {
              for (var index = 0; index < 5; index++) {
                manager.addComic(
                  '在读',
                  _tracked(sourceKey, 'slow-$index'),
                  null,
                  _oldSnapshot,
                );
              }
              manager.addComic(
                '在读',
                _tracked(otherSourceKey, 'other'),
                null,
                _oldSnapshot,
              );
              final refreshing = updateFolder('在读', true).toList();
              try {
                await otherStarted.future.timeout(const Duration(seconds: 3));
                expect(requested, contains((otherSourceKey, 'other')));
              } finally {
                slowResponse.complete();
                await refreshing;
              }
              final progress = await refreshing;
              expect(requested, hasLength(6));
              expect(progress.last.current, 6);
              expect(progress.last.updated, 6);
              expect(progress.last.errors, 0);
              expect(isFolderUpdating('在读'), isFalse);
            });
          },
        );

        test(
          'all-folder refresh deduplicates identities and equivalent subscriptions complete',
          () async {
            var calls = 0;
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async {
                  calls++;
                  return Res(_details(sourceKey, id));
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              manager.createFolder('other');
              final item = _tracked(sourceKey, 'shared');
              manager.addComic('在读', item, null, _oldSnapshot);
              manager.addComic('other', item, null, _oldSnapshot);
              final first = updateFolder(localAllFolderLabel, true).toList();
              final second = updateFolder(localAllFolderLabel, true).toList();
              final results = await Future.wait([first, second]);
              expect(calls, 1);
              expect(
                results.every((progress) => progress.last.current == 1),
                isTrue,
              );
              expect(isFolderUpdating(localAllFolderLabel), isFalse);
            });
          },
        );

        test(
          'late scope subscribers receive cumulative progress and share remaining work',
          () async {
            final pendingResponse = Completer<Res<ComicDetails>>();
            var calls = 0;
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async {
                  calls++;
                  if (id == 'pending') return pendingResponse.future;
                  return Res(_details(sourceKey, id));
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              manager.addComic(
                '在读',
                _tracked(sourceKey, 'first'),
                null,
                _oldSnapshot,
              );
              manager.addComic(
                '在读',
                _tracked(sourceKey, 'pending'),
                null,
                _oldSnapshot,
              );
              final firstCompleted = Completer<void>();
              final allCompleted = Completer<void>();
              final subscription = updateFolder('在读', true).listen(
                (progress) {
                  if (progress.current == 1 && !firstCompleted.isCompleted) {
                    firstCompleted.complete();
                  }
                },
                onError: allCompleted.completeError,
                onDone: allCompleted.complete,
              );
              try {
                await firstCompleted.future;
                final joined = updateFolder('在读', true).toList();
                pendingResponse.complete(Res(_details(sourceKey, 'pending')));
                final progress = await joined;
                await allCompleted.future;
                expect(calls, 2);
                expect(progress.first.current, 1);
                expect(progress.last.current, 2);
                expect(progress.last.updated, 2);
              } finally {
                await subscription.cancel();
              }
            });
          },
        );

        test(
          'reading during pending request does not suppress later discovered updates',
          () async {
            final response = Completer<Res<ComicDetails>>();
            final started = Completer<void>();
            var loaderCall = 0;
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) {
                  loaderCall++;
                  if (loaderCall == 1) {
                    started.complete();
                    return response.future;
                  }
                  return Future.value(
                    Res(_details(sourceKey, id, updateTime: _laterTime)),
                  );
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'read-race');
              manager.addComic('在读', item, null, _oldSnapshot);
              final pending = updateComic(item, '在读');
              await started.future;
              manager.markAsRead(item.id, item.type);
              response.complete(Res(_details(sourceKey, item.id)));
              final result = await pending;
              expect(result.updated, isTrue);
              expect(result.status, ComicUpdateCheckStatus.updated);
              expect(
                manager
                    .getComicWithUpdatesInfo('在读', item.id, item.type)
                    .updateTime,
                _newTime,
              );
              expect(manager.hasNewUpdate(item.id, item.type), isTrue);
              manager.markAsRead(item.id, item.type);
              expect(manager.hasNewUpdate(item.id, item.type), isFalse);
              final secondResult = await refreshComic(item.id, item.type);
              expect(secondResult.updated, isTrue);
              expect(secondResult.status, ComicUpdateCheckStatus.updated);
              expect(manager.hasNewUpdate(item.id, item.type), isTrue);
            });
          },
        );

        test('rename and database replacement reject late writes', () async {
          for (final replaceDatabase in [false, true]) {
            final response = Completer<Res<ComicDetails>>();
            final started = Completer<void>();
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) {
                  started.complete();
                  return response.future;
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'stale');
              manager.addComic('在读', item, null, _oldSnapshot);
              final pending = updateComic(item, '在读');
              await started.future;
              if (replaceDatabase) {
                await manager.waitForPendingReads();
                manager.close();
                await manager.init();
              } else {
                manager.rename('在读', 'renamed');
              }
              response.complete(Res(_details(sourceKey, item.id)));
              expect((await pending).errorMessage, isNotNull);
              expect(
                manager
                    .getComic(manager.readingFolder!, item.id, item.type)
                    .name,
                'Old title',
              );
            });
            ComicSourceManager().remove(sourceKey);
          }
        });

        test(
          'network-only metadata never inserts into local favorites and persists state',
          () async {
            var remoteTime = _newTime;
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async =>
                    Res(_details(sourceKey, id, updateTime: remoteTime)),
              ),
            );
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'remote-only');
              final result = await refreshComic(item.id, item.type);
              expect(result.item?.name, 'Fresh title');
              expect(result.updateTime, _newTime);
              expect(result.status, ComicUpdateCheckStatus.baseline);
              expect(manager.find(item.id, item.type), isEmpty);
              expect(manager.count('在读'), 0);
              expect(manager.hasNewUpdate(item.id, item.type), isFalse);
              expect(manager.getUpdateCheckTime(item.id, item.type), isNotNull);
              remoteTime = _laterTime;
              final updated = await refreshComic(item.id, item.type);
              expect(updated.status, ComicUpdateCheckStatus.updated);
              expect(manager.hasNewUpdate(item.id, item.type), isTrue);
              expect(manager.find(item.id, item.type), isEmpty);
            });
          },
        );

        test(
          'refresh distinguishes baseline, unknown, unchanged and updated with progress counters',
          () async {
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async {
                  if (id == 'baseline-item') {
                    return Res(
                      ComicDetails.fromJson({
                        'sourceKey': sourceKey,
                        'comicId': id,
                        'title': 'Baseline Comic',
                        'cover': 'cover.jpg',
                        'tags': <String, List<String>>{},
                        'chapters': {'ch1': 'Chapter 1'},
                      }),
                    );
                  }
                  if (id == 'unknown-item') {
                    return Res(
                      ComicDetails.fromJson({
                        'sourceKey': sourceKey,
                        'comicId': id,
                        'title': 'Unknown Comic',
                        'cover': 'cover.jpg',
                        'tags': <String, List<String>>{},
                      }),
                    );
                  }
                  return Res(_details(sourceKey, id));
                },
              ),
            );
            await _withLiveFavorites((manager) async {
              final baselineItem = FavoriteItem(
                id: 'baseline-item',
                name: 'Baseline Comic',
                coverPath: 'cover.jpg',
                author: 'Author',
                type: ComicType.fromKey(sourceKey),
                tags: const [],
              );
              final baselineRes = await refreshComic(
                baselineItem.id,
                baselineItem.type,
              );
              expect(baselineRes.status, ComicUpdateCheckStatus.baseline);
              expect(baselineRes.updated, isFalse);

              final unknownItem = FavoriteItem(
                id: 'unknown-item',
                name: 'Unknown Comic',
                coverPath: 'cover.jpg',
                author: 'Author',
                type: ComicType.fromKey(sourceKey),
                tags: const [],
              );
              final unknownRes = await refreshComic(
                unknownItem.id,
                unknownItem.type,
              );
              expect(unknownRes.status, ComicUpdateCheckStatus.unknown);
              expect(unknownRes.updated, isFalse);

              final unchangedRes = await refreshComic(
                baselineItem.id,
                baselineItem.type,
              );
              expect(unchangedRes.status, ComicUpdateCheckStatus.unchanged);
              expect(unchangedRes.updated, isFalse);
            });
          },
        );

        test(
          'refresh detects unpadded dates after the new catalog was already recorded',
          () async {
            final chapters = {'chapter-13': '13', 'chapter-14': '14'};
            ComicSourceManager().add(
              _source(
                sourceKey,
                loadComicInfo: (id) async => Res(
                  ComicDetails.fromJson({
                    ..._details(
                      sourceKey,
                      id,
                      updateTime: '2026-11-4',
                    ).toJson(),
                    'chapters': chapters,
                  }),
                ),
              ),
            );
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'unpadded-date');
              manager.addComic(
                '在读',
                item,
                null,
                ComicUpdateSnapshot.fromChapters(
                  chapters,
                  updateTime: '2026-9-16',
                ),
              );

              final progress = (await updateFolder('在读', true).toList()).last;
              expect(progress.errors, 0);
              expect(progress.updated, 1);
              expect(progress.newChapters, 0);
              final stored = manager.getComicWithUpdatesInfo(
                '在读',
                item.id,
                item.type,
              );
              expect(stored.updateTime, '2026-11-04');
              expect(stored.hasNewUpdate, isTrue);
            });
          },
        );

        test(
          'refresh keeps same-day additions visible to direct reading',
          () async {
            var revision = 1;
            final source = _source(
              sourceKey,
              loadComicInfo: (id) async => Res(
                ComicDetails.fromJson({
                  ..._details(sourceKey, id).toJson(),
                  'chapters': {'one': 'One', if (revision == 2) 'two': 'Two'},
                  'chapterPageCounts': {'one': revision == 1 ? 15 : 25},
                  'maxPage': 100,
                }),
              ),
              loadComicPages: (id, chapter) async => Res([
                for (var page = 1; page <= (revision == 1 ? 15 : 25); page++)
                  '$chapter-$page.jpg',
              ]),
            );
            ComicSourceManager().add(source);
            await _withLiveFavorites((manager) async {
              final item = _tracked(sourceKey, 'same-day');
              final initial = (await source.loadComicInfoForReading(
                item.id,
              )).data;
              manager.addComic(
                '在读',
                item,
                null,
                ComicUpdateSnapshot.fromChapters(
                  initial.chapters!.toJson(),
                  updateTime: initial.findUpdateTime(),
                  maxPage: initial.maxPage,
                  chapterPageCounts: initial.chapterPageCounts,
                ),
              );
              await source.loadComicPagesForReading(item.id, 'one');
              revision = 2;
              final progress = await updateFolder('在读', true).toList();
              expect(progress.last.updated, 1);
              expect(progress.last.newChapters, 1);
              final reopened = (await source.loadComicInfoForReading(
                item.id,
              )).data;
              expect(reopened.chapters!.ids, ['one', 'two']);
              final pages = (await source.loadComicPagesForReading(
                item.id,
                'one',
              )).data;
              expect(pages, [
                for (var page = 1; page <= 25; page++) 'one-$page.jpg',
              ]);
              expect(manager.hasNewUpdate(item.id, item.type), isTrue);
            });
          },
        );

        test(
          'missing scope emits an error and releases its active operation',
          () async {
            await _withLiveFavorites((manager) async {
              await expectLater(
                updateFolder('missing', true).toList(),
                throwsStateError,
              );
              expect(isFolderUpdating('missing'), isFalse);
            });
          },
        );
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
  });

  group('FollowUpdateQueue', () {
    test(
      'limits each source without pausing other sources after five starts',
      () {
        fakeAsync((async) {
          final scope = RequestScope();
          final started = <String>[];
          final responses = <String, Completer<void>>{};
          final activeBySource = <String, int>{};
          var active = 0;
          var maxActive = 0;
          var maxActivePerSource = 0;
          var completed = false;
          runFollowUpdateTasks(
            ['a1', 'a2', 'a3', 'b1', 'b2', 'c1', 'd1', 'e1', 'f1'],
            sourceKey: (task) => task[0],
            scope: scope,
            now: () => DateTime(2026).add(async.elapsed),
            run: (task) async {
              started.add(task);
              final source = task[0];
              active++;
              activeBySource[source] = (activeBySource[source] ?? 0) + 1;
              if (active > maxActive) maxActive = active;
              if (activeBySource[source]! > maxActivePerSource) {
                maxActivePerSource = activeBySource[source]!;
              }
              final response = responses[task] = Completer<void>();
              await response.future;
              active--;
              activeBySource[source] = activeBySource[source]! - 1;
            },
          ).then((_) => completed = true);
          async.flushMicrotasks();
          expect(started, ['a1', 'b1', 'c1', 'd1', 'e1']);

          responses['b1']!.complete();
          async.flushMicrotasks();
          expect(started.last, 'f1');
          expect(async.elapsed, Duration.zero);

          async.elapse(const Duration(milliseconds: 500));
          responses['c1']!.complete();
          async.flushMicrotasks();
          expect(started.last, 'a2');

          async.elapse(const Duration(milliseconds: 500));
          responses['d1']!.complete();
          async.flushMicrotasks();
          expect(started.last, 'b2');
          expect(started, isNot(contains('a3')));

          responses['a1']!.complete();
          async.flushMicrotasks();
          expect(started.last, 'a3');
          for (final response in responses.values) {
            if (!response.isCompleted) response.complete();
          }
          async.flushMicrotasks();
          expect(completed, isTrue);
          expect(maxActive, 5);
          expect(maxActivePerSource, 2);
          expect(active, 0);
          scope.dispose();
        });
      },
    );

    test(
      'spaces requests to one source while spare slots remain available',
      () {
        fakeAsync((async) {
          final scope = RequestScope();
          final started = <Duration>[];
          var completed = false;
          runFollowUpdateTasks(
            [1, 2],
            sourceKey: (_) => 'source',
            scope: scope,
            now: () => DateTime(2026).add(async.elapsed),
            run: (_) async => started.add(async.elapsed),
          ).then((_) => completed = true);
          async.flushMicrotasks();
          expect(started, [Duration.zero]);

          async.elapse(const Duration(milliseconds: 499));
          expect(started, hasLength(1));
          async.elapse(const Duration(milliseconds: 1));
          expect(started, [Duration.zero, const Duration(milliseconds: 500)]);
          expect(completed, isTrue);
          scope.dispose();
        });
      },
    );
  });
}

const _oldTime = '2026-10-01';
const _newTime = '2026-10-02';
const _laterTime = '2026-10-03';
final _oldSnapshot = ComicUpdateSnapshot.fromChapters(
  null,
  updateTime: _oldTime,
);

ComicSource _source(
  String key, {
  LoadComicFunc? loadComicInfo,
  LoadComicPagesFunc? loadComicPages,
}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    loadComicPages,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

FavoriteItemWithUpdateInfo _tracked(String key, String id) =>
    FavoriteItemWithUpdateInfo(
      FavoriteItem(
        id: id,
        name: 'Old title',
        coverPath: 'old.jpg',
        author: 'Old author',
        type: ComicType.fromKey(key),
        tags: const [],
      ),
      _oldTime,
      false,
      null,
    );

ComicDetails _details(
  String source,
  String id, {
  String updateTime = _newTime,
}) => ComicDetails.fromJson({
  'sourceKey': source,
  'comicId': id,
  'title': 'Fresh title',
  'cover': 'fresh.jpg',
  'subtitle': 'Fresh author',
  'tags': <String, List<String>>{
    'genre': ['fresh'],
  },
  'updateTime': updateTime,
});

Future<void> _withLiveFavorites(
  Future<void> Function(LocalFavoritesManager manager) run,
) async {
  final data = Directory.systemTemp.createTempSync('venera-refresh-');
  final cache = Directory.systemTemp.createTempSync('venera-refresh-cache-');
  String? oldData;
  String? oldCache;
  try {
    oldData = App.dataPath;
  } on Error {
    /* Late path may be unset. */
  }
  try {
    oldCache = App.cachePath;
  } on Error {
    /* Late path may be unset. */
  }
  final oldSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
  final oldManager = LocalFavoritesManager.cache;
  LocalFavoritesManager? manager;
  try {
    App.dataPath = data.path;
    App.cachePath = cache.path;
    appdata.settings.remove('readingFolder');
    LocalFavoritesManager.cache = null;
    manager = LocalFavoritesManager();
    await manager.init();
    manager.createFolder('在读');
    await manager.setReadingFolder('在读');
    await run(manager);
  } finally {
    await appdata.saveData(false);
    if (manager != null) {
      await manager.waitForPendingReads();
      manager.close();
    }
    await CacheManager.resetForTesting();
    LocalFavoritesManager.cache = oldManager;
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(oldSettings);
    App.dataPath = oldData ?? Directory.systemTemp.path;
    App.cachePath = oldCache ?? Directory.systemTemp.path;
    data.deleteSync(recursive: true);
    cache.deleteSync(recursive: true);
  }
}
