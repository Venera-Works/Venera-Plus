import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/remote_library/remote_library_repository.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late _FakeRemoteLibraryOps ops;
  late Directory dataDir;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-webdav-library-');
    App.dataPath = dataDir.path;
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.configureMetadataScraper(null);
    RemoteLibrarySource.configureMetadataSubjectHandler(null);
    RemoteLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    ops = _FakeRemoteLibraryOps();
    RemoteLibrarySource.ops = ops;
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      'pass',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/manga/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
  });

  tearDown(() async {
    if (RemoteLibrarySource.syncStatus.value.isSyncing) {
      await _synchronizeAndComplete();
    }
    RemoteLibrarySource.archiveSchedulerFactory = null;
    RemoteLibrarySource.resetOps();
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.configureMetadataScraper(null);
    RemoteLibrarySource.configureMetadataSubjectHandler(null);
    appdata.settings['webdavComicLibrary'] = [];
    appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
    appdata.settings['webdavComicLibraryAutoSync'] = true;
    dataDir.deleteSync(recursive: true);
  });

  test('library identity excludes password but includes location and user', () {
    final first = RemoteLibraryConfig(
      url: ' HTTPS://EXAMPLE.COM:443/dav/ ',
      user: ' user ',
      pass: 'old password',
      remotePath: 'manga',
    );
    final passwordChanged = RemoteLibraryConfig(
      url: 'https://example.com/dav',
      user: 'user',
      pass: 'new password',
      remotePath: '/manga/',
    );
    final pathChanged = RemoteLibraryConfig(
      url: 'https://example.com/dav',
      user: 'user',
      pass: 'new password',
      remotePath: '/other/',
    );

    expect(passwordChanged.libraryId, first.libraryId);
    expect(pathChanged.libraryId, isNot(first.libraryId));
  });

  for (final enabled in [true, false]) {
    test('旧单库迁移保留默认页面的${enabled ? '启用' : '隐藏'}状态', () async {
      appdata.settings[RemoteComicLibraryRegistry.settingsKey] = [];
      appdata.settings[remoteStorageAccountsSetting] = [];
      appdata.settings[RemoteComicLibraryRegistry.legacyMigrationKey] = false;
      appdata.settings[RemoteComicLibraryRegistry.legacyAccountMigrationKey] =
          false;
      final pages = ['其他源同名页', if (enabled) 'WebDAV Library'];
      appdata.settings['explore_pages'] = pages.toList();
      await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
      final migrated = RemoteComicLibraryRegistry.read().single;
      expect(migrated.name, 'WebDAV Library');
      expect(
        (appdata.settings['explore_pages'] as List).contains(migrated.name),
        enabled,
      );
      expect(appdata.settings['explore_pages'], pages);
      await RemoteComicLibraryRegistry.save(migrated.copyWith(name: '自定义库名'));
      await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
      expect(RemoteComicLibraryRegistry.read().single.name, '自定义库名');
    });
  }

  for (final scrapeFirst in [true, false]) {
    test('卷索引与后台刮削交错保留最新快照，刮削先完成=$scrapeFirst', () async {
      final zip = archive.ZipEncoder().encode(
        archive.Archive()
          ..addFile(archive.ArchiveFile('001.jpg', 1, [1]))
          ..addFile(archive.ArchiveFile('002.jpg', 1, [2])),
      );
      final store = _FakeRemoteFileStore('snapshot-race');
      final files = [
        for (var i = 1; i <= 2; i++)
          RemoteEntry(
            name: 'Book 0$i.zip',
            path: '/race/Book 0$i.zip',
            isDirectory: false,
            size: zip.length,
            eTag: '"v1"',
          ),
      ];
      store.dirs['/race/'] = files;
      for (final file in files) {
        store.statEntries[file.path] = file;
        store.links[file.path] = RemoteLink(
          url: 'https://range.example/${file.name}',
        );
      }
      final rangeStarted = Completer<void>();
      final rangeGate = Completer<void>();
      final adapter = _SnapshotRangeAdapter(zip, rangeStarted, rangeGate);
      final dio = Dio()..httpClientAdapter = adapter;
      RemoteLibrarySource.archiveDioFactory = () => dio;
      addTearDown(() {
        RemoteLibrarySource.archiveDioFactory = null;
        dio.close(force: true);
      });
      final scrapeStarted = Completer<void>();
      final scrape = Completer<ComicMetaData?>();
      RemoteLibrarySource.configureMetadataScraper((_) {
        if (!scrapeStarted.isCompleted) scrapeStarted.complete();
        return scrape.future;
      });
      final engine = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'snapshot-race',
          sourceKey: 'snapshot-race',
          accountId: 'snapshot-race',
          directories: ['/race/'],
          name: '竞态库',
          autoRefresh: false,
        ),
        store: store,
      );
      addTearDown(engine.cancel);
      await engine.synchronize();
      await scrapeStarted.future;
      final id = (await engine.loadComics(1)).data.single.id;
      final reading = engine.loadComicPages(id, files.first.path);
      await rangeStarted.future;
      try {
        if (scrapeFirst) {
          scrape.complete(
            const ComicMetaData(
              title: '刮削书名',
              author: '作者',
              tags: ['标签'],
              bangumiSubjectId: 47,
            ),
          );
          await engine.waitForBackgroundTasks();
          expect((await engine.loadComicInfo(id)).data.title, '刮削书名');
          rangeGate.complete();
        } else {
          rangeGate.complete();
          expect((await reading).success, isTrue);
          scrape.complete(
            const ComicMetaData(
              title: '刮削书名',
              author: '作者',
              tags: ['标签'],
              bangumiSubjectId: 47,
            ),
          );
        }
        final pages = await reading;
        expect(pages.success, isTrue, reason: pages.errorMessage);
        expect(pages.data, hasLength(2));
        await engine.waitForBackgroundTasks();
        final details = await engine.loadComicInfo(id);
        expect(details.data.title, '刮削书名');
        expect(details.data.tags['作者'], ['作者']);
        expect(details.data.externalIds['bangumi'], '47');
        final cached = (await RemoteLibraryRepository.instance.find(
          'remote-library:snapshot-race',
          id,
        ))!;
        expect(cached.title, '刮削书名');
        final volumes = (cached.snapshot!['work'] as Map)['volumes'] as List;
        expect((volumes.first as Map)['archive']['index'], isNotNull);
      } finally {
        if (!rangeGate.isCompleted) rangeGate.complete();
        if (!scrape.isCompleted) scrape.complete(null);
        await reading;
        await engine.waitForBackgroundTasks();
      }
    });
  }

  test('按需详情触发的旧刮削在强刷后拒绝远端写回', () async {
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-v1'),
    ];
    ops.dirs['/manga/'] = const [];
    final started = Completer<void>();
    final scrape = Completer<ComicMetaData?>();
    RemoteLibrarySource.configureMetadataScraper((_) {
      if (!started.isCompleted) started.complete();
      return scrape.future;
    });
    expect((await RemoteLibrarySource.loadComicInfo('Book')).success, isTrue);
    await started.future;
    await RemoteLibrarySource.synchronize(force: true);
    scrape.complete(const ComicMetaData(title: '过时书名', author: '', tags: []));
    await RemoteLibrarySource.waitForBackgroundTasks();
    expect(ops.writeRequests, isEmpty);
  });

  test('详情初始缓存查询期间关闭不会再排入 cooldown stat', () async {
    RemoteLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero)
          ..defer(retryAfter: '3600');
    final store = _FakeRemoteFileStore('cooldown');
    final engine = RemoteLibraryEngine(
      library: const RemoteLibrary(
        id: 'cooldown',
        sourceKey: 'cooldown',
        accountId: 'cooldown',
        directories: ['/files/'],
        name: '关闭库',
        autoRefresh: false,
      ),
      store: store,
    );
    final reading = engine.loadComicInfo('/files/Book.zip');
    await engine.cancel().timeout(const Duration(seconds: 2));
    final result = await reading.timeout(const Duration(seconds: 2));
    expect(result.error, isTrue);
    expect(store.statPaths, isEmpty);
  });

  test(
    'legacy snapshot migrates after its import clears the migration marker',
    () async {
      appdata.settings[RemoteComicLibraryRegistry.settingsKey] = const [];
      appdata.settings[remoteStorageAccountsSetting] = const [];
      appdata.settings[RemoteComicLibraryRegistry.legacyMigrationKey] = true;
      appdata.settings['webdavComicLibrary'] = const [];
      await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
      expect(RemoteComicLibraryRegistry.read(), isEmpty);

      appdata.settings['webdavComicLibrary'] = const [
        'https://example.com/dav',
        'user',
        'pass',
      ];
      appdata.settings['webdavComicLibraryPath'] = '/manga/';
      appdata.settings[RemoteComicLibraryRegistry.legacyMigrationKey] = false;
      final oldLibraryId = RemoteLibraryConfig.fromSettings().libraryId;

      await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
      final library = RemoteComicLibraryRegistry.read().single;
      expect(library.sourceKey, RemoteLibrarySource.sourceKey);
      expect(library.id, oldLibraryId);
      expect(library.directories, const ['/manga/']);
    },
  );

  test('legacy account recovery avoids a default-name collision', () async {
    final storage = RemoteStorageAccounts.instance;
    final original = RemoteLibrary(
      id: RemoteLibraryConfig.fromSettings().libraryId,
      sourceKey: RemoteLibrarySource.sourceKey,
      accountId: 'legacy-missing',
      directories: ['/manga/'],
      name: 'Old library',
    );
    const unrelated = StorageAccount(
      id: 'other-account',
      backend: StorageBackend.webdav,
      driver: 'webdav',
      name: 'WebDAV漫画库',
      authorization: {
        'url': 'https://other.example.com/',
        'user': 'other',
        'password': 'other',
      },
    );
    appdata.settings[remoteStorageAccountsSetting] = [unrelated.toJson()];
    appdata.settings[remoteLibrariesSetting] = [original.toJson()];
    appdata.settings[RemoteComicLibraryRegistry.legacyAccountMigrationKey] =
        false;
    await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
    expect(storage.account(unrelated.id)?.toJson(), unrelated.toJson());
    expect(storage.account(original.accountId)?.name, 'WebDAV漫画库 (2)');
    expect(storage.libraries.single.toJson(), original.toJson());
  });

  for (final hasMatchingAccount in [false, true]) {
    test(
      'recovers an orphaned legacy library and reads old favorites, existing=$hasMatchingAccount',
      () async {
        final storage = RemoteStorageAccounts.instance;
        final legacy = RemoteLibraryConfig.fromSettings();
        final original = RemoteLibrary(
          id: legacy.libraryId,
          sourceKey: RemoteLibrarySource.sourceKey,
          accountId: 'legacy-missing',
          directories: ['/manga/'],
          name: 'Old library',
          autoRefresh: false,
        );
        appdata.settings[remoteStorageAccountsSetting] = [];
        appdata.settings[remoteLibrariesSetting] = [original.toJson()];
        appdata.settings[RemoteComicLibraryRegistry.legacyMigrationKey] = true;
        appdata.settings[RemoteComicLibraryRegistry.legacyAccountMigrationKey] =
            false;
        if (hasMatchingAccount) {
          await storage.save(
            StorageAccount(
              id: 'existing-account',
              backend: StorageBackend.webdav,
              driver: 'webdav',
              name: 'My library account',
              authorization: {
                'url': legacy.url,
                'user': legacy.user,
                'password': legacy.pass,
              },
            ),
          );
        }

        await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
        await appdata.loadDataForTesting(dataDir.path);

        final library = storage.libraries.single;
        final account = storage.account(library.accountId)!;
        expect(library.id, original.id);
        expect(library.sourceKey, original.sourceKey);
        expect(library.directories, original.directories);
        expect(storage.accounts, hasLength(1));
        expect(
          account.id,
          hasMatchingAccount ? 'existing-account' : original.accountId,
        );
        expect(account.authorization, {
          'url': legacy.url,
          'user': legacy.user,
          'password': legacy.pass,
        });
        if (hasMatchingAccount) expect(account.name, 'My library account');
        final store = _FakeRemoteFileStore(account.id)
          ..dirs['/manga/Old/'] = const [
            RemoteEntry(
              name: '001.jpg',
              path: '/manga/Old/001.jpg',
              isDirectory: false,
            ),
          ];
        final engine = RemoteLibraryEngine(library: library, store: store);
        addTearDown(engine.cancel);
        final source = engine.create();
        final details = await source.loadComicInfo!('Old');
        final pages = await source.loadComicPages!('Old', null);
        expect(source.key, original.sourceKey);
        expect(details.success, isTrue);
        expect(pages.success, isTrue);
        expect(pages.data, ['/manga/Old/001.jpg']);

        // Later account deletion is an explicit action and must stay deleted.
        await storage.remove(account.id);
        await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
        expect(storage.accounts, isEmpty);
      },
    );
  }

  test(
    'does not restore legacy credentials into a different library identity',
    () async {
      appdata.settings[remoteStorageAccountsSetting] = [];
      appdata.settings[remoteLibrariesSetting] = [
        const RemoteLibrary(
          id: 'another-library',
          sourceKey: RemoteLibrarySource.sourceKey,
          accountId: 'missing',
          directories: ['/elsewhere/'],
          name: 'Other',
        ).toJson(),
      ];
      appdata.settings[RemoteComicLibraryRegistry.legacyMigrationKey] = true;
      appdata.settings[RemoteComicLibraryRegistry.legacyAccountMigrationKey] =
          false;
      await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
      expect(RemoteStorageAccounts.instance.accounts, isEmpty);
      expect(
        RemoteStorageAccounts.instance.libraries.single.accountId,
        'missing',
      );
    },
  );

  test(
    'root memberships merge selected directories and retain removed root cache',
    () async {
      final cache = RemoteLibraryRepository.instance;
      const key = 'multi-root-library';
      (await cache.replaceRootDirectoryIndex(
        key,
        const RemoteLibraryRootIndex(
          rootPath: '/A/',
          directories: [
            RemoteLibraryRemoteDirectory(id: '/A/Comic/', sortIndex: 0),
            RemoteLibraryRemoteDirectory(id: '/A/Same/', sortIndex: 1),
          ],
        ),
      ));
      (await cache.replaceRootDirectoryIndex(
        key,
        const RemoteLibraryRootIndex(
          rootPath: '/B/C/',
          directories: [
            RemoteLibraryRemoteDirectory(id: '/B/C/Same/', sortIndex: 0),
            RemoteLibraryRemoteDirectory(id: '/A/Same/', sortIndex: 1),
          ],
        ),
      ));

      expect((await cache.count(key, roots: const ['/A/', '/B/C/'])), 3);
      expect((await cache.count(key, roots: const ['/B/C/'])), 2);
      expect(
        (await cache.page(
          key,
          page: 1,
          pageSize: 10,
          roots: const ['/B/C/'],
        )).map((item) => item.id),
        containsAll(const ['/B/C/Same/', '/A/Same/']),
      );

      (await cache.removeRootsExcept(key, const {'/B/C/'}));
      expect((await cache.count(key, roots: const ['/B/C/'])), 2);
      // Re-adding an unavailable root can still display its last membership.
      expect((await cache.count(key, roots: const ['/A/', '/B/C/'])), 3);
    },
  );

  test(
    'two remote libraries synchronize without cancelling each other',
    () async {
      final firstStore = _FakeRemoteFileStore('first')
        ..dirs['/one/'] = const [
          RemoteEntry(name: 'First', path: '/one/First/', isDirectory: true),
        ]
        ..dirs['/one/First/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/one/First/001.jpg',
            isDirectory: false,
          ),
        ];
      final secondStore = _FakeRemoteFileStore('second')
        ..dirs['/two/'] = const [
          RemoteEntry(name: 'Second', path: '/two/Second/', isDirectory: true),
        ]
        ..dirs['/two/Second/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/two/Second/001.jpg',
            isDirectory: false,
          ),
        ];
      final first = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'first',
          sourceKey: 'first',
          accountId: 'first',
          directories: ['/one/'],
          name: 'First',
        ),
        store: firstStore,
      );
      final second = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'second',
          sourceKey: 'second',
          accountId: 'second',
          directories: ['/two/'],
          name: 'Second',
        ),
        store: secondStore,
      );

      await Future.wait([first.synchronize(), second.synchronize()]);
      expect(
        (await first.create().explorePages.single.loadPage!(1)).data.single.id,
        '/one/First/',
      );
      expect(
        (await second.create().explorePages.single.loadPage!(1)).data.single.id,
        '/two/Second/',
      );
      await first.cancel();
      await second.cancel();
      expect(firstStore.cancelAllCalls, 1);
      expect(secondStore.cancelAllCalls, 1);
    },
  );

  test('remote library thumbnails resolve their own account links', () async {
    const imageKey = '/娱乐/漫画 [A] 100%/cover.jpg';
    final sources = <String, ComicSource>{};
    final stores = <String, _FakeRemoteFileStore>{};
    for (final id in ['first', 'second']) {
      final store = _FakeRemoteFileStore(id)
        ..links[imageKey] = RemoteLink(
          url: 'https://$id.example.com/cover.jpg?sign=$id',
          headers: {'Referer': 'https://$id.example.com/'},
        );
      final engine = RemoteLibraryEngine(
        library: RemoteLibrary(
          id: id,
          sourceKey: id,
          accountId: id,
          directories: const ['/娱乐/'],
          name: id,
          autoRefresh: false,
        ),
        store: store,
      );
      addTearDown(engine.cancel);
      sources[id] = engine.create();
      stores[id] = store;
    }

    for (final id in sources.keys) {
      final config = await sources[id]!.getThumbnailLoadingConfig?.call(
        imageKey,
      );
      expect(config, {
        'url': 'https://$id.example.com/cover.jpg?sign=$id',
        'headers': {'Referer': 'https://$id.example.com/'},
      });
      expect(stores[id]!.linkedPaths, [imageKey]);
    }
  });

  test(
    'legacy multi-root IDs retain the anchor only for its original root',
    () async {
      final store = _FakeRemoteFileStore('legacy')
        ..dirs['/manga/'] = const [
          RemoteEntry(name: 'Old', path: '/manga/Old/', isDirectory: true),
        ]
        ..dirs['/other/'] = const [
          RemoteEntry(name: 'New', path: '/other/New/', isDirectory: true),
        ]
        ..dirs['/manga/Old/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/manga/Old/001.jpg',
            isDirectory: false,
          ),
        ]
        ..dirs['/other/New/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/other/New/001.jpg',
            isDirectory: false,
          ),
        ];
      final engine = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'legacy',
          sourceKey: RemoteLibrarySource.sourceKey,
          accountId: 'legacy',
          directories: ['/manga/', '/other/'],
          name: 'Legacy',
        ),
        store: store,
      );

      await engine.synchronize();
      final ids = (await engine.create().explorePages.single.loadPage!(
        1,
      )).data.map((comic) => comic.id);
      expect(ids, containsAll(['Old', '/other/New/']));
      await engine.cancel();
    },
  );

  test(
    'failed root keeps the available union and exposes its warning',
    () async {
      final store = _FakeRemoteFileStore('partial')
        ..dirs['/available/'] = const [
          RemoteEntry(
            name: 'Comic',
            path: '/available/Comic/',
            isDirectory: true,
          ),
        ]
        ..dirs['/available/Comic/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/available/Comic/001.jpg',
            isDirectory: false,
          ),
        ];
      final engine = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'partial',
          sourceKey: 'partial',
          accountId: 'partial',
          directories: ['/available/', '/missing/'],
          name: 'Partial',
        ),
        store: store,
      );

      await engine.synchronize();
      store.errors['/missing/'] = StateError('missing root');
      expect((await engine.synchronize()).error, isTrue);
      expect(
        (await engine.create().explorePages.single.loadPage!(1)).data.single.id,
        '/available/Comic/',
      );
      expect(engine.statusMessage, contains('/missing/'));
      await engine.cancel();
    },
  );

  test(
    'legacy engine writes anchor-external Bangumi metadata by full path',
    () async {
      final store = _FakeRemoteFileStore('legacy-write')
        ..dirs['/other/New/'] = const [
          RemoteEntry(
            name: '001.jpg',
            path: '/other/New/001.jpg',
            isDirectory: false,
          ),
        ];
      final engine = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'legacy-write',
          sourceKey: RemoteLibrarySource.sourceKey,
          accountId: 'legacy-write',
          directories: ['/manga/', '/other/'],
          name: 'Legacy',
        ),
        store: store,
      );

      await engine.writeMetadata(
        '/other/New/',
        const ComicMetaData(title: 'New', author: '', tags: []),
      );
      expect(store.writtenPaths, contains('/other/New/metadata.json'));
      await engine.cancel();
    },
  );

  test('malformed synchronized connection tuples are rejected', () {
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      7,
      'password',
    ];

    expect(RemoteLibraryConfig.fromSettings().isValid, isFalse);
  });

  test('malformed synchronized remote paths fail closed', () {
    appdata.settings['webdavComicLibraryPath'] = '../other-library';

    final config = RemoteLibraryConfig.fromSettings();

    expect(config.isValid, isFalse);
    expect(config.remotePath, '/venera_comics/');
  });

  test('loadComics lists directories and ZIP/CBZ file placeholders', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye', isDirectory: true),
      RemoteLibraryEntry(name: 'archive.cbz', isDirectory: false),
      RemoteLibraryEntry(name: '.DS_Store', isDirectory: false),
    ];
    ops.dirs['/manga/Cat Eye/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    await RemoteLibrarySource.loadComics(1);
    await _synchronizeAndComplete();
    final result = await RemoteLibrarySource.loadComics(1);

    expect(result.success, isTrue);
    expect(
      result.data.firstWhere((comic) => comic.title == 'Cat Eye').cover,
      '/manga/Cat Eye/cover.jpg',
    );
    expect(result.subData, 1);
    expect(result.data.map((comic) => comic.title).toSet(), {
      'Cat Eye',
      'archive',
    });
    expect(
      result.data.every(
        (comic) => comic.sourceKey == RemoteLibrarySource.sourceKey,
      ),
      isTrue,
    );
    expect(ops.readPaths.any((path) => path.contains('archive.cbz')), isFalse);
  });

  test(
    'loadComics keeps folder title and finds chapter cover from unmodifiable lists',
    () async {
      ops.dirs['/manga/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        const RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        const RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);

      await RemoteLibrarySource.loadComics(1);
      await _synchronizeAndComplete();
      final result = await RemoteLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, '猫之眼[北条司]');
      expect(result.data.single.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
    },
  );

  test('目录确认失败时不发布未经识别的漫画摘要', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye', isDirectory: true),
    ];
    ops.errors['/manga/Cat Eye/'] = UnsupportedError(
      'Cannot remove from an unmodifiable list',
    );

    final result = await RemoteLibrarySource.loadComics(1);

    expect(result.error, isTrue);
    expect(result.errorMessage, contains('Cannot remove'));
  });

  test('初次列表在慢 metadata.json 读取完成前返回已确认作品', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Slow Book', isDirectory: true),
    ];
    ops.dirs['/manga/Slow Book/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
    ];
    const metadataPath = '/manga/Slow Book/metadata.json';
    final blocker = Completer<void>();
    ops.textBlockers[metadataPath] = blocker;
    ops.textStarted[metadataPath] = Completer<void>();
    ops.textFiles[metadataPath] = jsonEncode({
      'title': '完整书名',
      'author': '',
      'tags': [],
    });
    try {
      final initial = await RemoteLibrarySource.loadComics(1);
      expect(initial.success, isTrue);
      expect(initial.data.single.title, 'Slow Book');
      expect(initial.data.single.cover, '/manga/Slow Book/cover.jpg');
      await ops.textStarted[metadataPath]!.future;
      expect(
        (await RemoteLibraryRepository.instance.find(
          RemoteLibraryConfig.fromSettings().cacheKey,
          'Slow Book',
        ))!.snapshot,
        isNull,
      );
    } finally {
      blocker.complete();
      await _synchronizeAndComplete();
    }
    expect((await RemoteLibrarySource.loadComics(1)).data.single.title, '完整书名');
  });

  test(
    'comic covers update while other directories are still being scanned',
    () async {
      final names = ['A', 'B', 'C', 'D', 'E', 'F'];
      ops.dirs['/manga/'] = [
        for (final name in names)
          RemoteLibraryEntry(name: name, isDirectory: true),
      ];
      for (final name in names) {
        ops.dirs['/manga/$name/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.blockers['/manga/$name/'] = Completer<void>();
        ops.readStarted['/manga/$name/'] = Completer<void>();
      }
      final cacheKey = RemoteLibraryConfig.fromSettings().cacheKey;
      final coverReady = Completer<void>();
      void onChanged() async {
        if (!coverReady.isCompleted &&
            (await RemoteLibraryRepository.instance.find(
                  cacheKey,
                  'A',
                ))?.cover.isNotEmpty ==
                true) {
          coverReady.complete();
        }
      }

      RemoteLibrarySource.contentVersion.addListener(onChanged);
      final sync = RemoteLibrarySource.synchronize();
      try {
        await Future.wait([
          for (final name in names.take(4))
            ops.readStarted['/manga/$name/']!.future,
        ]).timeout(const Duration(seconds: 2));
        expect(ops.readStarted['/manga/E/']!.isCompleted, isFalse);
        ops.blockers['/manga/A/']!.complete();
        await coverReady.future.timeout(const Duration(seconds: 2));
        await ops.readStarted['/manga/E/']!.future.timeout(
          const Duration(seconds: 2),
        );
        expect(ops.readStarted['/manga/F/']!.isCompleted, isFalse);
        final comics = await RemoteLibrarySource.loadComics(1);
        expect(comics.data.first.cover, '/manga/A/001.jpg');
        expect(RemoteLibrarySource.syncStatus.value.isSyncing, isTrue);
      } finally {
        RemoteLibrarySource.contentVersion.removeListener(onChanged);
        for (final blocker in ops.blockers.values) {
          if (!blocker.isCompleted) blocker.complete();
        }
        await sync;
      }
      expect(
        (await RemoteLibrarySource.loadComics(1)).data.map((comic) => comic.id),
        names,
      );
    },
  );

  test(
    'nested remote comics appear before their category finishes scanning',
    () async {
      final store = _FakeRemoteFileStore('account');
      store.dirs['/manga/'] = const [
        RemoteEntry(
          name: 'Category',
          path: '/manga/Category/',
          isDirectory: true,
        ),
      ];
      store.dirs['/manga/Category/'] = const [
        RemoteEntry(
          name: 'Book A',
          path: '/manga/Category/Book A/',
          isDirectory: true,
        ),
        RemoteEntry(
          name: 'Book B',
          path: '/manga/Category/Book B/',
          isDirectory: true,
        ),
      ];
      for (final name in ['Book A', 'Book B']) {
        store.dirs['/manga/Category/$name/'] = [
          RemoteEntry(
            name: '001.jpg',
            path: '/manga/Category/$name/001.jpg',
            isDirectory: false,
          ),
        ];
      }
      final blocker = Completer<void>();
      store.blockers['/manga/Category/Book B/'] = blocker;
      final engine = RemoteLibraryEngine(
        library: const RemoteLibrary(
          id: 'library',
          sourceKey: 'library',
          accountId: 'account',
          directories: ['/manga/'],
          name: 'Library',
          autoRefresh: false,
        ),
        store: store,
      );
      final source = engine.create();
      final coverReady = Completer<void>();
      void onChanged() async {
        if (!coverReady.isCompleted &&
            (await RemoteLibraryRepository.instance.find(
                  'remote-library:library',
                  '/manga/Category/Book A/',
                ))?.cover.isNotEmpty ==
                true) {
          coverReady.complete();
        }
      }

      engine.contentVersion.addListener(onChanged);
      final sync = engine.synchronize();
      try {
        await coverReady.future.timeout(const Duration(seconds: 2));
        final comics = await source.explorePages.single.loadPage!(1);
        expect(
          comics.data.any(
            (comic) => comic.cover == '/manga/Category/Book A/001.jpg',
          ),
          isTrue,
        );
        expect(engine.syncStatus.value.isSyncing, isTrue);
      } finally {
        engine.contentVersion.removeListener(onChanged);
        blocker.complete();
        await sync;
        await engine.cancel();
      }
    },
  );

  for (final rootCover in [true, false]) {
    test('章节后台补全不阻塞列表，阅读加入已有任务 (root cover: $rootCover)', () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = [
        const RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        if (rootCover)
          const RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        const RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        const RemoteLibraryEntry(name: '第02卷', isDirectory: true),
        const RemoteLibraryEntry(name: '临时目录', isDirectory: true),
      ];
      ops.textFiles['/manga/Comic/metadata.json'] = jsonEncode({
        'title': 'Comic title',
        'author': 'Author',
        'tags': ['Tag'],
      });
      for (final name in ['第01卷', '第02卷']) {
        ops.dirs['/manga/Comic/$name/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }
      final blocker = Completer<void>();
      final chapterStarted = Completer<void>();
      ops.blockers['/manga/Comic/第02卷/'] = blocker;
      ops.readStarted['/manga/Comic/第02卷/'] = chapterStarted;
      final sync = RemoteLibrarySource.synchronize();
      try {
        expect(
          (await sync.timeout(const Duration(seconds: 2))).success,
          isTrue,
        );
        final comics = await RemoteLibrarySource.loadComics(1);
        expect(comics.data.single.title, 'Comic');
        expect(
          comics.data.single.cover,
          rootCover ? '/manga/Comic/cover.jpg' : '',
        );
        final firstDetails = RemoteLibrarySource.loadComicInfo('Comic');
        final secondDetails = RemoteLibrarySource.loadComicInfo('Comic');
        await chapterStarted.future.timeout(const Duration(seconds: 2));
        blocker.complete();
        final details = await Future.wait([firstDetails, secondDetails]);
        for (final result in details) {
          expect(result.data.chapters!.allChapters.keys, ['第01卷', '第02卷']);
        }
        expect(
          ops.readPaths.where((path) => path == '/manga/Comic/第02卷/'),
          hasLength(1),
        );
      } finally {
        if (!blocker.isCompleted) blocker.complete();
        await sync;
      }
    });
  }

  for (final rootCover in [true, false]) {
    test('章目录识别完成后才提交漫画摘要 (root cover: $rootCover)', () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = [
        if (rootCover)
          const RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        const RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        const RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      for (final name in ['第01卷', '第02卷']) {
        ops.dirs['/manga/Comic/$name/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }
      final blockedPath = '/manga/Comic/${rootCover ? '第01卷' : '第02卷'}/';
      final blocker = Completer<void>();
      final started = Completer<void>();
      ops.blockers[blockedPath] = blocker;
      ops.readStarted[blockedPath] = started;
      final sync = RemoteLibrarySource.synchronize();
      try {
        await started.future;
        expect(
          await RemoteLibraryRepository.instance.find(
            RemoteLibraryConfig.fromSettings().cacheKey,
            'Comic',
          ),
          isNull,
        );
        blocker.complete();
        expect((await sync).success, isTrue);
        final comics = await RemoteLibrarySource.loadComics(1);
        expect(
          comics.data.single.cover,
          rootCover ? '/manga/Comic/cover.jpg' : '/manga/Comic/第01卷/001.jpg',
        );
        final details = await RemoteLibrarySource.loadComicInfo('Comic');
        expect(details.data.chapters!.allChapters.keys, ['第01卷', '第02卷']);
      } finally {
        if (!blocker.isCompleted) blocker.complete();
        await sync;
      }
    });
  }

  test('cached comic list is paged without additional WebDAV reads', () async {
    ops.dirs['/manga/'] = [
      for (var index = 1; index <= 45; index++)
        RemoteLibraryEntry(
          name: 'Book ${index.toString().padLeft(2, '0')}',
          isDirectory: true,
          eTag: 'v1',
        ),
    ];
    for (var index = 1; index <= 45; index++) {
      final name = 'Book ${index.toString().padLeft(2, '0')}';
      ops.dirs['/manga/$name/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
    }

    await _synchronizeAndComplete();
    ops.readPaths.clear();

    final first = await RemoteLibrarySource.loadComics(1);
    final second = await RemoteLibrarySource.loadComics(2);
    final third = await RemoteLibrarySource.loadComics(3);

    expect(first.data, hasLength(20));
    expect(second.data, hasLength(20));
    expect(third.data, hasLength(5));
    expect(first.subData, 3);
    expect(second.subData, 3);
    expect(third.subData, 3);
    expect(ops.readPaths, isEmpty);
  });

  test(
    'incremental sync fingerprints child entries before refreshing',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true, eTag: 'v1'),
        RemoteLibraryEntry(name: 'Book B', isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'a1'),
      ];
      ops.dirs['/manga/Book B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'b1'),
      ];
      await _synchronizeAndComplete();
      ops.readPaths.clear();

      await _synchronizeAndComplete();
      expect(ops.readPaths, ['/manga/', '/manga/Book A/', '/manga/Book B/']);
      expect(RemoteLibrarySource.syncStatus.value.total, 2);
      expect(RemoteLibrarySource.syncStatus.value.processed, 2);

      ops.readPaths.clear();
      ops.dirs['/manga/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'a2'),
      ];
      await _synchronizeAndComplete();

      expect(ops.readPaths, ['/manga/', '/manga/Book A/', '/manga/Book B/']);
      expect(RemoteLibrarySource.syncStatus.value.total, 2);
    },
  );

  test('failed refresh keeps the last successful cached list', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cached Book', isDirectory: true),
    ];
    ops.dirs['/manga/Cached Book/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    await _synchronizeAndComplete();
    ops.errors['/manga/'] = StateError('WebDAV unavailable');

    final refresh = await _synchronizeAndComplete(force: true);
    final cached = await RemoteLibrarySource.loadComics(1);

    expect(refresh.error, isTrue);
    expect(cached.success, isTrue);
    expect(cached.data.single.title, 'Cached Book');
  });

  test(
    'configuration change starts a new sync and invalidates old side effects',
    () async {
      final previous = RemoteLibraryConfig.fromSettings();
      final oldReadStarted = Completer<void>();
      final oldReadBlocker = Completer<void>();
      ops.readStarted['/manga/'] = oldReadStarted;
      ops.blockers['/manga/'] = oldReadBlocker;
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true),
      ];
      ops.dirs['/manga/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/other/'] = const [
        RemoteLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/other/Book B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      RemoteLibrarySource.configureMetadataScraper(
        (_) async =>
            const ComicMetaData(title: 'Scraped', author: '', tags: []),
      );

      final oldSync = RemoteLibrarySource.synchronize();
      await oldReadStarted.future;

      appdata.settings['webdavComicLibraryPath'] = '/other/';
      await RemoteLibrarySource.onConfigurationChanged(previous);
      RemoteLibrarySource.ops = ops;
      final newSync = await _synchronizeAndComplete().timeout(
        const Duration(seconds: 1),
      );

      expect(newSync.success, isTrue);
      expect(
        (await RemoteLibraryRepository.instance.count(
          RemoteLibraryConfig.fromSettings().cacheKey,
        )),
        1,
      );
      expect(ops.writtenTexts, contains('/other/Book B/metadata.json'));
      final currentStatus = RemoteLibrarySource.syncStatus.value;
      final currentContentVersion = RemoteLibrarySource.contentVersion.value;

      oldReadBlocker.complete();
      final oldResult = await oldSync;

      expect(oldResult.success, isTrue);
      expect(
        (await RemoteLibraryRepository.instance.count(previous.cacheKey)),
        0,
      );
      expect(
        ops.writtenTexts.keys.where((path) => path.startsWith('/manga/')),
        isEmpty,
      );
      expect(
        RemoteLibrarySource.syncStatus.value.lastSuccessfulSync,
        currentStatus.lastSuccessfulSync,
      );
      expect(RemoteLibrarySource.syncStatus.value.isSyncing, isFalse);
      expect(RemoteLibrarySource.contentVersion.value, currentContentVersion);
    },
  );

  test('concurrent detail loads share one snapshot request', () async {
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final results = await Future.wait([
      RemoteLibrarySource.loadComicInfo('Book'),
      RemoteLibrarySource.loadComicInfo('Book'),
    ]);

    expect(results.every((result) => result.success), isTrue);
    expect(ops.readPaths, ['/manga/Book/']);
  });

  test(
    'a detail-only cache entry does not replace the full library index',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true),
        RemoteLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await RemoteLibrarySource.loadComicInfo('Book A');
      await RemoteLibrarySource.loadComics(1);
      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(comics.data.map((comic) => comic.id), ['Book A', 'Book B']);
    },
  );

  test(
    'loadComicInfo lists every chapter directory and uses the first page as cover',
    () async {
      ops.dirs['/manga/Cat Eye/'] = const [
        RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        RemoteLibraryEntry(name: '第02卷', isDirectory: true),
        RemoteLibraryEntry(name: '第03卷', isDirectory: true),
        RemoteLibraryEntry(name: '第04卷', isDirectory: true),
        RemoteLibraryEntry(name: '第05卷', isDirectory: true),
        RemoteLibraryEntry(name: 'book.cbz', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第01卷/'] = const [
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第02卷/'] = const [
        RemoteLibraryEntry(name: '001.webp', isDirectory: false),
      ];
      for (var index = 3; index <= 5; index++) {
        ops.dirs['/manga/Cat Eye/第0$index卷/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }

      final result = await RemoteLibrarySource.loadComicInfo('Cat Eye');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/Cat Eye/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
        '第03卷': '第03卷',
        '第04卷': '第04卷',
        '第05卷': '第05卷',
      });
      expect(ops.readPaths, [
        '/manga/Cat Eye/',
        '/manga/Cat Eye/第01卷/',
        '/manga/Cat Eye/第02卷/',
        '/manga/Cat Eye/第03卷/',
        '/manga/Cat Eye/第04卷/',
        '/manga/Cat Eye/第05卷/',
      ]);
    },
  );

  test(
    'nested metadata directory is indexed as one comic with child chapters',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '分类', isDirectory: true),
      ];
      ops.dirs['/manga/分类/'] = const [
        RemoteLibraryEntry(name: '作者', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '第01章', isDirectory: true),
        RemoteLibraryEntry(name: '第02章', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/第01章/'] = const [
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/第02章/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/分类/作者/猫之眼/metadata.json'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作'],
        'chapters': [
          {'title': '错误的扁平章节', 'start': 1, 'end': 2},
        ],
      });

      final sync = await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      final details = await RemoteLibrarySource.loadComicInfo('分类/作者/猫之眼');
      final pages = await RemoteLibrarySource.loadComicPages(
        '分类/作者/猫之眼',
        '第01章',
      );

      expect(sync.success, isTrue);
      expect(comics.success, isTrue);
      expect(comics.data.single.id, '分类/作者/猫之眼');
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.cover, '/manga/分类/作者/猫之眼/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.chapters!.allChapters, {
        '第01章': '第01章',
        '第02章': '第02章',
      });
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/分类/作者/猫之眼/第01章/001.jpg',
        '/manga/分类/作者/猫之眼/第01章/002.jpg',
      ]);
    },
  );

  test(
    'nested metadata directories keep distinct relative ids for duplicate names',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '分类A', isDirectory: true),
        RemoteLibraryEntry(name: '分类B', isDirectory: true),
      ];
      for (final category in ['分类A', '分类B']) {
        ops.dirs['/manga/$category/'] = const [
          RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
        ];
        ops.dirs['/manga/$category/猫之眼/'] = const [
          RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/$category/猫之眼/metadata.json'] = jsonEncode({
          'title': category,
          'author': '',
          'tags': <String>[],
          'chapters': null,
        });
      }

      final sync = await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(comics.data, hasLength(2));
      expect(comics.data.map((comic) => comic.id), ['分类A/猫之眼', '分类B/猫之眼']);
    },
  );

  test('metadata directory wins over nested metadata directories', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
    ];
    ops.dirs['/manga/猫之眼/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '第01章', isDirectory: true),
    ];
    ops.dirs['/manga/猫之眼/第01章/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/猫之眼/第01章/嵌套漫画/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/猫之眼/metadata.json'] = jsonEncode({
      'title': '猫之眼',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });

    final sync = await _synchronizeAndComplete();
    final comics = await RemoteLibrarySource.loadComics(1);

    expect(sync.success, isTrue);
    expect(comics.data, hasLength(1));
    expect(comics.data.single.id, '猫之眼');
    expect(ops.readPaths, contains('/manga/猫之眼/'));
    expect(ops.readPaths, isNot(contains('/manga/猫之眼/第01章/嵌套漫画/')));
  });

  test(
    'incremental sync rebuilds snapshots from the old cache format',
    () async {
      const comicId = 'Cached Book';
      final config = RemoteLibraryConfig.fromSettings();
      final cache = RemoteLibraryRepository.instance;
      (await cache.replaceDirectoryIndex(config.cacheKey, const [
        RemoteLibraryRemoteDirectory(id: comicId, sortIndex: 0, eTag: 'v1'),
      ]));
      (await cache.upsertSnapshot(
        config.cacheKey,
        const RemoteLibraryCachedComic(
          id: comicId,
          sortIndex: 0,
          title: comicId,
          author: '',
          tags: [],
          cover: '/manga/Cached Book/cover.jpg',
          snapshot: {
            'title': comicId,
            'author': '',
            'tags': [],
            'cover': '/manga/Cached Book/cover.jpg',
            'chapters': {
              'Chapter 01': 'Chapter 01',
              'Chapter 02': 'Chapter 02',
              'Chapter 03': 'Chapter 03',
            },
            'metadataChapters': {},
            'rootImages': [],
          },
          remoteETag: 'v1',
          remoteModifiedAt: null,
        ),
      ));
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: comicId, isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Cached Book/'] = const [
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        RemoteLibraryEntry(name: 'Chapter 01', isDirectory: true),
        RemoteLibraryEntry(name: 'Chapter 02', isDirectory: true),
        RemoteLibraryEntry(name: 'Chapter 03', isDirectory: true),
        RemoteLibraryEntry(name: 'Chapter 04', isDirectory: true),
        RemoteLibraryEntry(name: 'Chapter 05', isDirectory: true),
      ];
      for (var i = 1; i <= 5; i++) {
        ops.dirs['/manga/Cached Book/Chapter 0$i/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }

      final sync = await _synchronizeAndComplete();
      final details = await RemoteLibrarySource.loadComicInfo(comicId);

      expect(sync.success, isTrue);
      expect(details.success, isTrue);
      expect(details.data.chapters!.allChapters, hasLength(5));
      expect(ops.readPaths, [
        '/manga/',
        '/manga/Cached Book/',
        '/manga/Cached Book/Chapter 01/',
        '/manga/Cached Book/Chapter 02/',
        '/manga/Cached Book/Chapter 03/',
        '/manga/Cached Book/Chapter 04/',
        '/manga/Cached Book/Chapter 05/',
      ]);
    },
  );

  test(
    'loadComicInfo handles Chinese comic and chapter directories from unmodifiable lists',
    () async {
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        const RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        const RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第02卷/'] = List.unmodifiable([
        const RemoteLibraryEntry(name: '001.webp', isDirectory: false),
      ]);

      final result = await RemoteLibrarySource.loadComicInfo('猫之眼[北条司]');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
      });
      expect(ops.readPaths, [
        '/manga/猫之眼[北条司]/',
        '/manga/猫之眼[北条司]/第01卷/',
        '/manga/猫之眼[北条司]/第02卷/',
      ]);
    },
  );

  test('loadComicInfo uses root cover and root images when present', () async {
    ops.dirs['/manga/Cat Eye/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final result = await RemoteLibrarySource.loadComicInfo('Cat Eye');

    expect(result.success, isTrue);
    expect(result.data.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.data.chapters, isNull);
  });

  test('loadComicPages returns chapter image paths in reading order', () async {
    ops.dirs['/manga/Cat Eye/第01卷/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '010.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
    ];

    final result = await RemoteLibrarySource.loadComicPages('Cat Eye', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/Cat Eye/第01卷/002.jpg',
      '/manga/Cat Eye/第01卷/010.jpg',
    ]);
  });

  test(
    'reopening reuses persisted chapter pages and library refresh updates them',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: '第01卷', isDirectory: true),
      ];
      ops.dirs['/manga/Book/第01卷/'] = const [
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      expect((await RemoteLibrarySource.loadComicInfo('Book')).success, isTrue);
      final initial = await RemoteLibrarySource.loadComicPages('Book', '第01卷');
      expect(initial.data, [
        '/manga/Book/第01卷/001.jpg',
        '/manga/Book/第01卷/002.jpg',
      ]);
      expect(ops.readPaths, ['/manga/Book/', '/manga/Book/第01卷/']);

      // Close the database and clear the source's memory cache, retaining files.
      await RemoteLibrarySource.resetCacheForTesting();
      ops.readPaths.clear();
      expect((await RemoteLibrarySource.loadComicInfo('Book')).success, isTrue);
      expect(
        (await RemoteLibrarySource.loadComicPages('Book', '第01卷')).data,
        initial.data,
      );
      expect(ops.readPaths, isEmpty);

      ops.dirs['/manga/Book/第01卷/'] = const [
        RemoteLibraryEntry(name: '003.jpg', isDirectory: false),
      ];
      expect((await _synchronizeAndComplete(force: true)).success, isTrue);
      expect((await RemoteLibrarySource.loadComicPages('Book', '第01卷')).data, [
        '/manga/Book/第01卷/003.jpg',
      ]);
    },
  );

  test('loadComicPages handles Chinese directory paths', () async {
    ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
      const RemoteLibraryEntry(name: '010.jpg', isDirectory: false),
      const RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
    ]);

    final result = await RemoteLibrarySource.loadComicPages('猫之眼[北条司]', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/猫之眼[北条司]/第01卷/002.jpg',
      '/manga/猫之眼[北条司]/第01卷/010.jpg',
    ]);
  });

  test(
    'CBZ metadata enriches list and details and maps virtual chapter pages',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼[北条司]/'] = const [
        RemoteLibraryEntry(name: 'metadata.JSON', isDirectory: false),
        RemoteLibraryEntry(name: 'ComicInfo.xml', isDirectory: false),
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '0004.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '0002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '0001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '0003.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/猫之眼[北条司]/metadata.JSON'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作', '漫画'],
        'description': '一位怪盗与刑警之间的故事。',
        'chapters': [
          {'title': '第01卷', 'start': 1, 'end': 2},
          {'title': '第02卷', 'start': 3, 'end': 4},
        ],
      });

      await RemoteLibrarySource.loadComics(1);
      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      final details = await RemoteLibrarySource.loadComicInfo('猫之眼[北条司]');
      final pages = await RemoteLibrarySource.loadComicPages(
        '猫之眼[北条司]',
        '__cbz_range_1',
      );

      expect(comics.success, isTrue);
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.subtitle, isNull);
      expect(comics.data.single.tags, ['动作', '漫画']);
      expect(comics.data.single.cover, '/manga/猫之眼[北条司]/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.title, '猫之眼');
      expect(details.data.subTitle, isNull);
      expect(details.data.description, '一位怪盗与刑警之间的故事。');
      expect(details.data.tags, {
        '作者': ['北条司'],
        '标签': ['动作', '漫画'],
      });
      expect(details.data.chapters!.allChapters, {
        '__cbz_range_0': '第01卷',
        '__cbz_range_1': '第02卷',
      });
      expect(details.data.maxPage, 4);
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/猫之眼[北条司]/0003.jpg',
        '/manga/猫之眼[北条司]/0004.jpg',
      ]);
      expect(ops.textReadPaths, ['/manga/猫之眼[北条司]/metadata.JSON']);
    },
  );

  test(
    'CBZ metadata without chapters keeps root pages as one chapter',
    () async {
      ops.dirs['/manga/Flat Book/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '0002.webp', isDirectory: false),
        RemoteLibraryEntry(name: '0001.webp', isDirectory: false),
      ];
      ops.textFiles['/manga/Flat Book/metadata.json'] = jsonEncode({
        'title': 'Flat Export',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });

      final details = await RemoteLibrarySource.loadComicInfo('Flat Book');
      final pages = await RemoteLibrarySource.loadComicPages('Flat Book', null);

      expect(details.success, isTrue);
      expect(details.data.title, 'Flat Export');
      expect(details.data.chapters, isNull);
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/Flat Book/0001.webp',
        '/manga/Flat Book/0002.webp',
      ]);
    },
  );

  test('malformed CBZ metadata falls back to folder inference', () async {
    ops.dirs['/manga/Broken Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Broken Book/metadata.json'] = '{broken';

    final details = await RemoteLibrarySource.loadComicInfo('Broken Book');
    final pages = await RemoteLibrarySource.loadComicPages(
      'Broken Book',
      RemoteLibrarySource.rootChapterId,
    );

    expect(details.success, isTrue);
    expect(details.data.title, 'Broken Book');
    expect(details.data.chapters, isNull);
    expect(pages.success, isTrue);
    expect(pages.data, ['/manga/Broken Book/001.jpg']);
  });

  for (final invalidCase in <String, List<Map<String, Object>>>{
    'out-of-range': [
      {'title': 'Chapter 1', 'start': 1, 'end': 3},
    ],
    'overlapping': [
      {'title': 'Chapter 1', 'start': 1, 'end': 2},
      {'title': 'Chapter 2', 'start': 2, 'end': 2},
    ],
    'reversed': [
      {'title': 'Chapter 1', 'start': 2, 'end': 1},
    ],
  }.entries) {
    test(
      '${invalidCase.key} CBZ chapter ranges fall back to root pages',
      () async {
        ops.dirs['/manga/Invalid Book/'] = const [
          RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
          RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/Invalid Book/metadata.json'] = jsonEncode({
          'title': 'Must Not Replace Folder Name',
          'author': 'Author',
          'tags': ['tag'],
          'chapters': invalidCase.value,
        });

        final details = await RemoteLibrarySource.loadComicInfo('Invalid Book');
        final pages = await RemoteLibrarySource.loadComicPages(
          'Invalid Book',
          null,
        );

        expect(details.success, isTrue);
        expect(details.data.title, 'Invalid Book');
        expect(details.data.chapters, isNull);
        expect(pages.success, isTrue);
        expect(pages.data, [
          '/manga/Invalid Book/001.jpg',
          '/manga/Invalid Book/002.jpg',
        ]);
      },
    );
  }

  test(
    'getImageLoadingConfig builds encoded URL and basic auth header',
    () async {
      final config = await RemoteLibrarySource.getImageLoadingConfig(
        '/manga/Cat Eye/第01卷/001.jpg',
        'Cat Eye',
        '第01卷',
      );

      expect(
        config['url'],
        'https://example.com/dav/manga/Cat%20Eye/%E7%AC%AC01%E5%8D%B7/001.jpg',
      );
      expect(config['headers'], {'authorization': 'Basic dXNlcjpwYXNz'});
    },
  );
  test('legacy thumbnails retain encoded URLs and basic auth headers', () async {
    final config = await RemoteLibrarySource.getThumbnailLoadingConfig(
      '/manga/Cat Eye/第01卷/cover.jpg',
    );
    expect(config, {
      'url':
          'https://example.com/dav/manga/Cat%20Eye/%E7%AC%AC01%E5%8D%B7/cover.jpg',
      'headers': {'authorization': 'Basic dXNlcjpwYXNz'},
    });
    expect(
      await RemoteLibrarySource.getThumbnailLoadingConfig('cover.Cat Eye'),
      {
        'headers': {'authorization': 'Basic dXNlcjpwYXNz'},
      },
    );
  });
  for (final connectedAtScan in [true, false]) {
    test(
      'metadata id binds through ${connectedAtScan ? 'library scan' : 'cached details after connection'} and uploads progress',
      () async {
        ops.dirs['/manga/'] = const [
          RemoteLibraryEntry(name: 'Book', isDirectory: true),
        ];
        ops.dirs['/manga/Book/'] = const [
          RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        final document = jsonEncode({
          'title': 'Local title',
          'author': 'Local author',
          'tags': <String>[],
          'bangumiSubjectId': 123,
        });
        ops.textFiles['/manga/Book/metadata.json'] = document;
        final previous = <String, dynamic>{
          for (final key in [
            'bangumiAccessToken',
            'bangumiUsername',
            'bangumiBindings',
            'bangumiAutoSyncEnabled',
          ])
            key: appdata.settings[key],
        };
        appdata.settings['bangumiAccessToken'] = connectedAtScan ? 'token' : '';
        appdata.settings['bangumiUsername'] = connectedAtScan ? 'alice' : '';
        appdata.settings['bangumiBindings'] = <String, dynamic>{};
        appdata.settings['bangumiAutoSyncEnabled'] = true;
        final gateway = _MetadataBindingGateway();
        final saved = Completer<void>();
        final service = BangumiService.forTesting(
          gatewayFactory: (_) => gateway,
          scopeResolver: (_) => RemoteLibrarySource.currentLibraryId,
          saveSettings: () async {
            if (!saved.isCompleted) saved.complete();
          },
        );
        addTearDown(() {
          RemoteLibrarySource.configureMetadataSubjectHandler(null);
          service.dispose();
          for (final entry in previous.entries) {
            appdata.settings[entry.key] = entry.value;
          }
        });
        RemoteLibrarySource.configureMetadataSubjectHandler(
          service.bindFromMetadata,
        );

        expect((await _synchronizeAndComplete()).success, isTrue);
        final reads = List<String>.from(ops.readPaths);
        if (!connectedAtScan) {
          expect(service.bindingFor('webdav_library', 'Book'), isNull);
          appdata.settings['bangumiAccessToken'] = 'token';
          appdata.settings['bangumiUsername'] = 'alice';
        } else {
          await saved.future;
        }
        final details = await RemoteLibrarySource.loadComicInfo('Book');
        await saved.future;
        final binding = service.bindingFor('webdav_library', 'Book')!;
        expect(binding.subjectId, 123);
        expect(binding.scopeId, RemoteLibrarySource.currentLibraryId);
        expect(binding.progressMode, BangumiProgressMode.auto);
        expect(details.data.title, 'Local title');
        expect(ops.readPaths, reads);
        expect(ops.textFiles['/manga/Book/metadata.json'], document);
        expect(ops.writeRequests, isEmpty);
        await service.onChapterCompleted(
          sourceKey: 'webdav_library',
          comicId: 'Book',
          chapterTitle: '第6话',
        );
        expect(gateway.collection.epStatus, 6);
        expect(gateway.collection.volStatus, 2);
        expect(gateway.collection.rate, 7);
      },
    );
  }

  test('missing metadata is scraped and written back to WebDAV', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    final scrapedTitles = <String>[];
    RemoteLibrarySource.configureMetadataScraper((input) async {
      scrapedTitles.add(input.title);
      return const ComicMetaData(
        title: 'Cat Eye',
        author: 'Tsukasa Hojo',
        tags: ['Action'],
        description: 'A trio of sisters run a café by day.',
        bangumiSubjectId: 123,
      );
    });

    final sync = await _synchronizeAndComplete();
    final comics = await RemoteLibrarySource.loadComics(1);
    final written = jsonDecode(
      ops.writtenTexts['/manga/Cat Eye[Tsukasa Hojo]/metadata.json']!,
    );

    expect(sync.success, isTrue);
    expect(scrapedTitles, ['Cat Eye[Tsukasa Hojo]']);
    expect(written, {
      'title': 'Cat Eye',
      'author': 'Tsukasa Hojo',
      'tags': ['Action'],
      'description': 'A trio of sisters run a café by day.',
      'chapters': null,
      'bangumiSubjectId': 123,
    });
    expect(ops.writeRequests.single.createOnly, isTrue);
    expect(comics.data.single.title, 'Cat Eye');
    expect(comics.data.single.subtitle, isNull);
  });

  test(
    'a later Bangumi connection scrapes an unchanged cached comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var enabled = false;
      var scrapeCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        scrapeCalls++;
        return const ComicMetaData(
          title: 'Matched book',
          author: 'Author',
          tags: [],
          bangumiSubjectId: 321,
        );
      }, isEnabled: () => enabled);
      await _synchronizeAndComplete();
      enabled = true;

      final sync = await _synchronizeAndComplete();

      expect(sync.success, isTrue);
      expect(scrapeCalls, 1);
      expect(ops.writtenTexts, contains('/manga/Book/metadata.json'));
    },
  );

  test('existing metadata is never replaced by automatic scraping', () async {
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Book/metadata.json'] = jsonEncode({
      'title': 'Existing title',
      'author': 'Existing author',
      'tags': ['Existing tag'],
      'chapters': null,
    });
    var scrapeCalls = 0;
    RemoteLibrarySource.configureMetadataScraper((_) async {
      scrapeCalls++;
      return const ComicMetaData(
        title: 'Replacement',
        author: 'Replacement',
        tags: [],
        bangumiSubjectId: 456,
      );
    });

    final details = await RemoteLibrarySource.loadComicInfo('Book');

    expect(details.success, isTrue);
    expect(details.data.title, 'Existing title');
    expect(scrapeCalls, 0);
    expect(ops.writtenTexts, isEmpty);
  });

  test('manual metadata writes preserve existing chapter ranges', () async {
    ops.dirs['/manga/Flat Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.JSON', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Flat Book/metadata.JSON'] = jsonEncode({
      'title': 'Old title',
      'author': 'Old author',
      'tags': ['Old tag'],
      'description': 'Existing description',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
    });

    await RemoteLibrarySource.writeMetadata(
      'Flat Book',
      const ComicMetaData(
        title: 'Bangumi title',
        author: 'Bangumi author',
        tags: ['Bangumi tag'],
        bangumiSubjectId: 789,
      ),
    );
    final written = jsonDecode(
      ops.writtenTexts['/manga/Flat Book/metadata.JSON']!,
    );

    expect(written, {
      'title': 'Bangumi title',
      'author': 'Bangumi author',
      'tags': ['Bangumi tag'],
      'description': '',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
      'bangumiSubjectId': 789,
    });
    final details = await RemoteLibrarySource.loadComicInfo('Flat Book');
    expect(details.data.title, 'Bangumi title');
    expect(details.data.subTitle, isNull);
    expect(details.data.description, '');
    expect(details.data.externalIds, {'bangumi': '789'});
    expect(details.data.tags, {
      '作者': ['Bangumi author'],
      '标签': ['Bangumi tag'],
    });
  });

  test('manual metadata merge retries an ETag conflict', () async {
    const path = '/manga/Flat Book/metadata.json';
    ops.dirs['/manga/Flat Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Old',
      'author': 'Old',
      'tags': ['Old'],
      'chapters': [
        {'title': 'Old chapter', 'start': 1, 'end': 1},
      ],
      'extension': {'preserve': true},
    });
    ops.textETags[path] = '"1"';
    ops.beforeWrite = (writtenPath, writeNumber) {
      if (writtenPath != path || writeNumber != 1) return;
      ops.textFiles[path] = jsonEncode({
        'title': 'Concurrent',
        'author': 'Concurrent',
        'tags': ['Concurrent'],
        'chapters': [
          {'title': 'Concurrent chapter', 'start': 1, 'end': 2},
        ],
        'extension': {'preserve': true},
      });
      ops.textETags[path] = '"2"';
    };

    await RemoteLibrarySource.writeMetadata(
      'Flat Book',
      const ComicMetaData(
        title: 'Selected subject',
        author: '',
        tags: [],
        description: '',
        bangumiSubjectId: 42,
      ),
    );

    final written = jsonDecode(ops.writtenTexts[path]!) as Map;
    expect(ops.writeRequests.map((request) => request.ifMatch), ['"1"', '"2"']);
    expect(written['title'], 'Selected subject');
    expect(written['author'], '');
    expect(written['tags'], isEmpty);
    expect(written['description'], '');
    expect(written['chapters'], [
      {'title': 'Concurrent chapter', 'start': 1, 'end': 2},
    ]);
    expect(written['extension'], {'preserve': true});
  });

  test('weak ETag falls back to Last-Modified for metadata updates', () async {
    const path = '/manga/Book/metadata.json';
    const modifiedAt = 1700000000000;
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Existing',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    ops.textETags[path] = 'w/"1"';
    ops.textModifiedAt[path] = modifiedAt;

    await RemoteLibrarySource.writeMetadata(
      'Book',
      const ComicMetaData(
        title: 'Replacement',
        author: '',
        tags: [],
        bangumiSubjectId: 43,
      ),
    );

    expect(ops.writeRequests.single.ifMatch, isNull);
    expect(ops.writeRequests.single.ifUnmodifiedSince, modifiedAt);
  });

  test(
    'weak ETag without Last-Modified safely rejects metadata update',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'Existing',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      ops.textETags[path] = 'W/"1"';

      await expectLater(
        RemoteLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Replacement',
            author: '',
            tags: [],
            bangumiSubjectId: 44,
          ),
        ),
        throwsA(isA<RemoteLibraryUnsupportedException>()),
      );

      expect(ops.writeRequests, isEmpty);
    },
  );

  test('metadata merge salvages valid chapters from invalid fields', () async {
    const path = '/manga/Broken Book/metadata.json';
    ops.dirs['/manga/Broken Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 7,
      'author': false,
      'tags': 'invalid',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
    });

    await RemoteLibrarySource.writeMetadata(
      'Broken Book',
      const ComicMetaData(
        title: 'Recovered',
        author: 'Author',
        tags: ['Tag'],
        bangumiSubjectId: 43,
      ),
    );

    final written = jsonDecode(ops.writtenTexts[path]!) as Map;
    expect(written['chapters'], [
      {'title': 'Volume 1', 'start': 1, 'end': 2},
    ]);
    expect(written['title'], 'Recovered');
    expect(written['bangumiSubjectId'], 43);
  });

  test('unsafe validatorless updates are retained as pending', () async {
    const path = '/manga/Book/metadata.json';
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Existing',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    ops.validatorlessPaths.add(path);

    await expectLater(
      RemoteLibrarySource.writeMetadata(
        'Book',
        const ComicMetaData(
          title: 'Replacement',
          author: '',
          tags: [],
          bangumiSubjectId: 44,
        ),
      ),
      throwsA(isA<RemoteLibraryUnsupportedException>()),
    );

    final pending = RemoteLibrarySource.metadataPendingStatuses.single;
    expect(pending.comicId, 'Book');
    expect(pending.subjectId, 44);
    expect(pending.attempts, 1);
    expect(pending.failure, RemoteLibraryMetadataPendingFailure.unsupported);
    expect(ops.writtenTexts, isEmpty);
  });

  test(
    'transient metadata failures can be retried from the local queue',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.beforeWrite = (writtenPath, writeNumber) {
        if (writtenPath == path && writeNumber == 1) {
          throw RemoteLibraryTransientException(path);
        }
      };

      await expectLater(
        RemoteLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Book',
            author: '',
            tags: [],
            bangumiSubjectId: 45,
          ),
        ),
        throwsA(isA<RemoteLibraryTransientException>()),
      );
      expect(
        RemoteLibrarySource.metadataPendingStatuses.single.failure,
        RemoteLibraryMetadataPendingFailure.transient,
      );

      ops.beforeWrite = null;
      await RemoteLibrarySource.retryPendingMetadata(force: true);

      expect(RemoteLibrarySource.metadataPendingStatuses, isEmpty);
      expect(ops.writtenTexts, contains(path));
    },
  );

  test(
    'metadata write guard rejects a stale binding without queuing it',
    () async {
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      RemoteLibrarySource.configureMetadataWriteGuard((_, _, _) => false);

      await expectLater(
        RemoteLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Book',
            author: '',
            tags: [],
            bangumiSubjectId: 46,
          ),
        ),
        throwsA(isA<RemoteLibraryMetadataWriteRejectedException>()),
      );

      expect(RemoteLibrarySource.metadataPendingStatuses, isEmpty);
      expect(ops.writeRequests, isEmpty);
    },
  );

  test(
    'nested unmarked comic directories are discovered conservatively',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        RemoteLibraryEntry(name: 'Author', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/Book/'] = const [
        RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/Book/第01卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Author/Book/第02卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(comics.data.map((comic) => comic.id), ['Category/Author/Book']);
    },
  );

  test(
    'chapters with non-standard or Chinese volume names are treated as chapters instead of individual comics',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
        RemoteLibraryEntry(name: '番外合集', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/番外合集/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      final details = await RemoteLibrarySource.loadComicInfo('猫之眼');

      expect(comics.data.map((comic) => comic.id), ['猫之眼']);
      expect(details.data.chapters!.allChapters, {
        '第一卷': '第一卷',
        '第二卷': '第二卷',
        '番外合集': '番外合集',
      });
    },
  );

  test(
    'multi-level category directory discovers child comics without classifying category as comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '少年漫画', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
        RemoteLibraryEntry(name: '城市猎人', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['少年漫画/城市猎人', '少年漫画/猫之眼']);
    },
  );

  test(
    'empty child directories do not prevent parent comic from being discovered',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
        RemoteLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/临时文件/'] = const [];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['猫之眼']);
    },
  );

  test(
    'flat category containing multiple leaf comic books is not merged into one comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '少年漫画', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
        RemoteLibraryEntry(name: '城市猎人', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      ];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['少年漫画/城市猎人', '少年漫画/猫之眼']);
    },
  );

  test(
    'child metadata takes precedence over chapter-like directory names',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        RemoteLibraryEntry(name: '01', isDirectory: true),
        RemoteLibraryEntry(name: '02', isDirectory: true),
      ];
      ops.dirs['/manga/Category/01/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/02/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), [
        'Category/01',
        'Category/02',
      ]);
    },
  );

  test(
    'empty child directory is excluded from chapter list and details',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
        RemoteLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/临时文件/'] = const [];

      await _synchronizeAndComplete();
      final details = await RemoteLibrarySource.loadComicInfo('猫之眼');
      expect(details.data.chapters!.allChapters.keys, ['第一卷', '第二卷']);
    },
  );

  test(
    'transient child directory read failure does not guess category as comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true),
        RemoteLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.errors['/manga/Category/Book B/'] = StateError(
        'transient network failure',
      );

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isFalse);
    },
  );

  test(
    'discovery depth limit fails closed without classifying ancestor as comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'L1', isDirectory: true),
      ];
      var current = '/manga/L1/';
      for (var index = 2; index <= 9; index++) {
        ops.dirs[current] = [
          RemoteLibraryEntry(name: 'L$index', isDirectory: true),
        ];
        current = '${current}L$index/';
      }
      ops.dirs[current] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['${current}Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isFalse);

      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.error, isTrue);
      expect(
        await RemoteLibraryRepository.instance.count(
          RemoteLibraryConfig.fromSettings().cacheKey,
        ),
        0,
      );
    },
  );

  test('发现触及目录上限后保留已确认作品并报告失败', () async {
    RemoteLibrarySource.discoveryDirectoryLimitOverride = 3;
    addTearDown(() {
      RemoteLibrarySource.discoveryDirectoryLimitOverride = null;
    });

    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'A', isDirectory: true),
      RemoteLibraryEntry(name: 'B', isDirectory: true),
      RemoteLibraryEntry(name: 'C', isDirectory: true),
      RemoteLibraryEntry(name: 'D', isDirectory: true),
    ];
    ops.dirs['/manga/A/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/B/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/C/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/D/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final sync = await _synchronizeAndComplete();
    expect(sync.success, isFalse);

    final comics = await RemoteLibrarySource.loadComics(1);
    expect(comics.data.map((comic) => comic.id), ['A', 'B', 'C']);
    expect(
      await RemoteLibraryRepository.instance.lastSuccessfulSync(
        RemoteLibraryConfig.fromSettings().cacheKey,
      ),
      0,
    );
  });

  test(
    'top-level directory read failure preserves the previous successful index',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true),
        RemoteLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Book B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final firstSync = await _synchronizeAndComplete();
      expect(firstSync.success, isTrue);
      final firstComics = await RemoteLibrarySource.loadComics(1);
      expect(firstComics.data.map((c) => c.id), [
        'Category/Book A',
        'Category/Book B',
      ]);

      ops.errors['/manga/Category/'] = StateError('temporary connection error');
      final secondSync = await _synchronizeAndComplete(force: true);
      expect(secondSync.success, isFalse);

      final secondComics = await RemoteLibrarySource.loadComics(1);
      expect(secondComics.data.map((c) => c.id), [
        'Category/Book A',
        'Category/Book B',
      ]);
    },
  );

  test(
    'metadata comic excludes empty child directories from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/临时文件/'] = const [];
      ops.textFiles['/manga/Comic/metadata.json'] = jsonEncode({
        'title': 'Comic',
      });

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);

      final details = await RemoteLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第一卷']);
    },
  );

  test(
    'root-image comic excludes empty child directories from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: 'Chapter 1', isDirectory: true),
        RemoteLibraryEntry(name: 'temp', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/Chapter 1/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/temp/'] = const [];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);

      final details = await RemoteLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, [
        'Chapter 1',
        '__root__',
      ]);
    },
  );

  test('empty child cover is not used as comic cover', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Comic', isDirectory: true),
    ];
    ops.dirs['/manga/Comic/'] = const [
      RemoteLibraryEntry(name: '第一卷', isDirectory: true),
      RemoteLibraryEntry(name: '临时文件', isDirectory: true),
    ];
    ops.dirs['/manga/Comic/第一卷/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/Comic/临时文件/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
    ];

    final sync = await _synchronizeAndComplete();
    expect(sync.success, isTrue);

    final details = await RemoteLibrarySource.loadComicInfo('Comic');
    expect(details.data.cover, '/manga/Comic/第一卷/001.jpg');
    expect(details.data.chapters!.allChapters.keys, ['第一卷']);
  });

  test(
    'flat category scraping targets leaf comics instead of category',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        RemoteLibraryEntry(name: 'Book A', isDirectory: true),
        RemoteLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Book B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final scrapedTitles = <String>[];
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scrapedTitles.add(input.title);
        return ComicMetaData(
          title: input.title,
          author: 'Author',
          tags: const ['Action'],
          description: '',
        );
      });

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);
      expect(scrapedTitles, ['Book A', 'Book B']);
      expect(scrapedTitles, isNot(contains('Category')));
    },
  );

  test(
    'automatic scraping targets only comic root and does not scrape or write to chapter folders',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final scrapedTitles = <String>[];
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scrapedTitles.add(input.title);
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: 'A trio of sisters run a café by day.',
          bangumiSubjectId: 123,
        );
      });

      final sync = await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(scrapedTitles, ['Cat Eye[Tsukasa Hojo]']);
      expect(ops.writtenTexts.keys, [
        '/manga/Cat Eye[Tsukasa Hojo]/metadata.json',
      ]);
      expect(comics.data.single.title, 'Cat Eye');
    },
  );

  test(
    'synchronization evicts stale chapter comics cached by previous buggy versions',
    () async {
      final config = RemoteLibraryConfig.fromSettings();
      final cache = RemoteLibraryRepository.instance;
      (await cache.replaceDirectoryIndex(config.cacheKey, const [
        RemoteLibraryRemoteDirectory(id: 'Cat Eye/第一卷', sortIndex: 0),
        RemoteLibraryRemoteDirectory(id: 'Cat Eye/第二卷', sortIndex: 1),
      ]));
      (await cache.upsertSnapshot(
        config.cacheKey,
        const RemoteLibraryCachedComic(
          id: 'Cat Eye/第一卷',
          sortIndex: 0,
          title: '第一卷',
          author: '',
          tags: [],
          cover: '',
          snapshot: {
            'title': '第一卷',
            'author': '',
            'tags': [],
            'cover': '',
            'chapters': {'root': 'root'},
            'metadataChapters': {},
            'rootImages': ['001.jpg'],
          },
          remoteETag: 'v1',
          remoteModifiedAt: null,
        ),
      ));

      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/'] = const [
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/第一卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(comics.data.map((c) => c.id), ['Cat Eye']);
      expect((await cache.find(config.cacheKey, 'Cat Eye/第一卷')), isNull);
      expect((await cache.find(config.cacheKey, 'Cat Eye/第二卷')), isNull);
    },
  );

  test(
    'single volume directory such as 全1卷 is recognized as chapter instead of comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/'] = const [
        RemoteLibraryEntry(name: '全1卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/全1卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final scrapedTitles = <String>[];
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scrapedTitles.add(input.title);
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: '',
        );
      });

      final sync = await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);
      final details = await RemoteLibrarySource.loadComicInfo('Cat Eye');

      expect(sync.success, isTrue);
      expect(comics.data.map((c) => c.id), ['Cat Eye']);
      expect(details.data.chapters!.allChapters.keys, ['全1卷']);
      expect(scrapedTitles, ['Cat Eye']);
      expect(scrapedTitles, isNot(contains('全1卷')));
      expect(ops.writtenTexts.keys, ['/manga/Cat Eye/metadata.json']);
      expect(
        ops.writtenTexts.keys,
        isNot(contains('/manga/Cat Eye/全1卷/metadata.json')),
      );
    },
  );

  test(
    'a long-title book with cover, matching ZIP and 全1卷 keeps its 158-page directory comic',
    () async {
      const book = '猫之眼 完全珍藏版 作者：[北条司] 语言：[Chinese]';
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: book, isDirectory: true),
      ];
      ops.dirs['/manga/$book/'] = const [
        RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        RemoteLibraryEntry(
          name: '$book.zip',
          isDirectory: false,
          size: 4096,
          eTag: 'zip-v1',
        ),
        RemoteLibraryEntry(name: '全1卷', isDirectory: true),
      ];
      ops.dirs['/manga/$book/全1卷/'] = [
        const RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        for (var page = 158; page >= 1; page--)
          RemoteLibraryEntry(
            name: '${page.toString().padLeft(3, '0')}.jpg',
            isDirectory: false,
          ),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.success, isTrue, reason: comics.errorMessage);
      expect(comics.data.map((comic) => comic.id), [book, '$book/$book.zip']);
      final directoryComic = comics.data.firstWhere(
        (comic) => comic.id == book,
      );
      expect(directoryComic.title, book);
      expect(directoryComic.cover, '/manga/$book/cover.png');
      expect(
        comics.data.map((comic) => comic.id),
        isNot(contains('$book/全1卷')),
      );

      final details = await RemoteLibrarySource.loadComicInfo(book);
      expect(details.success, isTrue, reason: details.errorMessage);
      expect(details.data.title, book);
      expect(details.data.cover, '/manga/$book/cover.png');
      expect(details.data.chapters!.allChapters, {'全1卷': '全1卷'});
      expect(details.data.maxPage, 158);
      final readsBeforePages = ops.readPaths.length;
      final pages = await RemoteLibrarySource.loadComicPages(book, '全1卷');
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(pages.data, [
        for (var page = 1; page <= 158; page++)
          '/manga/$book/全1卷/${page.toString().padLeft(3, '0')}.jpg',
      ]);
      expect(ops.readPaths, hasLength(readsBeforePages));
      final cachedArchive =
          (await RemoteLibraryRepository.instance.find(
                RemoteLibraryConfig.fromSettings().cacheKey,
                '$book/$book.zip',
              ))!.snapshot!['archive']
              as Map;
      expect(cachedArchive['index'], isNull);
    },
  );

  test(
    'Chinese chapter names stay under their book beside real and ZIP-only categories',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: '猫之眼', isDirectory: true),
        RemoteLibraryEntry(name: '少年漫画', isDirectory: true),
        RemoteLibraryEntry(name: '压缩包分类', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
        RemoteLibraryEntry(name: '番外合集', isDirectory: true),
        RemoteLibraryEntry(name: '猫之眼.zip', isDirectory: false, size: 4096),
      ];
      for (final chapter in ['第一卷', '第二卷', '番外合集']) {
        ops.dirs['/manga/猫之眼/$chapter/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
          RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        ];
      }
      ops.dirs['/manga/少年漫画/'] = const [
        RemoteLibraryEntry(name: '城市猎人', isDirectory: true),
        RemoteLibraryEntry(name: '平面漫画', isDirectory: true),
        RemoteLibraryEntry(name: '旁边的漫画.zip', isDirectory: false, size: 4096),
      ];
      for (final title in ['城市猎人', '平面漫画']) {
        ops.dirs['/manga/少年漫画/$title/'] = const [
          RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }
      ops.dirs['/manga/压缩包分类/'] = const [
        RemoteLibraryEntry(name: 'A.zip', isDirectory: false, size: 4096),
        RemoteLibraryEntry(name: 'B.cbz', isDirectory: false, size: 4096),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.success, isTrue, reason: comics.errorMessage);
      expect(
        comics.data.map((comic) => comic.id),
        unorderedEquals([
          '猫之眼',
          '猫之眼/猫之眼.zip',
          '少年漫画/城市猎人',
          '少年漫画/平面漫画',
          '少年漫画/旁边的漫画.zip',
          '压缩包分类/A.zip',
          '压缩包分类/B.cbz',
        ]),
      );
      final details = await RemoteLibrarySource.loadComicInfo('猫之眼');
      expect(details.success, isTrue, reason: details.errorMessage);
      expect(details.data.chapters!.allChapters, {
        '第一卷': '第一卷',
        '第二卷': '第二卷',
        '番外合集': '番外合集',
      });
      expect(details.data.maxPage, 6);
    },
  );

  test(
    'a ZIP inside a chapter does not promote that chapter to an independent image comic',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/Book/第一卷/'] = const [
        RemoteLibraryEntry(name: '第一卷.zip', isDirectory: false, size: 4096),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), [
        'Book',
        'Book/第一卷/第一卷.zip',
      ]);
      final details = await RemoteLibrarySource.loadComicInfo('Book');
      expect(details.success, isTrue, reason: details.errorMessage);
      expect(details.data.chapters!.allChapters, {'第一卷': '第一卷', '第二卷': '第二卷'});
      expect(details.data.maxPage, 3);
    },
  );

  test(
    'root images and a ZIP produce independent comics without counting the archive as a page',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: 'Book.zip', isDirectory: false, size: 4096),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final comics = await RemoteLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['Book', 'Book/Book.zip']);
      final details = await RemoteLibrarySource.loadComicInfo('Book');
      expect(details.success, isTrue, reason: details.errorMessage);
      expect(details.data.chapters, isNull);
      expect(details.data.maxPage, 2);
      final pages = await RemoteLibrarySource.loadComicPages('Book', null);
      expect(pages.data, ['/manga/Book/001.jpg', '/manga/Book/002.jpg']);
    },
  );

  test(
    'page totals include root images and scanned chapters once after lazy inspection',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: 'cover.png', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '第一卷', isDirectory: true),
        RemoteLibraryEntry(name: '第二卷', isDirectory: true),
        RemoteLibraryEntry(name: '临时目录', isDirectory: true),
      ];
      ops.dirs['/manga/Book/第一卷/'] = const [
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '003.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book/第二卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book/临时目录/'] = const [
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final summary = (await RemoteLibraryRepository.instance.find(
        RemoteLibraryConfig.fromSettings().cacheKey,
        'Book',
      ))!.snapshot!;
      expect(summary['chaptersInspected'], isTrue);
      expect((summary['chapterImages'] as Map).keys, ['第一卷', '第二卷']);
      expect(ops.readPaths, contains('/manga/Book/第一卷/'));
      final details = await RemoteLibrarySource.loadComicInfo('Book');
      expect(details.success, isTrue, reason: details.errorMessage);
      expect(details.data.chapters!.allChapters, {
        '第一卷': '第一卷',
        '第二卷': '第二卷',
        RemoteLibrarySource.rootChapterId: RemoteLibrarySource.rootChapterTitle,
      });
      expect(details.data.maxPage, 7);
      final rootPages = await RemoteLibrarySource.loadComicPages('Book', null);
      expect(rootPages.data, ['/manga/Book/001.jpg', '/manga/Book/002.jpg']);
      final cached = (await RemoteLibraryRepository.instance.find(
        RemoteLibraryConfig.fromSettings().cacheKey,
        'Book',
      ))!.snapshot!;
      final chapterImages = cached['chapterImages'] as Map;
      expect(chapterImages.keys, ['第一卷', '第二卷']);
      expect(chapterImages['第一卷'], hasLength(3));
      expect(chapterImages['第二卷'], hasLength(2));
    },
  );

  test(
    'metadata comic excludes empty chapter-named directory from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
        RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第01卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/第02卷/'] = const [];
      ops.textFiles['/manga/Comic/metadata.json'] = jsonEncode({
        'title': 'Comic',
        'author': '',
      });

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);

      final details = await RemoteLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第01卷']);
    },
  );

  test(
    'chapter with only named cover is excluded from chapters and comic cover',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        RemoteLibraryEntry(name: '第01卷', isDirectory: true),
        RemoteLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第01卷/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/第02卷/'] = const [
        RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      ];

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);

      final details = await RemoteLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第01卷']);
      expect(details.data.cover, '/manga/Comic/第01卷/001.jpg');
    },
  );

  test(
    'noMatch negative scrape cache is preserved across forced sync',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        scraperCalls++;
        return null;
      });

      final firstSync = await _synchronizeAndComplete();
      expect(firstSync.success, isTrue);
      expect(scraperCalls, 1);

      final secondSync = await _synchronizeAndComplete(force: true);
      expect(secondSync.success, isTrue);
      expect(scraperCalls, 1);
    },
  );

  test(
    'noMatch negative scrape cache is preserved when comic pages change',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'p1'),
      ];
      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        scraperCalls++;
        return null;
      });

      await _synchronizeAndComplete();
      expect(scraperCalls, 1);

      ops.dirs['/manga/Unmatched Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'p1'),
        RemoteLibraryEntry(name: '002.jpg', isDirectory: false, eTag: 'p2'),
      ];

      await _synchronizeAndComplete();
      expect(scraperCalls, 1);
    },
  );

  test(
    'validatorless WebDAV comic does not loop scraper queries on subsequent syncs',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        scraperCalls++;
        return null;
      });

      await _synchronizeAndComplete();
      expect(scraperCalls, 1);

      await _synchronizeAndComplete();
      expect(scraperCalls, 1);
    },
  );

  test('scraperVersion change retries an existing noMatch comic', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Unmatched Book', isDirectory: true),
    ];
    ops.dirs['/manga/Unmatched Book/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    RemoteLibrarySource.configureMetadataScraper((_) async {
      scraperCalls++;
      return null;
    }, scraperVersion: '1');

    await _synchronizeAndComplete();
    expect(scraperCalls, 1);

    RemoteLibrarySource.configureMetadataScraper((_) async {
      scraperCalls++;
      return null;
    }, scraperVersion: '2');

    await _synchronizeAndComplete();
    expect(scraperCalls, 2);
  });

  test(
    'automatic scraping is skipped when scraper is disabled in settings',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        scraperCalls++;
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: '',
        );
      }, isEnabled: () => false);

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);
      expect(scraperCalls, 0);
      expect(ops.writtenTexts, isEmpty);
    },
  );

  test(
    'disconnected scraper records failed status instead of noMatch',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      RemoteLibrarySource.configureMetadataScraper((_) async {
        throw StateError('Bangumi is not connected');
      });

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);

      final config = RemoteLibraryConfig.fromSettings();
      final cached = (await RemoteLibraryRepository.instance.find(
        config.cacheKey,
        'Cat Eye[Tsukasa Hojo]',
      ));
      expect(cached, isNotNull);
      final snapshot = cached!.snapshot!;
      expect(snapshot['metadataScrapeStatus'], 'failed');
      expect(snapshot['metadataScrapeRetryAt'], isNotNull);
      expect(
        snapshot['metadataScrapeError'],
        contains('Bangumi is not connected'),
      );
    },
  );

  test('normal unmatching scraper records noMatch without retryAt', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    RemoteLibrarySource.configureMetadataScraper((_) async {
      return null;
    });

    final sync = await _synchronizeAndComplete();
    expect(sync.success, isTrue);

    final config = RemoteLibraryConfig.fromSettings();
    final cached = (await RemoteLibraryRepository.instance.find(
      config.cacheKey,
      'Cat Eye[Tsukasa Hojo]',
    ));
    expect(cached, isNotNull);
    final snapshot = cached!.snapshot!;
    expect(snapshot['metadataScrapeStatus'], 'noMatch');
    expect(snapshot['metadataScrapeRetryAt'], isNull);
    expect(snapshot['metadataScrapeError'], isNull);
  });

  test(
    'secondary gate skips scraper and sets pending if disabled before execution',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var calls = 0;
      var enabled = true;
      RemoteLibrarySource.configureMetadataScraper(
        (_) async {
          calls++;
          return null;
        },
        isEnabled: () {
          final current = enabled;
          enabled = false;
          return current;
        },
      );

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);
      expect(calls, 0);

      final config = RemoteLibraryConfig.fromSettings();
      final cached = (await RemoteLibraryRepository.instance.find(
        config.cacheKey,
        'Cat Eye[Tsukasa Hojo]',
      ));
      expect(cached, isNotNull);
      expect(cached!.snapshot!['metadataScrapeStatus'], 'pending');
    },
  );

  test('failed scraper does not retry before retryAt arrives', () async {
    var simulatedTime = 1000000000000;
    RemoteLibrarySource.metadataNowProvider = () => simulatedTime;

    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    RemoteLibrarySource.configureMetadataScraper((_) async {
      scraperCalls++;
      throw StateError('Bangumi is not connected');
    });

    final firstSync = await _synchronizeAndComplete();
    expect(firstSync.success, isTrue);
    expect(scraperCalls, 1);

    // Advance time by 14 minutes (< 15 minutes retryAt)
    simulatedTime += const Duration(minutes: 14).inMilliseconds;

    final secondSync = await _synchronizeAndComplete();
    expect(secondSync.success, isTrue);
    expect(scraperCalls, 1);
  });

  test('failed scraper retries after retryAt has elapsed', () async {
    var simulatedTime = 1000000000000;
    RemoteLibrarySource.metadataNowProvider = () => simulatedTime;

    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    RemoteLibrarySource.configureMetadataScraper((_) async {
      scraperCalls++;
      throw StateError('Bangumi is not connected');
    });

    final firstSync = await _synchronizeAndComplete();
    expect(firstSync.success, isTrue);
    expect(scraperCalls, 1);

    // Advance time by 15 minutes (>= 15 minutes retryAt)
    simulatedTime += const Duration(minutes: 15).inMilliseconds;

    final secondSync = await _synchronizeAndComplete();
    expect(secondSync.success, isTrue);
    expect(scraperCalls, 2);
  });

  test(
    'child metadata validators invalidate an unchanged parent snapshot',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true, eTag: 'parent'),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(
          name: 'metadata.json',
          isDirectory: false,
          eTag: 'metadata-1',
        ),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'Before',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      await _synchronizeAndComplete();

      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(
          name: 'metadata.json',
          isDirectory: false,
          eTag: 'metadata-2',
        ),
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'After',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      await _synchronizeAndComplete();
      final comics = await RemoteLibrarySource.loadComics(1);

      expect(comics.data.single.title, 'After');
    },
  );

  test('a child without validators keeps its snapshot refreshable', () async {
    const path = '/manga/Book/metadata.json';
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Book', isDirectory: true, eTag: 'parent'),
    ];
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(
        name: 'metadata.json',
        isDirectory: false,
        eTag: 'metadata',
      ),
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Book',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    await _synchronizeAndComplete();

    await _synchronizeAndComplete();

    expect(RemoteLibrarySource.syncStatus.value.total, 1);
  });

  test(
    'structured scrape state retries only after scraper version changes',
    () async {
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      var calls = 0;
      RemoteLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return null;
      }, scraperVersion: '1');
      await _synchronizeAndComplete();
      final config = RemoteLibraryConfig.fromSettings();
      final firstSnapshot = (await RemoteLibraryRepository.instance.find(
        config.cacheKey,
        'Book',
      ))!.snapshot!;
      expect(firstSnapshot['metadataScrapeStatus'], 'noMatch');
      expect(firstSnapshot['metadataScraperVersion'], '1');

      RemoteLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return const ComicMetaData(
          title: 'Matched',
          author: '',
          tags: [],
          bangumiSubjectId: 47,
        );
      }, scraperVersion: '1');
      await _synchronizeAndComplete();
      expect(calls, 1);

      RemoteLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return const ComicMetaData(
          title: 'Matched',
          author: '',
          tags: [],
          bangumiSubjectId: 47,
        );
      }, scraperVersion: '2');
      await _synchronizeAndComplete();

      expect(calls, 2);
      expect(ops.writtenTexts, contains('/manga/Book/metadata.json'));
    },
  );

  test('后台章节补全后刮削保留完整章节与文件证据', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Complex Comic', isDirectory: true),
    ];
    ops.dirs['/manga/Complex Comic/'] = const [
      RemoteLibraryEntry(name: 'cover.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '000.jpg', isDirectory: false),
      RemoteLibraryEntry(name: '第01话', isDirectory: true),
      RemoteLibraryEntry(name: '第02话', isDirectory: true),
    ];
    ops.dirs['/manga/Complex Comic/第01话/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/Complex Comic/第02话/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final inputs = <RemoteLibraryMetadataInput>[];
    RemoteLibrarySource.configureMetadataScraper((input) async {
      inputs.add(input);
      return null;
    });

    final sync = await _synchronizeAndComplete();
    expect(sync.success, isTrue);

    expect(ops.readPaths.any((p) => p.contains('/第01话')), isTrue);
    expect(inputs, hasLength(1));

    final config = RemoteLibraryConfig.fromSettings();
    final cached = (await RemoteLibraryRepository.instance.find(
      config.cacheKey,
      'Complex Comic',
    ));
    expect(cached, isNotNull);
    expect(cached!.snapshot!['metadataScrapeStatus'], 'noMatch');

    final info = await RemoteLibrarySource.loadComicInfo('Complex Comic');
    expect(info.success, isTrue);
    expect(inputs, hasLength(1));
    final input = inputs.single;
    expect(input.title, 'Complex Comic');
    expect(input.directoryTitle, 'Complex Comic');
    expect(input.fileNames, containsAll(['第01话', '第02话', '001.jpg']));

    final afterInfo = (await RemoteLibraryRepository.instance.find(
      config.cacheKey,
      'Complex Comic',
    ));
    expect(afterInfo!.snapshot!['metadataScrapeStatus'], 'noMatch');
  });

  test('failed scrape stores attempt, retry, version, and error', () async {
    ops.dirs['/manga/'] = const [
      RemoteLibraryEntry(name: 'Book', isDirectory: true),
    ];
    ops.dirs['/manga/Book/'] = const [
      RemoteLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
    ];
    RemoteLibrarySource.configureMetadataScraper(
      (_) => throw StateError('scraper unavailable'),
      scraperVersion: 'rules-2',
    );

    await _synchronizeAndComplete();

    final config = RemoteLibraryConfig.fromSettings();
    final snapshot = (await RemoteLibraryRepository.instance.find(
      config.cacheKey,
      'Book',
    ))!.snapshot!;
    final attemptedAt = snapshot['metadataScrapeAttemptedAt'];
    final retryAt = snapshot['metadataScrapeRetryAt'];
    expect(snapshot['metadataScrapeStatus'], 'failed');
    expect(snapshot['metadataScraperVersion'], 'rules-2');
    expect(attemptedAt, isA<int>());
    expect(retryAt, isA<int>());
    expect(retryAt as int, greaterThan(attemptedAt as int));
    expect(snapshot['metadataScrapeError'], contains('scraper unavailable'));
    expect(ops.writeRequests, isEmpty);
  });

  test(
    'manual scraping retries only the selected unmatched comic and updates details',
    () async {
      ops.dirs['/manga/Comic A/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic B/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Comic A', isDirectory: true),
        RemoteLibraryEntry(name: 'Comic B', isDirectory: true),
      ];

      final boundSubjects = <({String comicId, int subjectId})>[];
      RemoteLibrarySource.configureMetadataSubjectHandler(({
        required scopeId,
        required sourceKey,
        required comicId,
        required subjectId,
      }) {
        boundSubjects.add((comicId: comicId, subjectId: subjectId));
      });

      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scraperCalls++;
        return null;
      }, scraperVersion: 'v1');

      final initialSync = await _synchronizeAndComplete();
      expect(initialSync.success, isTrue);
      expect(scraperCalls, 2);

      final config = RemoteLibraryConfig.fromSettings();
      expect(
        (await RemoteLibraryRepository.instance.find(
          config.cacheKey,
          'Comic A',
        ))!.snapshot!['metadataScrapeStatus'],
        'noMatch',
      );
      expect(
        (await RemoteLibraryRepository.instance.find(
          config.cacheKey,
          'Comic B',
        ))!.snapshot!['metadataScrapeStatus'],
        'noMatch',
      );

      // Scraper now returns a match for Comic A, but still null for Comic B
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scraperCalls++;
        if (input.title.contains('Comic A')) {
          return const ComicMetaData(
            title: 'Comic A Matched',
            author: 'Author A',
            tags: ['Action'],
            bangumiSubjectId: 101,
          );
        }
        return null;
      }, scraperVersion: 'v1');

      // Forced sync must NOT retry because both are cached as noMatch for v1
      final forcedSync = await _synchronizeAndComplete(force: true);
      expect(forcedSync.success, isTrue);
      expect(scraperCalls, 2);

      // Manual retry on Comic A bypasses noMatch
      final result = await RemoteLibrarySource.retryMetadataScrape('Comic A');
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.data, RemoteLibraryMetadataScrapeResult.matched);
      expect(scraperCalls, 3);
      expect(boundSubjects, [(comicId: 'Comic A', subjectId: 101)]);

      // Details and file for Comic A are updated
      final detailsA = await RemoteLibrarySource.loadComicInfo('Comic A');
      expect(detailsA.success, isTrue);
      expect(detailsA.data.title, 'Comic A Matched');
      expect(detailsA.data.tags['作者'], ['Author A']);
      expect(
        ops.writtenTexts.containsKey('/manga/Comic A/metadata.json'),
        isTrue,
      );
      final writtenA =
          jsonDecode(ops.writtenTexts['/manga/Comic A/metadata.json']!) as Map;
      expect(writtenA['bangumiSubjectId'], 101);

      // Comic B remains completely isolated and unchanged
      final snapshotB = (await RemoteLibraryRepository.instance.find(
        config.cacheKey,
        'Comic B',
      ))!.snapshot!;
      expect(snapshotB['metadataScrapeStatus'], 'noMatch');
      expect(
        ops.writtenTexts.containsKey('/manga/Comic B/metadata.json'),
        isFalse,
      );
    },
  );

  test(
    'retryMetadataScrape succeeds when automatic scraping is disabled, while network error records failed instead of noMatch',
    () async {
      ops.dirs['/manga/Manual Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/'] = const [
        RemoteLibraryEntry(name: 'Manual Book', isDirectory: true),
      ];

      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scraperCalls++;
        return const ComicMetaData(
          title: 'Manual Matched',
          author: 'Manual Author',
          tags: [],
        );
      }, isEnabled: () => false);

      final sync = await _synchronizeAndComplete();
      expect(sync.success, isTrue);
      expect(scraperCalls, 0);
      expect(
        ops.writtenTexts.containsKey('/manga/Manual Book/metadata.json'),
        isFalse,
      );

      // Manual retry succeeds even though auto scraping is disabled
      final manualResult = await RemoteLibrarySource.retryMetadataScrape(
        'Manual Book',
      );
      expect(manualResult.success, isTrue, reason: manualResult.errorMessage);
      expect(manualResult.data, RemoteLibraryMetadataScrapeResult.matched);
      expect(scraperCalls, 1);
      expect(
        ops.writtenTexts.containsKey('/manga/Manual Book/metadata.json'),
        isTrue,
      );

      // Network error during retry records failed status instead of noMatch
      ops.dirs['/manga/Net Fail Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      RemoteLibrarySource.configureMetadataScraper(
        (input) async => throw const SocketException('Connection timed out'),
      );

      final failResult = await RemoteLibrarySource.retryMetadataScrape(
        'Net Fail Book',
      );
      expect(failResult.success, isFalse);

      final config = RemoteLibraryConfig.fromSettings();
      final snapshotFail = (await RemoteLibraryRepository.instance.find(
        config.cacheKey,
        'Net Fail Book',
      ))!.snapshot!;
      expect(snapshotFail['metadataScrapeStatus'], 'failed');
      expect(
        snapshotFail['metadataScrapeError'],
        contains('Connection timed out'),
      );
    },
  );

  test(
    'retryMetadataScrape returns notNeeded and never overwrites existing metadata',
    () async {
      ops.dirs['/manga/Existing Book/'] = const [
        RemoteLibraryEntry(name: '001.jpg', isDirectory: false),
        RemoteLibraryEntry(name: 'metadata.json', isDirectory: false),
      ];
      ops.textFiles['/manga/Existing Book/metadata.json'] = jsonEncode({
        'title': 'Original Title',
        'author': 'Original Author',
        'tags': ['Original Tag'],
        'bangumiSubjectId': 42,
      });

      var scraperCalls = 0;
      RemoteLibrarySource.configureMetadataScraper((input) async {
        scraperCalls++;
        return const ComicMetaData(
          title: 'Replacement Title',
          author: 'Replacement Author',
          bangumiSubjectId: 99,
          tags: [],
        );
      });

      final result = await RemoteLibrarySource.retryMetadataScrape(
        'Existing Book',
      );
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.data, RemoteLibraryMetadataScrapeResult.notNeeded);
      expect(scraperCalls, 0);
      expect(ops.writeRequests, isEmpty);
      expect(
        jsonDecode(
          ops.textFiles['/manga/Existing Book/metadata.json']!,
        )['title'],
        'Original Title',
      );

      final details = await RemoteLibrarySource.loadComicInfo('Existing Book');
      expect(details.success, isTrue);
      expect(details.data.title, 'Original Title');
      expect(details.data.tags['作者'], ['Original Author']);
    },
  );
}

class _MetadataBindingGateway extends Fake implements BangumiGateway {
  BangumiCollection collection = const BangumiCollection(
    type: 3,
    rate: 7,
    epStatus: 5,
    volStatus: 2,
  );

  @override
  Future<BangumiSubject> getSubject(int id) async => BangumiSubject(
    id: id,
    title: 'Bangumi title',
    originalTitle: 'Original title',
    coverUrl: '',
    totalEpisodes: 24,
    totalVolumes: 4,
  );

  @override
  Future<BangumiCollection?> getCollection(
    String username,
    int subjectId,
  ) async => collection;

  @override
  Future<void> patchCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    collection = BangumiCollection(
      type: fields['type'] as int? ?? collection.type,
      rate: fields['rate'] as int? ?? collection.rate,
      epStatus: fields['ep_status'] as int? ?? collection.epStatus,
      volStatus: fields['vol_status'] as int? ?? collection.volStatus,
    );
  }
}

class _FakeRemoteFileStore implements RemoteFileStore {
  _FakeRemoteFileStore(String id)
    : _account = StorageAccount(
        id: id,
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: id,
        authorization: const {},
      );

  final StorageAccount _account;
  final dirs = <String, List<RemoteEntry>>{};
  final listRequests = <({String path, bool refresh})>[];
  Future<List<RemoteEntry>> Function(String path, bool refresh)? onList;
  final errors = <String, Object>{};
  final writtenPaths = <String>[];
  final texts = <String, String>{};
  final statEntries = <String, RemoteEntry>{};
  final statPaths = <String>[];
  final links = <String, RemoteLink>{};
  final linkedPaths = <String>[];
  final blockers = <String, Completer<void>>{};
  var cancelAllCalls = 0;

  @override
  StorageAccount get account => _account;

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }

  @override
  Future<void> delete(String path) async {}

  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {}

  @override
  Future<RemoteLink> link(String path) async {
    linkedPaths.add(path);
    return links[path] ?? RemoteLink(url: path);
  }

  @override
  Future<List<RemoteEntry>> list(
    String directory, {
    bool refresh = false,
  }) async {
    listRequests.add((path: directory, refresh: refresh));
    if (onList != null) return onList!(directory, refresh);
    await blockers[directory]?.future;
    final error = errors[directory];
    if (error != null) throw error;
    return dirs[directory] ?? const [];
  }

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<RemoteTextFile> readText(String path) async {
    final content = texts[path];
    if (content == null) throw StateError('Missing text file: $path');
    return RemoteTextFile(content: content, eTag: '"metadata-v1"');
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    statPaths.add(path);
    final entry = statEntries[path];
    if (entry == null) throw StateError(path);
    return entry;
  }

  @override
  Future<void> test() async {}

  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {}

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    writtenPaths.add(path);
    texts[path] = content;
    final slash = path.lastIndexOf('/');
    final parent = path.substring(0, slash + 1);
    final name = path.substring(slash + 1);
    final entries = List<RemoteEntry>.from(dirs[parent] ?? const []);
    if (!entries.any((entry) => entry.name == name)) {
      entries.add(
        RemoteEntry(
          name: name,
          path: path,
          isDirectory: false,
          eTag: '"metadata-v1"',
        ),
      );
      dirs[parent] = entries;
    }
    return const RemoteWriteResult();
  }
}

class _SnapshotRangeAdapter implements HttpClientAdapter {
  _SnapshotRangeAdapter(this.bytes, this.started, this.gate);

  final List<int> bytes;
  final Completer<void> started;
  final Completer<void> gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    final range = RegExp(
      r'^bytes=(\d+)-(\d+)$',
    ).firstMatch(options.headers['Range'] as String)!;
    final start = int.parse(range.group(1)!);
    final end = int.parse(range.group(2)!);
    return ResponseBody.fromBytes(
      bytes.sublist(start, end + 1),
      206,
      headers: {
        'content-range': ['bytes $start-$end/${bytes.length}'],
        'content-length': ['${end - start + 1}'],
        'etag': ['"v1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeRemoteLibraryOps implements RemoteLibraryOps {
  final dirs = <String, List<RemoteLibraryEntry>>{};
  final errors = <String, Object>{};
  final textFiles = <String, String>{};
  final textETags = <String, String>{};
  final textModifiedAt = <String, int>{};
  final validatorlessPaths = <String>{};
  final readPaths = <String>[];
  final directoryRequests = <({String path, bool refresh})>[];
  final textBlockers = <String, Completer<void>>{};
  final textStarted = <String, Completer<void>>{};
  final textReadPaths = <String>[];
  final writtenTexts = <String, String>{};
  final writeRequests =
      <
        ({
          String path,
          bool createOnly,
          String? ifMatch,
          int? ifUnmodifiedSince,
        })
      >[];
  void Function(String path, int writeNumber)? beforeWrite;
  final blockers = <String, Completer<void>>{};
  final readStarted = <String, Completer<void>>{};

  @override
  Future<List<RemoteLibraryEntry>> readDir(
    RemoteLibraryConfig config,
    String remotePath, {
    bool refresh = false,
  }) async {
    directoryRequests.add((path: remotePath, refresh: refresh));
    readPaths.add(remotePath);
    final started = readStarted[remotePath];
    if (started != null && !started.isCompleted) started.complete();
    await blockers[remotePath]?.future;
    final error = errors[remotePath];
    if (error != null) throw error;
    return dirs[remotePath] ?? const [];
  }

  @override
  Future<RemoteLibraryTextFile> readText(
    RemoteLibraryConfig config,
    String remotePath,
  ) async {
    textReadPaths.add(remotePath);
    final started = textStarted[remotePath];
    if (started != null && !started.isCompleted) started.complete();
    await textBlockers[remotePath]?.future;
    final value = textFiles[remotePath];
    if (value == null) throw StateError('Missing text file: $remotePath');
    return RemoteLibraryTextFile(
      content: value,
      eTag: validatorlessPaths.contains(remotePath)
          ? null
          : textETags[remotePath] ?? '"1"',
      modifiedAt: validatorlessPaths.contains(remotePath)
          ? null
          : textModifiedAt[remotePath],
    );
  }

  @override
  Future<RemoteLibraryWriteResult> writeText(
    RemoteLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    writeRequests.add((
      path: remotePath,
      createOnly: createOnly,
      ifMatch: ifMatch,
      ifUnmodifiedSince: ifUnmodifiedSince,
    ));
    beforeWrite?.call(remotePath, writeRequests.length);
    if (createOnly && textFiles.containsKey(remotePath)) {
      throw RemoteLibraryPreconditionFailedException(remotePath);
    }
    if (ifMatch != null && ifMatch != (textETags[remotePath] ?? '"1"')) {
      throw RemoteLibraryPreconditionFailedException(remotePath);
    }
    if (ifUnmodifiedSince != null &&
        ifUnmodifiedSince != textModifiedAt[remotePath]) {
      throw RemoteLibraryPreconditionFailedException(remotePath);
    }
    writtenTexts[remotePath] = content;
    textFiles[remotePath] = content;
    final currentTag = textETags[remotePath] ?? '"1"';
    final version = int.tryParse(currentTag.replaceAll('"', '')) ?? 1;
    final nextTag = '"${version + 1}"';
    textETags[remotePath] = nextTag;
    final separator = remotePath.lastIndexOf('/');
    final directoryPath = remotePath.substring(0, separator + 1);
    final fileName = remotePath.substring(separator + 1);
    final entries = List<RemoteLibraryEntry>.from(
      dirs[directoryPath] ?? const [],
    );
    if (!entries.any(
      (entry) =>
          !entry.isDirectory &&
          entry.name.toLowerCase() == fileName.toLowerCase(),
    )) {
      entries.add(
        RemoteLibraryEntry(name: fileName, isDirectory: false, eTag: nextTag),
      );
      dirs[directoryPath] = entries;
    }
    return RemoteLibraryWriteResult(eTag: nextTag);
  }

  @override
  Future<void> test(RemoteLibraryConfig config) async {}
}

Future<Res<bool>> _synchronizeAndComplete({bool force = false}) async {
  final result = await RemoteLibrarySource.synchronize(force: force);
  await RemoteLibrarySource.waitForBackgroundTasks();
  return result;
}
