import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';

const _oldTime = '2026-10-01';
const _newTime = '2026-10-02';
const _laterTime = '2026-10-03';

void main() {
  const sourceKey = 'follow_updates_test_source';

  setUp(() {
    Log.isMuted = true;
  });

  tearDown(() {
    Log.isMuted = false;
    ComicSourceManager().remove(sourceKey);
  });

  test('updateComic does not wait after final retry failure', () async {
    var attempts = 0;
    final retryDelays = <Duration>[];
    final source = _source(
      sourceKey,
      loadComicInfo: (id) async {
        attempts++;
        throw 'network unavailable';
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

    final result = await updateComic(
      item,
      'folder',
      retryDelay: (duration) {
        retryDelays.add(duration);
        return Future.value();
      },
    );

    expect(result.updated, isFalse);
    expect(result.errorMessage, contains('network unavailable'));
    expect(attempts, 3);
    expect(retryDelays, const [Duration(seconds: 2), Duration(seconds: 2)]);
  });

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

      var delayCalled = false;
      final result = await updateComic(
        missingSourceItem,
        'folder',
        retryDelay: (_) {
          delayCalled = true;
          return Future.value();
        },
      );
      expect(result.updated, isFalse);
      expect(result.errorMessage, contains('Comic source not found'));
      expect(delayCalled, isFalse);
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
            manager.addComic('在读', item, null, _oldTime);
            manager.addComic('other', item, null, _oldTime);
            final first = updateComic(item, '在读');
            await started.future;
            final second = updateComic(item, 'other');
            final remote = refreshComic(item);
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
            manager.addComic('在读', item, null, _oldTime);
            manager.addComic(
              'other',
              _tracked(sourceKey, 'outside'),
              null,
              _oldTime,
            );
            manager.addComic('在读', _tracked('local', 'local'));
            await manager.debugWaitForHashedIdsRefresh();
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
            manager.addComic('在读', item, null, _oldTime);
            manager.addComic('other', item, null, _oldTime);
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
              _oldTime,
            );
            manager.addComic(
              '在读',
              _tracked(sourceKey, 'pending'),
              null,
              _oldTime,
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
        'reading during pending request acknowledges the returned version',
        () async {
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
            final item = _tracked(sourceKey, 'read-race');
            manager.addComic('在读', item, null, _oldTime);
            final pending = updateComic(item, '在读');
            await started.future;
            manager.markAsRead(item.id, item.type);
            response.complete(Res(_details(sourceKey, item.id)));
            final result = await pending;
            expect(result.updated, isFalse);
            expect(
              manager
                  .getComicWithUpdatesInfo('在读', item.id, item.type)
                  .updateTime,
              _newTime,
            );
            expect(manager.hasNewUpdate(item.id, item.type), isFalse);
            manager.updateUpdateTime('在读', item.id, item.type, _laterTime);
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
            manager.addComic('在读', item, null, _oldTime);
            final pending = updateComic(item, '在读');
            await started.future;
            if (replaceDatabase) {
              await manager.debugWaitForHashedIdsRefresh();
              manager.close();
              await manager.init();
            } else {
              manager.rename('在读', 'renamed');
            }
            response.complete(Res(_details(sourceKey, item.id)));
            expect((await pending).errorMessage, isNotNull);
            expect(
              manager.getComic(manager.readingFolder!, item.id, item.type).name,
              'Old title',
            );
          });
          ComicSourceManager().remove(sourceKey);
        }
      });

      test(
        'network-only metadata never inserts into local favorites',
        () async {
          ComicSourceManager().add(
            _source(
              sourceKey,
              loadComicInfo: (id) async => Res(_details(sourceKey, id)),
            ),
          );
          await _withLiveFavorites((manager) async {
            final item = _tracked(sourceKey, 'remote-only');
            final result = await refreshComic(item);
            expect(result.item?.name, 'Fresh title');
            expect(result.updateTime, _newTime);
            expect(manager.find(item.id, item.type), isEmpty);
            expect(manager.count('在读'), 0);
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
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

ComicSource _source(String key, {LoadComicFunc? loadComicInfo}) {
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
    null,
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
    await run(manager);
  } finally {
    await appdata.saveData(false);
    if (manager != null) {
      await manager.debugWaitForHashedIdsRefresh();
      manager.close();
    }
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
