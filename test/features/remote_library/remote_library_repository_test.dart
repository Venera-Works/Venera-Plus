import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/remote_library/remote_library_repository.dart';
import 'package:venera_plus/foundation/app.dart';

import '../../support/sqlite.dart';

void main() {
  final repository = RemoteLibraryRepository.instance;
  late Directory dataDir;
  const key = 'library';

  group('云端库数据库 worker', () {
    setUp(() async {
      await repository.resetForTesting();
      dataDir = Directory.systemTemp.createTempSync(
        'remote-library-repository-',
      );
      App.dataPath = dataDir.path;
    });

    tearDown(() async {
      await repository.resetForTesting();
      dataDir.deleteSync(recursive: true);
    });

    for (final filename in ['webdav_library.db', 'remote_library.db']) {
      test('从 $filename 的旧表迁移完整快照、根和旧版同步状态', () async {
        final snapshot = {
          'formatVersion': remoteLibrarySnapshotFormatVersion,
          'metadataFilePresent': false,
          'metadataScrapeStatus': 'failed',
          'metadataScraperVersion': 'scraper-v1',
          'metadataScrapeRetryAt': 200,
          'bangumiSubjectId': 123,
          'chapters': {
            '1': ['page-1', 'page-2'],
          },
        };
        _withDatabase('${dataDir.path}/$filename', (db) {
          _createLegacySchema(db, withIndexColumn: false);
          _insertComic(db, 'legacy', snapshot: snapshot);
          db.execute('''
            INSERT INTO webdav_library_state(config_key, last_successful_sync)
            VALUES ('library', 100);
            INSERT INTO webdav_library_root_membership VALUES
              ('library', '/old/', 'legacy');
            INSERT INTO webdav_library_root_state VALUES
              ('library', '/old/', 90, '离线');
          ''');
        });

        final cached = (await repository.find(key, 'legacy'))!;
        expect(cached.snapshot, snapshot);
        expect(cached.title, '标题 legacy');
        expect(cached.tags, ['标签']);
        expect(cached.remoteETag, 'etag-v1');
        expect(cached.remoteModifiedAt, 1);
        expect(await repository.count(key, roots: ['/old/']), 1);
        expect(await repository.lastSuccessfulSync(key), 100);
        expect(await repository.hasDirectoryIndex(key), isFalse);
        expect(await repository.rootFailures(key), {'/old/': '离线'});
        final version = (await repository.versions(key))['legacy']!;
        expect(version.isReady, isTrue);
        expect(version.snapshot, isNot(contains('chapters')));
        expect(version.snapshot?['bangumiSubjectId'], 123);
        expect(
          version.shouldRetryMetadataScrape(
            scraperVersion: 'scraper-v1',
            now: 199,
          ),
          isFalse,
        );
        expect(
          version.shouldRetryMetadataScrape(
            scraperVersion: 'scraper-v1',
            now: 200,
          ),
          isTrue,
        );

        await repository.close();
        expect(File('${dataDir.path}/$filename').existsSync(), isTrue);
        expect(File('${dataDir.path}/remote_library.db').existsSync(), isTrue);
        expect((await repository.all(key))['legacy']!.snapshot, snapshot);
      });
    }

    test('两库并存时合并记录和根，完整快照优先且按更新时间解决冲突', () async {
      await repository.count(key);
      await repository.close();
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        _insertComic(
          db,
          'newer-target',
          prefix: 'remote_library',
          updatedAt: 300,
        );
        _insertComic(
          db,
          'newer-legacy',
          prefix: 'remote_library',
          updatedAt: 100,
        );
        _insertComic(
          db,
          'complete-target',
          prefix: 'remote_library',
          updatedAt: 100,
        );
        _insertComic(
          db,
          'placeholder',
          prefix: 'remote_library',
          snapshot: null,
          updatedAt: 400,
        );
        _insertComic(db, 'tie', prefix: 'remote_library', updatedAt: 300);
        db.execute('''
          INSERT INTO remote_library_root_membership VALUES
            ('library', '/new/', 'newer-target');
          INSERT INTO remote_library_state VALUES ('library', 400, 1);
        ''');
      });
      _withDatabase('${dataDir.path}/webdav_library.db', (db) {
        _createLegacySchema(db);
        _insertComic(db, 'newer-target', title: '旧库旧记录', updatedAt: 100);
        _insertComic(db, 'newer-legacy', title: '旧库较新记录', updatedAt: 300);
        _insertComic(
          db,
          'complete-target',
          snapshot: null,
          title: '较新占位',
          updatedAt: 400,
        );
        _insertComic(db, 'placeholder', title: '恢复完整快照', updatedAt: 100);
        _insertComic(db, 'tie', title: '同时间旧库记录', updatedAt: 300);
        _insertComic(db, 'legacy-only');
        db.execute('''
          INSERT INTO webdav_library_root_membership VALUES
            ('library', '/old/', 'legacy-only');
          INSERT INTO webdav_library_root_membership VALUES
            ('library', '/old/', 'newer-target');
          INSERT INTO webdav_library_state VALUES ('library', 600, 0);
        ''');
      });

      final comics = await repository.all(key);
      expect(comics, hasLength(6));
      expect(comics['newer-target']!.title, '标题 newer-target');
      expect(comics['newer-legacy']!.title, '旧库较新记录');
      expect(comics['complete-target']!.snapshot, isNotNull);
      expect(comics['placeholder']!.snapshot, isNotNull);
      expect(comics['placeholder']!.title, '恢复完整快照');
      expect(comics['tie']!.title, '标题 tie');
      expect(await repository.count(key, roots: ['/new/', '/old/']), 2);
      expect(await repository.lastSuccessfulSync(key), 600);
      expect(await repository.hasDirectoryIndex(key), isTrue);

      await repository.clear(key);
      await repository.close();
      expect(await repository.count(key), 0);
      expect(await repository.all(key), isEmpty);
      expect(await repository.rootFailures(key), isEmpty);
      // 已提交的迁移标记防止清空缓存后，从保留的旧库重新导入。
      expect(File('${dataDir.path}/webdav_library.db').existsSync(), isTrue);
    });

    test('迁移失败回滚数据和标记，修复旧表后可以重试', () async {
      await repository.upsertSnapshot('other', _comic('existing'));
      await repository.close();
      _withDatabase('${dataDir.path}/webdav_library.db', (db) {
        _createLegacySchema(db);
        _insertComic(db, 'legacy');
        db.execute('''
          INSERT INTO webdav_library_root_membership VALUES
            ('library', '/old/', 'legacy');
          ALTER TABLE webdav_library_root_membership
            RENAME COLUMN root_path TO unfinished_root_path;
        ''');
      });

      await expectLater(repository.count(key), throwsStateError);
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        expect(
          db.select(
            "SELECT id FROM remote_library_comics WHERE config_key = 'library';",
          ),
          isEmpty,
        );
        expect(
          db.select(
            "SELECT name FROM remote_library_migrations WHERE name = 'legacy_database';",
          ),
          isEmpty,
        );
        expect(
          db
              .select(
                "SELECT id FROM remote_library_comics WHERE config_key = 'other';",
              )
              .single['id'],
          'existing',
        );
      });
      _withDatabase('${dataDir.path}/webdav_library.db', (db) {
        expect(
          db.select('SELECT id FROM webdav_library_comics;').single['id'],
          'legacy',
        );
        db.execute('''
          ALTER TABLE webdav_library_root_membership
            RENAME COLUMN unfinished_root_path TO root_path;
        ''');
      });

      expect(await repository.count(key, roots: ['/old/']), 1);
      expect((await repository.find(key, 'legacy'))!.isReady, isTrue);
      expect(await repository.count('other'), 1);
    });

    test('worker 负责编码 JSON，关闭后可重新打开并恢复完整快照', () async {
      await repository.upsertSnapshot(
        key,
        _comic(
          'persisted',
          snapshot: {
            'formatVersion': remoteLibrarySnapshotFormatVersion,
            'encodedBy': const _EncodingProbe(),
            'chapters': {
              '1': ['image-1', 'image-2'],
            },
          },
        ),
      );
      await repository.setLastSuccessfulSync(key, 1234);
      await repository.close();
      await repository.close();

      final restored = (await repository.find(key, 'persisted'))!;
      expect(restored.snapshot?['encodedBy'], {
        'isolate': 'remote-library-database',
      });
      expect(restored.snapshot?['chapters'], {
        '1': ['image-1', 'image-2'],
      });
      expect(await repository.lastSuccessfulSync(key), 1234);
      expect(await repository.hasDirectoryIndex(key), isTrue);
      expect(await repository.find(key, 'missing'), isNull);
    });

    test('列表和版本不读取完整大 JSON，find 和 all 保留完整语义', () async {
      final snapshot = {
        'formatVersion': remoteLibrarySnapshotFormatVersion,
        'metadataFilePresent': false,
        'metadataScrapeStatus': 'failed',
        'metadataScraperVersion': 'v1',
        'metadataScrapeRetryAt': 50,
        'bangumiSubjectId': 123,
        'chaptersInspected': true,
        'chapters': {
          '1': List.filled(12000, 'https://example.com/${'x' * 128}.jpg'),
        },
      };
      await repository.upsertSnapshot(key, _comic('large', snapshot: snapshot));
      expect((await repository.find(key, 'large'))!.snapshot, snapshot);
      expect((await repository.all(key))['large']!.snapshot, snapshot);
      final page = await repository.page(key, page: 1, pageSize: 10);
      expect(page.single.title, '标题 large');
      expect(page.single.author, '作者');
      expect(page.single.tags, ['标签']);
      expect(page.single.cover, 'https://example.com/large.jpg');
      expect(page.single.isReady, isTrue);
      expect(page.single.snapshot, isNot(contains('chapters')));

      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          UPDATE remote_library_comics SET snapshot_json = 'invalid JSON'
          WHERE config_key = 'library' AND id = 'large';
        ''');
      });
      await repository.close();
      expect(
        (await repository.page(key, page: 1, pageSize: 1)).single.id,
        'large',
      );
      final version = (await repository.versions(key))['large']!;
      expect(version.snapshot, {
        'formatVersion': remoteLibrarySnapshotFormatVersion,
        'metadataFilePresent': false,
        'metadataScrapeStatus': 'failed',
        'metadataScraperVersion': 'v1',
        'metadataScrapeRetryAt': 50,
        'bangumiSubjectId': 123,
        'chaptersInspected': true,
      });
      expect(
        version.hasSameRemoteVersion(eTag: 'etag-v1', modifiedAt: 1),
        isTrue,
      );
      await expectLater(repository.find(key, 'large'), throwsStateError);
      expect(await repository.count(key), 1);
    });

    test('根成员差量更新保留其他失败根和缓存，索引不提前覆盖快照版本', () async {
      await repository.upsertSnapshots(key, [
        _comic('keep'),
        _comic('gone', sortIndex: 1),
        _comic('other', sortIndex: 2),
      ]);
      await repository.replaceRootDirectoryIndex(
        key,
        _index('/A/', ['keep', 'gone']),
      );
      await repository.replaceRootDirectoryIndex(
        key,
        _index('/B/', ['keep', 'other']),
      );
      await repository.markRootFailure(key, '/B/', 'B 离线');
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          CREATE TABLE membership_changes(action TEXT, root_path TEXT, id TEXT);
          CREATE TRIGGER audit_membership_insert
          AFTER INSERT ON remote_library_root_membership
          BEGIN
            INSERT INTO membership_changes VALUES ('insert', NEW.root_path, NEW.comic_id);
          END;
          CREATE TRIGGER audit_membership_delete
          AFTER DELETE ON remote_library_root_membership
          BEGIN
            INSERT INTO membership_changes VALUES ('delete', OLD.root_path, OLD.comic_id);
          END;
        ''');
      });

      await repository.replaceRootDirectoryIndex(
        key,
        const RemoteLibraryRootIndex(
          rootPath: '/A/',
          directories: [
            RemoteLibraryRemoteDirectory(
              id: 'keep',
              sortIndex: 3,
              eTag: 'etag-v2',
              modifiedAt: 2,
            ),
            RemoteLibraryRemoteDirectory(id: 'added', sortIndex: 4),
          ],
        ),
      );
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        expect(
          db
              .select('SELECT * FROM membership_changes;')
              .map((row) => [row['action'], row['root_path'], row['id']])
              .toList(),
          [
            ['delete', '/A/', 'gone'],
            ['insert', '/A/', 'added'],
          ],
        );
      });
      expect(await repository.count(key, roots: ['/A/', '/B/']), 3);
      expect(await repository.rootFailures(key), {'/B/': 'B 离线'});
      final cached = (await repository.find(key, 'keep'))!;
      expect(cached.sortIndex, 3);
      expect(cached.remoteETag, 'etag-v1');
      expect(cached.remoteModifiedAt, 1);
      expect(
        cached.hasSameRemoteVersion(eTag: 'etag-v2', modifiedAt: 2),
        isFalse,
      );
      expect(await repository.find(key, 'gone'), isNotNull);

      await repository.removeRootsExcept(key, {'/B/'});
      expect(await repository.count(key, roots: ['/B/']), 2);
      await repository.markRootFailure(key, '/A/', '重新添加后离线');
      expect(await repository.count(key, roots: ['/A/']), 2);
      await repository.replaceRootDirectoryIndex(key, _index('/A/', []));
      expect(await repository.count(key, roots: ['/A/']), 0);
      expect(await repository.count(key, roots: []), 0);
      await repository.replaceRootDirectoryIndex(key, _index('/B/', []));
      expect(await repository.count(key), 0);
      expect(await repository.page(key, page: 1, pageSize: 10), isEmpty);
      expect(await repository.find(key, 'keep'), isNotNull);
      expect(await repository.rootFailures(key), isEmpty);
    });

    test('根索引事务失败时保留成员、排序和失败状态', () async {
      await repository.replaceRootDirectoryIndex(
        key,
        _index('/A/', ['keep', 'gone']),
      );
      await repository.markRootFailure(key, '/A/', '上次失败');
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          CREATE TRIGGER reject_membership BEFORE INSERT ON remote_library_root_membership
          WHEN NEW.comic_id = 'rejected'
          BEGIN SELECT RAISE(ABORT, '拒绝测试成员'); END;
        ''');
      });

      await expectLater(
        repository.replaceRootDirectoryIndex(
          key,
          const RemoteLibraryRootIndex(
            rootPath: '/A/',
            directories: [
              RemoteLibraryRemoteDirectory(id: 'keep', sortIndex: 9),
              RemoteLibraryRemoteDirectory(id: 'added', sortIndex: 10),
              RemoteLibraryRemoteDirectory(id: 'rejected', sortIndex: 11),
            ],
          ),
        ),
        throwsStateError,
      );
      expect((await repository.find(key, 'keep'))!.sortIndex, 0);
      expect(await repository.find(key, 'added'), isNull);
      expect(await repository.find(key, 'rejected'), isNull);
      expect(
        (await repository.page(
          key,
          page: 1,
          pageSize: 10,
          roots: ['/A/'],
        )).map((comic) => comic.id).toList(),
        ['keep', 'gone'],
      );
      expect(await repository.rootFailures(key), {'/A/': '上次失败'});
    });

    test('基本摘要发布保留完整元数据，相同字段不重复更新记录', () async {
      final snapshot = {
        'formatVersion': remoteLibrarySnapshotFormatVersion,
        'metadataFilePresent': true,
        'bangumiSubjectId': 123,
        'chapters': {
          '1': ['page'],
        },
      };
      await repository.upsertSnapshot(
        key,
        _comic('complete', title: '刮削标题', snapshot: snapshot),
      );
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          UPDATE remote_library_comics SET updated_at = 123
          WHERE config_key = 'library' AND id = 'complete';
          CREATE TABLE summary_updates(id TEXT);
          CREATE TRIGGER audit_summary_update AFTER UPDATE ON remote_library_comics
          BEGIN INSERT INTO summary_updates VALUES (NEW.id); END;
        ''');
      });
      RemoteLibraryCachedComic basicSummary({int sortIndex = 0}) =>
          RemoteLibraryCachedComic(
            id: 'complete',
            sortIndex: sortIndex,
            title: 'complete',
            author: '',
            tags: const [],
            cover: '',
            snapshot: null,
            remoteETag: 'etag-v2',
            remoteModifiedAt: 2,
          );

      await repository.upsertSummaries(key, [basicSummary()], rootPath: '/A/');
      await repository.upsertSummaries(key, [basicSummary()], rootPath: '/A/');
      final listed = (await repository.page(
        key,
        page: 1,
        pageSize: 10,
        roots: ['/A/'],
      )).single;
      expect(listed.title, '刮削标题');
      expect(listed.author, '作者');
      expect(listed.tags, ['标签']);
      expect(listed.cover, 'https://example.com/complete.jpg');
      expect(listed.remoteETag, 'etag-v1');
      expect(listed.remoteModifiedAt, 1);
      expect((await repository.find(key, 'complete'))!.snapshot, snapshot);
      expect(await repository.count(key, roots: ['/A/']), 1);
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        expect(db.select('SELECT * FROM summary_updates;'), isEmpty);
        expect(
          db.select('''
          SELECT updated_at FROM remote_library_comics
          WHERE config_key = 'library' AND id = 'complete';
        ''').single['updated_at'],
          123,
        );
      });

      await repository.upsertSummaries(key, [
        basicSummary(sortIndex: 7),
      ], rootPath: '/A/');
      expect((await repository.find(key, 'complete'))!.sortIndex, 7);
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        expect(db.select('SELECT * FROM summary_updates;'), hasLength(1));
        expect(
          db.select('''
          SELECT updated_at FROM remote_library_comics
          WHERE config_key = 'library' AND id = 'complete';
        ''').single['updated_at'],
          123,
        );
      });

      await repository.upsertSummaries(key, [
        _comic('placeholder', snapshot: null),
      ]);
      final replacement = _comic(
        'placeholder',
        title: '补充摘要',
        snapshot: null,
        eTag: null,
        modifiedAt: 2,
      );
      await repository.upsertSummaries(key, [replacement]);
      await repository.upsertSummaries(key, [replacement]);
      final placeholder = (await repository.find(key, 'placeholder'))!;
      expect(placeholder.title, '补充摘要');
      expect(placeholder.remoteETag, isNull);
      expect(placeholder.remoteModifiedAt, 2);
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        expect(
          db.select("SELECT * FROM summary_updates WHERE id = 'placeholder';"),
          hasLength(1),
        );
      });
    });

    test('批量摘要保留完整快照与版本，成员失败时整批回滚', () async {
      final snapshot = {
        'formatVersion': remoteLibrarySnapshotFormatVersion,
        'chapters': {
          '1': ['page'],
        },
      };
      await repository.upsertSnapshot(key, _comic('keep', snapshot: snapshot));
      await repository.upsertSummaries(key, [
        _comic(
          'keep',
          title: '新摘要',
          snapshot: null,
          eTag: 'etag-v2',
          modifiedAt: 2,
        ),
        _comic('new', sortIndex: 1, snapshot: null),
      ], rootPath: '/A/');
      final cached = (await repository.find(key, 'keep'))!;
      expect(cached.title, '标题 keep');
      expect(cached.snapshot, snapshot);
      expect(cached.remoteETag, 'etag-v1');
      expect(cached.remoteModifiedAt, 1);
      expect((await repository.find(key, 'new'))!.snapshot, isNull);
      expect(await repository.count(key, roots: ['/A/']), 2);
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          CREATE TRIGGER reject_membership BEFORE INSERT ON remote_library_root_membership
          WHEN NEW.comic_id = 'rejected'
          BEGIN SELECT RAISE(ABORT, '拒绝测试成员'); END;
        ''');
      });

      await expectLater(
        repository.upsertSummaries(key, [
          _comic('temporary', snapshot: null),
          _comic('rejected', snapshot: null),
        ], rootPath: '/A/'),
        throwsStateError,
      );
      expect(await repository.find(key, 'temporary'), isNull);
      expect(await repository.find(key, 'rejected'), isNull);
      expect(await repository.count(key, roots: ['/A/']), 2);
      await repository.upsertSummaries(key, [
        _comic('after-failure', snapshot: null),
      ], rootPath: '/A/');
      expect(await repository.count(key, roots: ['/A/']), 3);
    });

    test('批量快照编码失败时回滚前面的写入，worker 可以继续处理请求', () async {
      await repository.upsertSnapshot(key, _comic('keep'));
      await expectLater(
        repository.upsertSnapshots(key, [
          _comic('keep', title: '未提交的新标题'),
          _comic(
            'invalid',
            snapshot: {
              'formatVersion': remoteLibrarySnapshotFormatVersion,
              'value': double.nan,
            },
          ),
        ]),
        throwsStateError,
      );

      expect((await repository.find(key, 'keep'))!.title, '标题 keep');
      expect(await repository.find(key, 'invalid'), isNull);
      await repository.upsertSnapshot(key, _comic('after-failure'));
      expect(await repository.count(key), 2);
    });

    test('clear 原子清除根、记录和同步状态，其他库保持可用', () async {
      await repository.upsertSnapshot(key, _comic('keep'));
      await repository.replaceRootDirectoryIndex(key, _index('/A/', ['keep']));
      await repository.markRootFailure(key, '/A/', '离线');
      await repository.setLastSuccessfulSync(key, 100);
      await repository.upsertSnapshot('other', _comic('other'));
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('''
          CREATE TRIGGER reject_clear BEFORE DELETE ON remote_library_root_state
          WHEN OLD.config_key = 'library'
          BEGIN SELECT RAISE(ABORT, '拒绝测试清理'); END;
        ''');
      });
      await expectLater(repository.clear(key), throwsStateError);
      expect(await repository.count(key, roots: ['/A/']), 1);
      expect(await repository.lastSuccessfulSync(key), 100);
      expect(await repository.rootFailures(key), {'/A/': '离线'});
      _withDatabase('${dataDir.path}/remote_library.db', (db) {
        db.execute('DROP TRIGGER reject_clear;');
      });
      await repository.clear(key);
      expect(await repository.all(key), isEmpty);
      expect(await repository.count(key, roots: ['/A/']), 0);
      expect(await repository.rootFailures(key), isEmpty);
      expect(await repository.lastSuccessfulSync(key), 0);
      expect(await repository.hasDirectoryIndex(key), isFalse);
      expect(await repository.count('other'), 1);
    });

    test('并发排队请求捕获各自的数据路径，close 等待写入且可再次打开', () async {
      final otherDir = Directory('${dataDir.path}/other')..createSync();
      final firstWrite = repository.upsertSnapshot(key, _comic('first'));
      App.dataPath = otherDir.path;
      final secondWrite = repository.upsertSnapshot(key, _comic('second'));
      App.dataPath = dataDir.path;
      final firstRead = repository.all(key);
      final close = repository.close();
      final reopenedRead = repository.all(key);
      await Future.wait([firstWrite, secondWrite, close]);
      expect((await firstRead).keys, ['first']);
      expect((await reopenedRead).keys, ['first']);
      App.dataPath = otherDir.path;
      expect((await repository.all(key)).keys, ['second']);
    });
  }, skip: isSqliteAvailable() ? false : 'sqlite3 原生库不可用');
}

RemoteLibraryCachedComic _comic(
  String id, {
  int sortIndex = 0,
  String? title,
  Map<String, dynamic>? snapshot = const {
    'formatVersion': remoteLibrarySnapshotFormatVersion,
  },
  String? eTag = 'etag-v1',
  int? modifiedAt = 1,
}) => RemoteLibraryCachedComic(
  id: id,
  sortIndex: sortIndex,
  title: title ?? '标题 $id',
  author: '作者',
  tags: const ['标签'],
  cover: 'https://example.com/$id.jpg',
  snapshot: snapshot,
  remoteETag: eTag,
  remoteModifiedAt: modifiedAt,
);

RemoteLibraryRootIndex _index(String root, List<String> ids) =>
    RemoteLibraryRootIndex(
      rootPath: root,
      directories: [
        for (var i = 0; i < ids.length; i++)
          RemoteLibraryRemoteDirectory(id: ids[i], sortIndex: i),
      ],
    );

T _withDatabase<T>(String path, T Function(Database db) action) {
  final db = sqlite3.open(path);
  try {
    return action(db);
  } finally {
    db.close();
  }
}

void _createLegacySchema(Database db, {bool withIndexColumn = true}) {
  db.execute('''
    CREATE TABLE webdav_library_comics (
      config_key TEXT NOT NULL, id TEXT NOT NULL, sort_index INTEGER NOT NULL,
      title TEXT NOT NULL, author TEXT NOT NULL, tags TEXT NOT NULL,
      cover TEXT NOT NULL, snapshot_json TEXT, remote_etag TEXT,
      remote_modified_at INTEGER, updated_at INTEGER NOT NULL,
      PRIMARY KEY(config_key, id)
    );
    CREATE TABLE webdav_library_root_membership (
      config_key TEXT NOT NULL, root_path TEXT NOT NULL, comic_id TEXT NOT NULL,
      PRIMARY KEY(config_key, root_path, comic_id)
    );
    CREATE TABLE webdav_library_root_state (
      config_key TEXT NOT NULL, root_path TEXT NOT NULL,
      last_successful_sync INTEGER NOT NULL DEFAULT 0, last_error TEXT,
      PRIMARY KEY(config_key, root_path)
    );
    CREATE TABLE webdav_library_state (
      config_key TEXT PRIMARY KEY,
      last_successful_sync INTEGER NOT NULL DEFAULT 0
      ${withIndexColumn ? ', index_initialized INTEGER NOT NULL DEFAULT 0' : ''}
    );
  ''');
}

void _insertComic(
  Database db,
  String id, {
  String prefix = 'webdav_library',
  String? title,
  Map<String, dynamic>? snapshot = const {
    'formatVersion': remoteLibrarySnapshotFormatVersion,
  },
  int updatedAt = 100,
}) {
  db.execute(
    '''
    INSERT INTO ${prefix}_comics (
      config_key, id, sort_index, title, author, tags, cover,
      snapshot_json, remote_etag, remote_modified_at, updated_at
    ) VALUES ('library', ?, 0, ?, '作者', ?, 'cover', ?, 'etag-v1', 1, ?);
  ''',
    [
      id,
      title ?? '标题 $id',
      jsonEncode(['标签']),
      snapshot == null ? null : jsonEncode(snapshot),
      updatedAt,
    ],
  );
}

class _EncodingProbe {
  const _EncodingProbe();

  Map<String, Object?> toJson() => {'isolate': Isolate.current.debugName};
}
