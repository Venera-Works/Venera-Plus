import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/remote_library/remote_archive_comic.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/features/remote_library/remote_library_repository.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import '../../support/sqlite.dart';

const _libraryId = 'cover-library';
const _archiveDirectory = '/library/Collection/';
const _archivePath = '$_archiveDirectory[松本痙] メスの烙淫 [中国翻訳] [DL版].zip';
const _flatDirectory = '/library/Flat/';
const _workDirectory = '/library/Directory Work/';
const _imageDirectory = '/library/Image Book/';
const _archiveCoverBytes = [1, 3, 5];
const _uploadedBytes = [2, 4, 6, 8];

void main() {
  late Directory temporary;
  late _CoverStore store;
  late RemoteLibraryEngine engine;
  late Dio dio;
  late String uploadPath;

  setUp(() async {
    await RemoteLibrarySource.resetCacheForTesting();
    temporary = await Directory.systemTemp.createTemp('remote-cover-');
    App.dataPath = temporary.path;
    store = _CoverStore();
    dio = Dio()..httpClientAdapter = _CoverRangeAdapter(store);
    RemoteLibrarySource.configureMetadataScraper(null);
    RemoteLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    RemoteLibrarySource.archiveDioFactory = () => dio;
    engine = RemoteLibraryEngine(
      library: const RemoteLibrary(
        id: _libraryId,
        sourceKey: _libraryId,
        accountId: _libraryId,
        directories: ['/library/'],
        name: '封面测试库',
        autoRefresh: false,
      ),
      store: store,
    );
    final file = File('${temporary.path}/local-cover.png');
    await file.writeAsBytes(_uploadedBytes);
    uploadPath = file.path;
  });

  tearDown(() async {
    await engine.cancel();
    dio.close(force: true);
    RemoteLibrarySource.archiveDioFactory = null;
    RemoteLibrarySource.archiveSchedulerFactory = null;
    await RemoteLibrarySource.resetCacheForTesting();
    await temporary.delete(recursive: true);
  });

  Future<RemoteLibraryCachedComic> cached(String id) async =>
      (await RemoteLibraryRepository.instance.find(
        'remote-library:$_libraryId',
        id,
      ))!;

  Future<List<Comic>> scan({bool waitForDetails = true}) async {
    final sync = await engine.synchronize(force: true);
    expect(sync.success, isTrue, reason: sync.errorMessage);
    if (waitForDetails) await engine.waitForBackgroundTasks();
    return (await engine.loadComics(1)).data;
  }

  test('单文件的旁车封面进入扫描摘要与详情，并参与远端版本', () async {
    const cover = '$_archivePath.cover.png';
    store.put(_archivePath, _zip());
    store.put(cover, [1]);
    store.put('${_archiveDirectory}cover.jpg', [2]);
    store.put('$_archivePath.metadata.json', utf8.encode('{"title":"归档"}'));
    final metadataGate = Completer<void>();
    store.metadataGate = metadataGate.future;
    try {
      final summary = (await scan(waitForDetails: false)).single;
      expect(summary.id, _archivePath);
      expect(summary.cover, cover);
      expect((await cached(summary.id)).snapshot, isNull);
    } finally {
      metadataGate.complete();
    }

    await engine.waitForBackgroundTasks();
    final details = (await engine.loadComicInfo(_archivePath)).data;
    expect(details.cover, cover);
    expect(details.maxPage, 2);
    expect((await cached(_archivePath)).snapshot!['cover'], cover);
    final version = (await cached(_archivePath)).remoteETag;
    expect(version, startsWith('venera:'));

    // 同路径和大小，只有封面版本变化。
    store.put(cover, [3]);
    expect((await scan()).single.cover, cover);
    final updatedVersion = (await cached(_archivePath)).remoteETag;
    expect(updatedVersion, isNot(version));

    store.files.remove(cover);
    final summary = (await scan()).single;
    expect(summary.id, _archivePath);
    final fallback = (await engine.loadComicInfo(_archivePath)).data.cover;
    expect(summary.cover, startsWith(remoteArchiveImagePrefix));
    expect(RemoteArchiveComic.parseImageKey(fallback)?.entry, 'cover.jpg');
    final config = await engine.getImageLoadingConfig(
      fallback,
      _archivePath,
      '',
    );
    final load = config['loadBytes'] as Future<Uint8List> Function(CancelToken);
    expect(await load(CancelToken()), _archiveCoverBytes);
    expect((await cached(_archivePath)).remoteETag, isNot(updatedVersion));
    expect(store.files, contains('${_archiveDirectory}cover.jpg'));
  }, skip: !isSqliteAvailable());

  test('平铺多卷作品各自使用自己的封面，旁车不会变成额外的图片漫画', () async {
    _seedFlatWorks(store);
    final comics = await scan();
    expect(
      comics.map((comic) => comic.title),
      unorderedEquals(['作品 A', '作品 B']),
    );
    final first = comics.singleWhere((comic) => comic.title == '作品 A');
    final other = comics.singleWhere((comic) => comic.title == '作品 B');
    expect(RemoteComicWork.location(first.id).family, '作品 A');
    expect(RemoteComicWork.location(other.id).family, '作品 B');
    expect(first.cover, '$_flatDirectory作品 A.cover.jpg');
    expect(other.cover, startsWith(remoteComicWorkImagePrefix));
    final firstDetails = (await engine.loadComicInfo(first.id)).data;
    final otherDetails = (await engine.loadComicInfo(other.id)).data;
    expect(firstDetails.cover, first.cover);
    expect(otherDetails.cover, other.cover);
    expect(firstDetails.chapters?.ids, [
      '$_flatDirectory作品 A 01.cbz',
      '$_flatDirectory作品 A 02.cbz',
    ]);
    expect(otherDetails.chapters?.ids, [
      '$_flatDirectory作品 B 01.cbz',
      '$_flatDirectory作品 B 02.cbz',
    ]);
  }, skip: !isSqliteAvailable());

  test('独立目录作品和混排图片漫画使用根封面，旁车不计入正文', () async {
    _seedDirectoryWork(store);
    _seedImageDirectory(store);
    store.put('${_imageDirectory}Single.cbz', _zip());
    store.put('${_imageDirectory}Single.cbz.cover.png', [7]);

    final comics = await scan();
    expect(comics, hasLength(3));
    final work = comics.singleWhere((comic) => comic.title == 'Directory Work');
    expect(RemoteComicWork.location(work.id).family, isNull);
    expect(work.cover, '${_workDirectory}cover.jpg');
    final workDetails = (await engine.loadComicInfo(work.id)).data;
    expect(workDetails.cover, work.cover);
    expect(workDetails.chapters?.ids, hasLength(2));

    final images = comics.singleWhere((comic) => comic.id == _imageDirectory);
    expect(images.cover, '${_imageDirectory}cover.jpg');
    final details = (await engine.loadComicInfo(images.id)).data;
    expect(details.cover, images.cover);
    expect(details.maxPage, 3);
    expect(
      (await engine.loadComicPages(
        images.id,
        RemoteLibrarySource.rootChapterId,
      )).data,
      ['${_imageDirectory}001.jpg', '${_imageDirectory}002.jpg'],
    );
    expect((await engine.loadComicPages(images.id, 'Chapter 01')).data, [
      '${_imageDirectory}Chapter 01/001.jpg',
    ]);
    expect(
      comics
          .singleWhere((comic) => comic.id == '${_imageDirectory}Single.cbz')
          .cover,
      '${_imageDirectory}Single.cbz.cover.png',
    );
  }, skip: !isSqliteAvailable());

  final transferCases = [
    (
      label: '单文件',
      stem: '$_archivePath.cover',
      seed: _seedArchiveCollection,
      fallback: startsWith(remoteArchiveImagePrefix),
    ),
    (
      label: '平铺多卷作品',
      stem: '$_flatDirectory作品 A.cover',
      seed: (_CoverStore store) {
        _seedFlatWorks(store);
        store.put('$_flatDirectory作品 B.cover.webp', [4]);
      },
      fallback: startsWith(remoteComicWorkImagePrefix),
    ),
    (
      label: '独立目录多卷作品',
      stem: '${_workDirectory}cover',
      seed: _seedDirectoryWork,
      fallback: startsWith(remoteComicWorkImagePrefix),
    ),
    (
      label: '图片目录漫画',
      stem: '${_imageDirectory}cover',
      seed: _seedImageDirectory,
      fallback: equals('${_imageDirectory}001.jpg'),
    ),
  ];

  for (final scenario in transferCases) {
    test('${scenario.label}按归属先传后删，并恢复默认封面', () async {
      scenario.seed(store);
      final oldCover = '${scenario.stem}.jpg';
      final newCover = '${scenario.stem}.png';
      final comic = (await scan()).singleWhere(
        (comic) => comic.cover == oldCover,
      );
      // 建立完整详情快照，并保存待保护的其他作品和正文文件。
      expect((await engine.loadComicInfo(comic.id)).data.cover, oldCover);
      final previousVersion = (await cached(comic.id)).remoteETag;
      final untouched = Map.of(store.files)..remove(oldCover);

      final replaced = (await engine.replaceCover(
        comic.id,
        localPath: uploadPath,
        extension: 'PNG',
      )).data;
      expect(store.transfers, [('upload', newCover), ('delete', oldCover)]);
      expect(replaced.changed, isTrue);
      expect(replaced.previousCover, oldCover);
      expect(replaced.cover, newCover);
      expect(replaced.failedOldCoverRemovals, isEmpty);
      expect(
        replaced.invalidatedCoverPaths,
        unorderedEquals([oldCover, newCover]),
      );
      expect(store.files[newCover]?.bytes, _uploadedBytes);
      expect(Map.of(store.files)..remove(newCover), untouched);
      final stored = await cached(comic.id);
      expect(stored.cover, newCover);
      expect(stored.snapshot!['cover'], newCover);
      expect(stored.remoteETag, isNot(previousVersion));
      expect((await engine.loadComicInfo(comic.id)).data.cover, newCover);

      store.transfers.clear();
      final restored = (await engine.restoreDefaultCover(comic.id)).data;
      expect(store.transfers, [('delete', newCover)]);
      expect(store.files, untouched);
      expect(restored.changed, isTrue);
      expect(restored.previousCover, newCover);
      expect(restored.cover, scenario.fallback);
      expect(restored.invalidatedCoverPaths, [newCover]);
      expect((await cached(comic.id)).snapshot!['cover'], restored.cover);
      expect((await engine.loadComicInfo(comic.id)).data.cover, restored.cover);

      store.transfers.clear();
      final unchanged = (await engine.restoreDefaultCover(comic.id)).data;
      expect(unchanged.changed, isFalse);
      expect(unchanged.cover, restored.cover);
      expect(store.transfers, isEmpty);
      expect(store.files, untouched);
    }, skip: !isSqliteAvailable());
  }

  test('同后缀替换只上传，并保留覆盖后的文件', () async {
    _seedImageDirectory(store);
    const cover = '${_imageDirectory}cover.jpg';
    final comic = (await scan()).single;
    final previousVersion = (await cached(comic.id)).remoteETag;

    final result = (await engine.replaceCover(
      comic.id,
      localPath: uploadPath,
      extension: 'JPG',
    )).data;
    expect(store.transfers, [('upload', cover)]);
    expect(store.files[cover]?.bytes, _uploadedBytes);
    expect(result.changed, isTrue);
    expect(result.previousCover, cover);
    expect(result.cover, cover);
    expect(result.invalidatedCoverPaths, [cover]);
    expect((await cached(comic.id)).remoteETag, isNot(previousVersion));
  }, skip: !isSqliteAvailable());

  test('上传失败时保留旧封面及原快照', () async {
    _seedImageDirectory(store);
    const cover = '${_imageDirectory}cover.jpg';
    const newCover = '${_imageDirectory}cover.png';
    final comic = (await scan()).single;
    final previousFiles = Map.of(store.files);
    final previousVersion = (await cached(comic.id)).remoteETag;
    store.failedUpload = newCover;
    final result = await engine.replaceCover(
      comic.id,
      localPath: uploadPath,
      extension: 'png',
    );

    expect(result.errorMessage, contains('上传被拒绝'));
    expect(store.transfers, [('upload', newCover)]);
    expect(store.files, previousFiles);
    final snapshot = await cached(comic.id);
    expect(snapshot.cover, cover);
    expect(snapshot.remoteETag, previousVersion);
  }, skip: !isSqliteAvailable());

  test('替换后旧封面删除失败时，仍将新封面写入详情和本地索引', () async {
    _seedImageDirectory(store);
    const cover = '${_imageDirectory}cover.jpg';
    const newCover = '${_imageDirectory}cover.png';
    final comic = (await scan()).single;
    final previousBytes = store.files[cover]!.bytes;
    store.failedDelete = cover;
    final result = (await engine.replaceCover(
      comic.id,
      localPath: uploadPath,
      extension: 'png',
    )).data;

    expect(store.transfers, [('upload', newCover), ('delete', cover)]);
    expect(store.files[cover]?.bytes, previousBytes);
    expect(store.files[newCover]?.bytes, _uploadedBytes);
    expect(result.cover, newCover);
    expect(result.failedOldCoverRemovals, ['cover.jpg']);
    expect((await cached(comic.id)).cover, newCover);
    expect((await engine.loadComicInfo(comic.id)).data.cover, newCover);
  }, skip: !isSqliteAvailable());
}

List<int> _zip() => archive.ZipEncoder().encode(
  archive.Archive()
    ..addFile(archive.ArchiveFile.bytes('cover.jpg', _archiveCoverBytes))
    ..addFile(archive.ArchiveFile.bytes('001.jpg', [2]))
    ..addFile(archive.ArchiveFile.bytes('002.jpg', [4])),
);

void _seedArchiveCollection(_CoverStore store) {
  store.put(_archivePath, _zip());
  store.put('$_archivePath.cover.jpg', [1]);
  store.put('${_archiveDirectory}cover.jpg', [2]);
  store.put('${_archiveDirectory}Other.zip.cover.jpg', [3]);
}

void _seedFlatWorks(_CoverStore store) {
  for (final title in ['作品 A', '作品 B']) {
    for (final volume in ['01', '02']) {
      store.put('$_flatDirectory$title $volume.cbz', _zip());
    }
  }
  store.put('$_flatDirectory作品 A.cover.jpg', [1]);
  store.put('${_flatDirectory}cover.jpg', [2]);
  store.put('$_flatDirectory作品 A 01.cbz.cover.webp', [3]);
}

void _seedDirectoryWork(_CoverStore store) {
  store.put('${_workDirectory}Vol. 01.cbz', _zip());
  store.put('${_workDirectory}Vol. 02.cbz', _zip());
  store.put('${_workDirectory}cover.jpg', [1]);
  store.put('${_workDirectory}Vol. 01.cbz.cover.webp', [2]);
}

void _seedImageDirectory(_CoverStore store) {
  store.put('${_imageDirectory}cover.jpg', [1]);
  store.put('${_imageDirectory}001.jpg', [2]);
  store.put('${_imageDirectory}002.jpg', [3]);
  store.put('${_imageDirectory}Chapter 01/001.jpg', [4]);
  store.put('${_imageDirectory}Chapter 01/cover.webp', [5]);
  store.put('${_imageDirectory}Chapter 01/Related.cbz.cover.webp', [6]);
}

class _CoverStore extends Fake implements RemoteFileStore {
  @override
  final account = const StorageAccount(
    id: _libraryId,
    backend: StorageBackend.webdav,
    driver: 'webdav',
    name: '封面测试账号',
    authorization: {},
  );

  final files = <String, ({List<int> bytes, String eTag})>{};
  final transfers = <(String, String)>[];
  Future<void>? metadataGate;
  String? failedUpload;
  String? failedDelete;
  int _version = 0;

  void put(String path, List<int> bytes) {
    files[path] = (bytes: bytes, eTag: '"v${++_version}"');
  }

  @override
  Future<List<RemoteEntry>> list(
    String directory, {
    bool refresh = false,
  }) async {
    final parent = normalizeRemoteDirectory(directory);
    final entries = <String, RemoteEntry>{};
    for (final path in files.keys.where((path) => path.startsWith(parent))) {
      final relative = path.substring(parent.length);
      final slash = relative.indexOf('/');
      if (slash < 0) {
        entries[relative] = _entry(path);
      } else {
        final name = relative.substring(0, slash);
        entries[name] = RemoteEntry(
          name: name,
          path: '$parent$name/',
          isDirectory: true,
          eTag: 'directory',
        );
      }
    }
    return entries.values.toList();
  }

  RemoteEntry _entry(String path) {
    final file = files[path]!;
    return RemoteEntry(
      name: path.substring(path.lastIndexOf('/') + 1),
      path: path,
      isDirectory: false,
      size: file.bytes.length,
      eTag: file.eTag,
    );
  }

  @override
  Future<RemoteEntry> stat(String path) async => _entry(path);

  @override
  Future<RemoteTextFile> readText(String path) async {
    await metadataGate;
    final file = files[path]!;
    return RemoteTextFile(content: utf8.decode(file.bytes), eTag: file.eTag);
  }

  @override
  Future<RemoteLink> link(String path, {bool refresh = false}) async =>
      RemoteLink(
        url: Uri.https('cover.test', '/file', {'path': path}).toString(),
      );

  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {
    transfers.add(('upload', remotePath));
    if (remotePath == failedUpload) throw StateError('上传被拒绝');
    put(remotePath, await File(localPath).readAsBytes());
  }

  @override
  Future<void> delete(String path) async {
    transfers.add(('delete', path));
    if (path == failedDelete) throw StateError('删除被拒绝');
    if (files.remove(path) == null) throw StateError('文件不存在 $path');
  }

  @override
  Future<void> cancelAll() async {}
}

class _CoverRangeAdapter implements HttpClientAdapter {
  _CoverRangeAdapter(this.store);

  final _CoverStore store;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.queryParameters['path'];
    final file = store.files[path]!;
    final range = RegExp(
      r'^bytes=(\d+)-(\d+)$',
    ).firstMatch(options.headers['Range'] as String)!;
    final start = int.parse(range.group(1)!);
    final end = int.parse(range.group(2)!);
    return ResponseBody.fromBytes(
      file.bytes.sublist(start, end + 1),
      206,
      headers: {
        'content-range': ['bytes $start-$end/${file.bytes.length}'],
        'content-length': ['${end - start + 1}'],
        'etag': [file.eTag],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
