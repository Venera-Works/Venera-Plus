part of 'remote_library_engine.dart';

class _RemoteLibraryMetadataPipeline {
  _RemoteLibraryMetadataPipeline(this._engine);
  final RemoteLibraryEngine _engine;
  final metadataPendingVersion = ValueNotifier<int>(0);
  final _metadataWriteTails = <String, Future<void>>{};
  int _metadataPayloadSequence = 0;
  Timer? _metadataRetryTimer;
  final _completions = <String, Future<void> Function()>{};
  final _scrapes = <String, Future<void> Function()>{};
  final _scrapeKeys = <String>{};
  final _active = <Future<void>>{};
  final _operations = <Future<void>>{};
  final _pendingSnapshots =
      <
        String,
        ({
          RemoteLibraryConfig config,
          RemoteLibraryCachedComic comic,
          _RemoteLibrarySyncRun run,
        })
      >{};
  Future<void> _snapshotWriteTail = Future<void>.value();
  Timer? _snapshotTimer;
  int _completionWorkers = 0;
  int _scrapeWorkers = 0;
  int? _snapshotGeneration;
  final _cancelled = Completer<void>();

  void enqueueCompletion(
    RemoteLibraryConfig config,
    _RemoteDiscoveredDirectory comic,
    RemoteLibraryRemoteDirectory directory,
    _RemoteLibrarySyncRun run,
  ) {
    if (!_engine._isSynchronizationCurrent(run)) return;
    final key = '${run.generation}:${directory.id}';
    _completions[key] = () async {
      _engine._throwIfSynchronizationObsolete(run);
      final snapshot = await _engine._loadSnapshot(
        config,
        directory.id,
        forceRefresh: true,
        summaryOnly: comic.archiveFile != null,
        background: true,
        remoteDirectory: directory,
        archiveFile: comic.archiveFile,
        work: comic.work,
        rootEntries: comic.entries,
        childEntries: comic.childEntries,
        syncRun: run,
      );
      _engine._throwIfSynchronizationObsolete(run);
      _engine._notifyMetadataSubject(
        config,
        directory.id,
        snapshot.bangumiSubjectId,
      );
      enqueueScrape(config, directory.id, snapshot, run: run);
    };
    _pump();
  }

  void enqueueScrape(
    RemoteLibraryConfig config,
    String id,
    _RemoteComicSnapshot snapshot, {
    _RemoteLibrarySyncRun? run,
  }) {
    if (_engine._state.disposed ||
        !RemoteLibrarySource._canScrapeMetadata ||
        snapshot.archive != null && !snapshot.archive!.isInspected ||
        !_shouldAttemptMetadataScrape(
          previousSnapshot: snapshot,
          metadataFilePresent: snapshot.metadataFilePresent,
          scraperVersion: RemoteLibrarySource._metadataScraperVersion,
          now: RemoteLibrarySource.metadataNowProvider(),
          automaticScrapingEnabled: true,
        )) {
      return;
    }
    final generation = run?.generation ?? _engine._state.syncGeneration;
    final key = '$generation:$id';
    if (!_scrapeKeys.add(key)) return;
    _scrapes[key] = () async {
      try {
        if (generation != _engine._state.syncGeneration) return;
        if (run != null) _engine._throwIfSynchronizationObsolete(run);
        final target = _engine._metadataTarget(config, id);
        final work = snapshot.work;
        final archive = snapshot.archive;
        final result = await _scrapeMissingMetadata(
          config,
          id,
          target.directory,
          fileName: target.fileName,
          pageCount: snapshot.pageCount,
          input: RemoteLibraryMetadataInput(
            title: target.title,
            directoryTitle: _directoryName(target.directory),
            fileNames: [
              ...snapshot.chapterImages.keys,
              for (final image in snapshot.rootImages) image.name,
              for (final images in snapshot.chapterImages.values) ...images,
              if (work != null)
                for (final volume in work.volumes)
                  _directoryName(volume.archive.path),
              if (archive != null) ...[
                _directoryName(archive.path),
                if (archive.index != null)
                  for (final entry in archive.index!.entries)
                    _directoryName(entry.name),
                ...?archive.epubPages,
              ],
            ],
            authors: _metadataAuthors([
              snapshot.author,
              archive?.embeddedMetadata?.author,
            ]),
          ),
          syncRun: run,
          expectedGeneration: generation,
        );
        _ensureMetadataContextActive();
        if (generation != _engine._state.syncGeneration) return;
        // 刮削独立于章节加载，合并到此刻最新的快照，保住期间取得的卷索引。
        await flushSnapshots();
        await _engine._withSnapshotLock(id, () async {
          if (generation != _engine._state.syncGeneration) return;
          final cached = await _engine._cache.find(config.cacheKey, id);
          if (cached == null || !cached.isReady) return;
          final memoryKey = jsonEncode([config.cacheKey, id]);
          final latest =
              _engine._snapshotCache[memoryKey] ??
              _RemoteComicSnapshot.fromJson(cached.snapshot!);
          final json = latest.toJson();
          json.addAll({
            'metadataFilePresent': result.filePresent,
            'metadataScrapeStatus': result.status,
            'metadataScraperVersion':
                RemoteLibrarySource._metadataScraperVersion,
            'metadataScrapeAttemptedAt': result.attemptedAt,
            'metadataScrapeRetryAt': result.retryAt,
            'metadataScrapeError': result.error,
          });
          if (result.metadata != null) {
            final metadata = result.metadata!;
            json.addAll({
              'title': metadata.title,
              'author': metadata.author,
              'tags': metadata.tags,
              'description': metadata.description,
              'bangumiSubjectId': metadata.bangumiSubjectId,
            });
            if (json['archive'] is Map) {
              json['archive'] = RemoteArchiveComic.fromJson(
                Map<String, dynamic>.from(json['archive'] as Map),
              ).withMetadata(metadata).toJson();
            }
            if (latest.rootImages.isNotEmpty &&
                latest.chapterImages.isEmpty &&
                metadata.chapters?.isNotEmpty == true) {
              json['chapters'] = {
                for (var i = 0; i < metadata.chapters!.length; i++)
                  '$_metadataChapterPrefix$i': metadata.chapters![i].title,
              };
              json['metadataChapters'] = {
                for (var i = 0; i < metadata.chapters!.length; i++)
                  '$_metadataChapterPrefix$i': metadata.chapters![i].toJson(),
              };
            }
          }
          if (generation != _engine._state.syncGeneration) return;
          final updated = _RemoteComicSnapshot.fromJson(
            json,
            retainedWork: latest.work,
            retainedArchive: latest.archive?.withMetadata(
              result.metadata ?? latest.archive?.metadata,
            ),
          );
          await _engine._cache.upsertSnapshots(config.cacheKey, [
            RemoteLibraryCachedComic(
              id: id,
              sortIndex: _engine._state.sortIndexes[id] ?? cached.sortIndex,
              title: updated.title,
              author: updated.author,
              tags: updated.tags,
              cover: updated.cover,
              snapshot: updated.toJson(),
              remoteETag: cached.remoteETag,
              remoteModifiedAt: cached.remoteModifiedAt,
            ),
          ]);
          if (generation != _engine._state.syncGeneration ||
              _engine._state.disposed) {
            return;
          }
          _engine._snapshotCache[memoryKey] = updated;
          _engine._notifyMetadataSubject(config, id, updated.bangumiSubjectId);
          _engine._notifyContent();
        });
      } finally {
        _scrapeKeys.remove(key);
      }
    };
    _pump();
  }

  void _pump() {
    if (_engine._state.disposed) return;
    while (_completionWorkers < 2 && _completions.isNotEmpty) {
      final key = _completions.keys.first;
      final action = _completions.remove(key)!;
      _completionWorkers++;
      _startWorker(action, scraping: false);
    }
    while (_scrapeWorkers < 2 && _scrapes.isNotEmpty) {
      final key = _scrapes.keys.first;
      final action = _scrapes.remove(key)!;
      _scrapeWorkers++;
      _startWorker(action, scraping: true);
    }
  }

  void _startWorker(Future<void> Function() action, {required bool scraping}) {
    late final Future<void> task;
    task = RemoteReadContext(priority: RemoteReadPriority.background).run(
      () async {
        try {
          await action();
        } on _RemoteSynchronizationObsoleteException {
          // 新 generation 已接管这个作品。
        } on RemoteLibraryMetadataWriteRejectedException {
          // 引擎关闭后停止补全与写回。
        } catch (error, stackTrace) {
          if (!_engine._state.disposed) {
            Log.error('Remote Library metadata', error, stackTrace);
          }
        } finally {
          if (scraping) {
            _scrapeWorkers--;
          } else {
            _completionWorkers--;
          }
          _active.remove(task);
          _pump();
        }
      },
    );
    _active.add(task);
  }

  void bufferSnapshot(
    RemoteLibraryConfig config,
    RemoteLibraryCachedComic comic,
    _RemoteLibrarySyncRun run,
  ) {
    _engine._throwIfSynchronizationObsolete(run);
    _pendingSnapshots[comic.id] = (config: config, comic: comic, run: run);
    if (_snapshotGeneration != run.generation) {
      _snapshotGeneration = run.generation;
      unawaited(
        flushSnapshots().catchError((Object error, StackTrace stackTrace) {
          Log.error('Remote Library snapshot batch', error, stackTrace);
        }),
      );
    } else if (_pendingSnapshots.length >= 64) {
      unawaited(
        flushSnapshots().catchError((Object error, StackTrace stackTrace) {
          Log.error('Remote Library snapshot batch', error, stackTrace);
        }),
      );
    } else {
      _snapshotTimer ??= Timer(const Duration(milliseconds: 200), () {
        _snapshotTimer = null;
        unawaited(
          flushSnapshots().catchError((Object error, StackTrace stackTrace) {
            Log.error('Remote Library snapshot batch', error, stackTrace);
          }),
        );
      });
    }
  }

  Future<void> flushSnapshots() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    final rows = List.of(_pendingSnapshots.values);
    _pendingSnapshots.clear();
    final write = _snapshotWriteTail.then((_) async {
      if (rows.isEmpty || _engine._state.disposed) return;
      final current = rows
          .where((row) => _engine._isSynchronizationCurrent(row.run))
          .toList();
      if (current.isEmpty) return;
      final ids = current.map((row) => row.comic.id).toList()..sort();
      Future<void> writeLocked(int index) async {
        if (index < ids.length) {
          await _engine._withSnapshotLock(
            ids[index],
            () => writeLocked(index + 1),
          );
          return;
        }
        await _engine._cache.upsertSnapshots(current.first.config.cacheKey, [
          for (final row in current)
            RemoteLibraryCachedComic(
              id: row.comic.id,
              sortIndex:
                  _engine._state.sortIndexes[row.comic.id] ??
                  row.comic.sortIndex,
              title:
                  _engine
                      ._snapshotCache[jsonEncode([
                        row.config.cacheKey,
                        row.comic.id,
                      ])]
                      ?.title ??
                  row.comic.title,
              author:
                  _engine
                      ._snapshotCache[jsonEncode([
                        row.config.cacheKey,
                        row.comic.id,
                      ])]
                      ?.author ??
                  row.comic.author,
              tags:
                  _engine
                      ._snapshotCache[jsonEncode([
                        row.config.cacheKey,
                        row.comic.id,
                      ])]
                      ?.tags ??
                  row.comic.tags,
              cover:
                  _engine
                      ._snapshotCache[jsonEncode([
                        row.config.cacheKey,
                        row.comic.id,
                      ])]
                      ?.cover ??
                  row.comic.cover,
              snapshot:
                  _engine
                      ._snapshotCache[jsonEncode([
                        row.config.cacheKey,
                        row.comic.id,
                      ])]
                      ?.toJson() ??
                  row.comic.snapshot,
              remoteETag: row.comic.remoteETag,
              remoteModifiedAt: row.comic.remoteModifiedAt,
            ),
        ]);
      }

      await writeLocked(0);
      if (!_engine._state.disposed) _engine._notifyContent();
    });
    _snapshotWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<T> _track<T>(Future<T> operation) {
    late final Future<void> done;
    done = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations.remove(done));
    _operations.add(done);
    return operation;
  }

  Future<void> waitForIdle() async {
    while (_active.isNotEmpty || _operations.isNotEmpty) {
      await Future.wait([..._active, ..._operations]);
    }
    await flushSnapshots();
    await Future.wait(_metadataWriteTails.values.toList());
  }

  Future<void> cancel() async {
    _metadataRetryTimer?.cancel();
    _snapshotTimer?.cancel();
    _completions.clear();
    _scrapes.clear();
    _pendingSnapshots.clear();
    if (!_cancelled.isCompleted) _cancelled.complete();
    await waitForIdle();
  }

  String get _metadataPendingStorageKey =>
      _engine._config.configuredSourceKey == RemoteLibrarySource.sourceKey
      ? _metadataPendingKey
      : '$_metadataPendingKey:${_engine.libraryId}';
  List<RemoteLibraryMetadataPendingStatus> get metadataPendingStatuses =>
      _pendingMetadataWrites()
          .map((pending) => pending.status)
          .toList(growable: false);
  Future<Res<RemoteLibraryMetadataScrapeResult>> retryMetadataScrape(
    String id,
  ) => _track(_retryMetadataScrape(id));

  Future<Res<RemoteLibraryMetadataScrapeResult>> _retryMetadataScrape(
    String id,
  ) async {
    final config = _engine._config;
    if (!config.isValid) {
      return const Res.error('Invalid remote comic library configuration');
    }
    if (RemoteLibrarySource._metadataScraper == null) {
      return const Res.error('Metadata scraping is unavailable');
    }
    try {
      final snapshot = await _engine._loadSnapshot(
        config,
        id,
        forceRefresh: true,
        forceMetadataScrape: true,
      );
      _engine._notifyMetadataSubject(config, id, snapshot.bangumiSubjectId);
      _engine._notifyContent();
      return switch (snapshot.metadataScrapeStatus) {
        'matched' => const Res(RemoteLibraryMetadataScrapeResult.matched),
        'noMatch' => const Res(RemoteLibraryMetadataScrapeResult.noMatch),
        'notNeeded' => const Res(RemoteLibraryMetadataScrapeResult.notNeeded),
        _ => Res.error(
          snapshot.metadataScrapeError ?? 'Metadata scraping is unavailable',
        ),
      };
    } catch (error) {
      return Res.error(error.toString());
    }
  }

  int _nextMetadataPayloadSequence() {
    for (final pending in _pendingMetadataWrites()) {
      if (pending.sequence > _metadataPayloadSequence) {
        _metadataPayloadSequence = pending.sequence;
      }
    }
    return ++_metadataPayloadSequence;
  }

  Future<void> writeMetadata(
    String id,
    ComicMetaData metadata, {
    String? expectedLibraryId,
    int? expectedSubjectId,
  }) => _track(
    _writeMetadata(
      id,
      metadata,
      expectedLibraryId: expectedLibraryId,
      expectedSubjectId: expectedSubjectId,
    ),
  );

  Future<void> _writeMetadata(
    String id,
    ComicMetaData metadata, {
    String? expectedLibraryId,
    int? expectedSubjectId,
  }) async {
    final config = _engine._config;
    if (!config.isValid) {
      throw StateError('Invalid remote comic library configuration');
    }
    final pending = _RemotePendingMetadataWrite(
      libraryId: expectedLibraryId ?? config.libraryId,
      comicId: id,
      subjectId: expectedSubjectId ?? metadata.bangumiSubjectId,
      metadata: metadata,
      sequence: _nextMetadataPayloadSequence(),
    );
    try {
      await _writeMetadataNow(config, pending);
    } on RemoteLibraryMetadataWriteRejectedException {
      if (!_engine._state.disposed) {
        await _removePendingMetadataWrite(pending);
      }
      rethrow;
    } catch (error, stackTrace) {
      await _recordPendingMetadataWrite(pending, error);
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _removePendingMetadataWrite(pending);
    await _refreshSnapshotAfterMetadataWrite(config, id);
  }

  Future<void> _writeMetadataNow(
    RemoteLibraryConfig config,
    _RemotePendingMetadataWrite pending,
  ) async {
    await _ensureMetadataWriteCurrent(config, pending);
    final target = _engine._metadataTarget(config, pending.comicId);
    final memoryKey = jsonEncode([config.cacheKey, pending.comicId]);
    final cached = await _engine._cache.find(config.cacheKey, pending.comicId);
    final archive = _engine._isArchiveId(pending.comicId)
        ? (_engine._snapshotCache[memoryKey]?.archive ??
              (cached?.isReady == true
                  ? _RemoteComicSnapshot.fromJson(cached!.snapshot!).archive
                  : null))
        : null;
    await _runMetadataWrite(config, pending.comicId, () async {
      for (var attempt = 0; attempt < _maxMetadataMergeAttempts; attempt++) {
        await _ensureMetadataWriteCurrent(config, pending);
        final entries = List<RemoteLibraryEntry>.from(
          await _engine._readDirectory(config, target.directory, refresh: true),
        );
        final pageCount = pending.comicId.startsWith(remoteComicWorkPrefix)
            ? null
            : _engine._isArchiveId(pending.comicId)
            ? archive?.pageCount
            : _metadataPageCount(entries);
        final metadataEntry = entries.firstWhereOrNull(
          (entry) =>
              !entry.isDirectory &&
              entry.name.toLowerCase() == target.fileName.toLowerCase(),
        );
        final metadataPath = config.childFilePath(
          target.directory,
          metadataEntry?.name ?? target.fileName,
        );
        try {
          if (metadataEntry == null) {
            final document = _mergeMetadataDocument(
              archive?.embeddedMetadata?.toJson() ?? const {},
              pending.metadata,
              fallbackTitle: target.title,
              pageCount: pageCount,
            );
            await _ensureMetadataWriteCurrent(config, pending);
            await _engine._writeText(
              config,
              metadataPath,
              _encodeMetadataDocument(document),
              createOnly: true,
            );
          } else {
            final current = await _engine._readText(config, metadataPath);
            final document = _mergeMetadataDocument(
              {
                ...?archive?.embeddedMetadata?.toJson(),
                ..._decodeMetadataDocument(current.content),
              },
              pending.metadata,
              fallbackTitle: target.title,
              pageCount: pageCount,
            );
            final strongETag = _strongETag(current.eTag);
            if (strongETag == null && current.modifiedAt == null) {
              throw RemoteLibraryUnsupportedException(
                metadataPath,
                message:
                    'The WebDAV server returned no strong ETag or '
                    'Last-Modified validator for $metadataPath',
              );
            }
            await _ensureMetadataWriteCurrent(config, pending);
            await _engine._writeText(
              config,
              metadataPath,
              _encodeMetadataDocument(document),
              ifMatch: strongETag,
              ifUnmodifiedSince: strongETag == null ? current.modifiedAt : null,
            );
          }
          return;
        } on RemoteLibraryPreconditionFailedException {
          if (attempt + 1 >= _maxMetadataMergeAttempts) rethrow;
        }
      }
    });
  }

  String? _strongETag(String? eTag) {
    final candidate = eTag?.trim();
    if (candidate == null ||
        candidate.isEmpty ||
        candidate.toLowerCase().startsWith('w/')) {
      return null;
    }
    return candidate;
  }

  Future<void> _ensureMetadataWriteCurrent(
    RemoteLibraryConfig config,
    _RemotePendingMetadataWrite pending,
  ) async {
    _ensureMetadataContextActive();
    if (config.libraryId != pending.libraryId ||
        _engine._config.libraryId != pending.libraryId) {
      throw const RemoteLibraryMetadataWriteRejectedException();
    }
    final guard = RemoteLibrarySource._metadataWriteGuard;
    if (guard != null &&
        !await Future.sync(
          () => guard(pending.libraryId, pending.comicId, pending.subjectId),
        )) {
      throw const RemoteLibraryMetadataWriteRejectedException();
    }
  }

  void _ensureMetadataContextActive() {
    if (_engine._state.disposed) {
      throw const RemoteLibraryMetadataWriteRejectedException();
    }
  }

  Map<String, dynamic> _decodeMetadataDocument(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('metadata.json must contain an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _mergeMetadataDocument(
    Map<String, dynamic> current,
    ComicMetaData metadata, {
    required String fallbackTitle,
    required int? pageCount,
  }) {
    List<ComicChapter>? chapters = metadata.chapters;
    final currentChapters = current['chapters'];
    if (currentChapters == null) {
      if (current.containsKey('chapters')) chapters = null;
    } else if (currentChapters is List) {
      try {
        final parsed = currentChapters.map((chapter) {
          if (chapter is! Map) {
            throw const FormatException(
              'metadata.chapters entries must be objects',
            );
          }
          return ComicChapter.fromJson(Map<String, dynamic>.from(chapter));
        }).toList();
        final candidate = ComicMetaData(
          title: metadata.title,
          author: metadata.author,
          tags: metadata.tags,
          description: metadata.description,
          chapters: parsed,
          bangumiSubjectId: metadata.bangumiSubjectId,
        );
        candidate.validateChapterRanges(pageCount: pageCount);
        chapters = parsed;
      } on FormatException {
        // Preserve only a structurally valid chapter list. Other corrupt
        // metadata fields must not make valid ranges disappear on update.
      }
    }
    final currentSubjectId = current['bangumiSubjectId'];
    final merged = ComicMetaData(
      title: metadata.title.trim().isEmpty ? fallbackTitle : metadata.title,
      author: metadata.author,
      tags: metadata.tags,
      description: metadata.description,
      chapters: chapters,
      bangumiSubjectId:
          metadata.bangumiSubjectId ??
          (currentSubjectId is int && currentSubjectId > 0
              ? currentSubjectId
              : null),
    );
    merged.validateChapterRanges(pageCount: pageCount);
    final result = <String, dynamic>{...current, ...merged.toJson()};
    if (merged.bangumiSubjectId == null) {
      result.remove('bangumiSubjectId');
    }
    return result;
  }

  Future<void> _refreshSnapshotAfterMetadataWrite(
    RemoteLibraryConfig config,
    String id,
  ) async {
    if (_engine._state.disposed) return;
    final memoryKey = jsonEncode([config.cacheKey, id]);
    final inFlight = _engine._snapshotInFlight[memoryKey];
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    _engine._snapshotCache.remove(memoryKey);
    try {
      if (_engine._state.disposed) return;
      await _engine._loadSnapshot(
        config,
        id,
        forceRefresh: true,
        summaryOnly: _engine._isArchiveId(id),
      );
      _engine._notifyContent();
    } catch (error, stackTrace) {
      Log.error('Remote Library metadata cache refresh', error, stackTrace);
    }
  }

  Future<
    ({
      ComicMetaData? metadata,
      bool filePresent,
      String status,
      int? attemptedAt,
      int? retryAt,
      String? error,
    })
  >
  _scrapeMissingMetadata(
    RemoteLibraryConfig config,
    String id,
    String comicPath, {
    required int? pageCount,
    String fileName = _metadataFileName,
    required RemoteLibraryMetadataInput input,
    _RemoteLibrarySyncRun? syncRun,
    bool forceMetadataScrape = false,
    int? expectedGeneration,
  }) async {
    final generation = expectedGeneration ?? _engine._state.syncGeneration;
    final scanToken = _engine._state.scanToken;
    void ensureCurrent() {
      _ensureMetadataContextActive();
      if (generation != _engine._state.syncGeneration) {
        throw const _RemoteSynchronizationObsoleteException();
      }
      if (syncRun != null) _engine._throwIfSynchronizationObsolete(syncRun);
    }

    final scraper = RemoteLibrarySource._metadataScraper;
    if (scraper == null ||
        (!forceMetadataScrape && !RemoteLibrarySource._canScrapeMetadata)) {
      return (
        metadata: null,
        filePresent: false,
        status: 'pending',
        attemptedAt: null,
        retryAt: null,
        error: null,
      );
    }
    final attemptedAt = RemoteLibrarySource.metadataNowProvider();
    try {
      final scraped = await Future.any([
        scraper(input),
        scanToken.whenCancel.then<ComicMetaData?>(
          (_) => throw const _RemoteSynchronizationObsoleteException(),
        ),
        _cancelled.future.then<ComicMetaData?>(
          (_) => throw const RemoteLibraryMetadataWriteRejectedException(),
        ),
      ]);
      ensureCurrent();
      if (scraped == null) {
        return (
          metadata: null,
          filePresent: false,
          status: 'noMatch',
          attemptedAt: attemptedAt,
          retryAt: null,
          error: null,
        );
      }
      scraped.validateChapterRanges(pageCount: pageCount);
      return await _runMetadataWrite(config, id, () async {
        final latestEntries = List<RemoteLibraryEntry>.from(
          await _engine._readDirectory(config, comicPath, refresh: true),
        );
        ensureCurrent();
        if (_hasMetadataFile(latestEntries, fileName: fileName)) {
          return (
            metadata: await _readMetadata(
              config,
              comicPath,
              latestEntries,
              fileName: fileName,
              pageCount:
                  _engine._isArchiveId(id) ||
                      id.startsWith(remoteComicWorkPrefix)
                  ? pageCount
                  : _metadataPageCount(latestEntries),
            ),
            filePresent: true,
            status: 'notNeeded',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        }
        try {
          ensureCurrent();
          await _engine._writeText(
            config,
            config.childFilePath(comicPath, fileName),
            _encodeMetadata(scraped),
            createOnly: true,
            expectedGeneration: generation,
          );
          ensureCurrent();
          return (
            metadata: scraped,
            filePresent: true,
            status: 'matched',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        } on RemoteLibraryPreconditionFailedException {
          final refreshedEntries = List<RemoteLibraryEntry>.from(
            await _engine._readDirectory(config, comicPath, refresh: true),
          );
          ensureCurrent();
          if (!_hasMetadataFile(refreshedEntries, fileName: fileName)) rethrow;
          return (
            metadata: await _readMetadata(
              config,
              comicPath,
              refreshedEntries,
              fileName: fileName,
              pageCount:
                  _engine._isArchiveId(id) ||
                      id.startsWith(remoteComicWorkPrefix)
                  ? pageCount
                  : _metadataPageCount(refreshedEntries),
            ),
            filePresent: true,
            status: 'notNeeded',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        }
      });
    } on _RemoteSynchronizationObsoleteException {
      rethrow;
    } on RemoteLibraryMetadataWriteRejectedException {
      rethrow;
    } catch (error) {
      Log.warning(
        'Remote Library',
        'Failed to scrape metadata for $id: $error',
      );
      return (
        metadata: null,
        filePresent: false,
        status: 'failed',
        attemptedAt: attemptedAt,
        retryAt: attemptedAt + const Duration(minutes: 15).inMilliseconds,
        error: error.toString(),
      );
    }
  }

  Future<T> _runMetadataWrite<T>(
    RemoteLibraryConfig config,
    String id,
    Future<T> Function() action,
  ) async {
    final key = jsonEncode([config.cacheKey, id]);
    final previous = _metadataWriteTails[key];
    final done = Completer<void>();
    _metadataWriteTails[key] = done.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      _ensureMetadataContextActive();
      return await action();
    } finally {
      done.complete();
      if (identical(_metadataWriteTails[key], done.future)) {
        _metadataWriteTails.remove(key);
      }
    }
  }

  int? _metadataPageCount(List<RemoteLibraryEntry> entries) {
    if (entries.any(
      (entry) => entry.isDirectory && !_isIgnoredEntry(entry.name),
    )) {
      return null;
    }
    return _imageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).length;
  }

  List<String> _metadataAuthors(Iterable<String?> rawAuthors) {
    final result = <String>{};
    for (final raw in rawAuthors) {
      if (raw == null || raw.trim().isEmpty) continue;
      for (final part in raw.split(RegExp(r'[,，;；/、]'))) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) {
          result.add(trimmed);
        }
      }
    }
    return result.toList(growable: false);
  }

  String _encodeMetadata(ComicMetaData metadata) =>
      _encodeMetadataDocument(metadata.toJson());

  String _encodeMetadataDocument(Map<String, dynamic> metadata) =>
      '${const JsonEncoder.withIndent('  ').convert(metadata)}\n';

  Future<ComicMetaData?> _readMetadata(
    RemoteLibraryConfig config,
    String comicPath,
    List<RemoteLibraryEntry> entries, {
    int? pageCount,
    String fileName = _metadataFileName,
    ComicMetaData? fallback,
  }) async {
    final metadataEntry = entries.firstWhereOrNull(
      (entry) =>
          !entry.isDirectory &&
          entry.name.toLowerCase() == fileName.toLowerCase(),
    );
    if (metadataEntry == null) return null;

    final metadataPath = config.childFilePath(comicPath, metadataEntry.name);
    try {
      final file = await _engine._readText(config, metadataPath);
      final metadata = ComicMetaData.fromJson({
        ...?fallback?.toJson(),
        ..._decodeMetadataDocument(file.content),
      });
      metadata.validateChapterRanges(pageCount: pageCount);
      return metadata;
    } catch (error) {
      Log.warning(
        'Remote Library',
        'Ignoring invalid metadata at $metadataPath: $error',
      );
      return null;
    }
  }

  void initializeMetadataRetry() {
    unawaited(retryPendingMetadata(force: true));
  }

  Future<void> retryPendingMetadata({bool force = false}) => _track(
    RemoteReadContext(
      priority: RemoteReadPriority.background,
    ).run(() => _retryPendingMetadata(force: force)),
  );

  Future<void> _retryPendingMetadata({bool force = false}) async {
    if (_engine._state.disposed) return;
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    final config = _engine._config;
    if (!config.isValid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final pending in _pendingMetadataWrites()) {
      if (_engine._state.disposed) return;
      if (pending.libraryId != config.libraryId ||
          (!force &&
              (pending.attempts >= _maxMetadataRetryAttempts ||
                  pending.nextRetryAt == null ||
                  pending.nextRetryAt! > now))) {
        continue;
      }
      try {
        await _writeMetadataNow(config, pending);
        await _removePendingMetadataWrite(pending);
        await _refreshSnapshotAfterMetadataWrite(config, pending.comicId);
      } on RemoteLibraryMetadataWriteRejectedException {
        // 关闭时保留未写回记录，活动引擎的绑定失效仍需删除。
        if (_engine._state.disposed) return;
        await _removePendingMetadataWrite(pending);
      } catch (error) {
        if (_engine._state.disposed) return;
        await _recordPendingMetadataWrite(pending, error);
      }
    }
    if (!_engine._state.disposed) _scheduleMetadataRetry();
  }

  List<_RemotePendingMetadataWrite> _pendingMetadataWrites() {
    final raw = appdata.implicitData[_metadataPendingStorageKey];
    if (raw is! Map) return const [];
    final result = <_RemotePendingMetadataWrite>[];
    for (final value in raw.values) {
      if (value is! Map) continue;
      try {
        result.add(
          _RemotePendingMetadataWrite.fromJson(
            Map<String, dynamic>.from(value),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  Future<void> _recordPendingMetadataWrite(
    _RemotePendingMetadataWrite pending,
    Object error,
  ) async {
    final failure = _metadataPendingFailure(error);
    final key = _pendingMetadataKey(pending.libraryId, pending.comicId);
    final raw = appdata.implicitData[_metadataPendingStorageKey];
    final entries = <String, dynamic>{
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.key is String) entry.key as String: entry.value,
    };
    final existingRaw = entries[key];
    _RemotePendingMetadataWrite? existing;
    if (existingRaw is Map) {
      try {
        existing = _RemotePendingMetadataWrite.fromJson(
          Map<String, dynamic>.from(existingRaw),
        );
      } catch (_) {}
    }
    if (existing != null && existing.sequence > pending.sequence) return;
    final attempts =
        (existing != null &&
            existing.sequence == pending.sequence &&
            existing.subjectId == pending.subjectId)
        ? existing.attempts + 1
        : pending.attempts + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    final shouldRetry =
        attempts < _maxMetadataRetryAttempts &&
        (failure == RemoteLibraryMetadataPendingFailure.transient ||
            failure == RemoteLibraryMetadataPendingFailure.conflict ||
            failure == RemoteLibraryMetadataPendingFailure.other);
    final retryDelay = Duration(minutes: 1 << (attempts - 1).clamp(0, 3));
    final updated = pending.copyWith(
      attempts: attempts,
      lastAttemptAt: now,
      nextRetryAt: shouldRetry ? now + retryDelay.inMilliseconds : null,
      failure: failure,
      errorMessage: error.toString(),
    );
    entries[key] = updated.toJson();
    appdata.implicitData[_metadataPendingStorageKey] = entries;
    await appdata.writeImplicitData();
    metadataPendingVersion.value++;
    _scheduleMetadataRetry();
  }

  Future<void> _removePendingMetadataWrite(
    _RemotePendingMetadataWrite pending,
  ) async {
    final raw = appdata.implicitData[_metadataPendingStorageKey];
    if (raw is! Map) return;
    final key = _pendingMetadataKey(pending.libraryId, pending.comicId);
    final current = raw[key];
    if (current is Map) {
      try {
        final stored = _RemotePendingMetadataWrite.fromJson(
          Map<String, dynamic>.from(current),
        );
        if (stored.sequence > pending.sequence) return;
      } catch (_) {}
    }
    final entries = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    if (entries.remove(key) == null) return;
    appdata.implicitData[_metadataPendingStorageKey] = entries;
    await appdata.writeImplicitData();
    metadataPendingVersion.value++;
    _scheduleMetadataRetry();
  }

  RemoteLibraryMetadataPendingFailure _metadataPendingFailure(Object error) {
    if (error is RemoteLibraryAuthenticationException) {
      return RemoteLibraryMetadataPendingFailure.authentication;
    }
    if (error is RemoteLibraryTransientException) {
      return RemoteLibraryMetadataPendingFailure.transient;
    }
    if (error is RemoteLibraryUnsupportedException) {
      return RemoteLibraryMetadataPendingFailure.unsupported;
    }
    if (error is RemoteLibraryPreconditionFailedException) {
      return RemoteLibraryMetadataPendingFailure.conflict;
    }
    if (error is FormatException) {
      return RemoteLibraryMetadataPendingFailure.invalidMetadata;
    }
    return RemoteLibraryMetadataPendingFailure.other;
  }

  String _pendingMetadataKey(String libraryId, String comicId) =>
      jsonEncode([libraryId, comicId]);

  void _scheduleMetadataRetry() {
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    final libraryId = _engine._config.libraryId;
    final due = _pendingMetadataWrites()
        .where(
          (pending) =>
              pending.libraryId == libraryId &&
              pending.attempts < _maxMetadataRetryAttempts &&
              pending.nextRetryAt != null,
        )
        .map((pending) => pending.nextRetryAt!)
        .fold<int?>(null, (earliest, value) {
          return earliest == null || value < earliest ? value : earliest;
        });
    if (due == null) return;
    final delay = Duration(
      milliseconds: (due - DateTime.now().millisecondsSinceEpoch).clamp(
        0,
        const Duration(days: 1).inMilliseconds,
      ),
    );
    _metadataRetryTimer = Timer(delay, () {
      _metadataRetryTimer = null;
      unawaited(retryPendingMetadata());
    });
  }

  bool _shouldAttemptMetadataScrape({
    required _RemoteComicSnapshot? previousSnapshot,
    required bool metadataFilePresent,
    required String scraperVersion,
    required int now,
    required bool automaticScrapingEnabled,
    bool forceMetadataScrape = false,
  }) {
    if (metadataFilePresent) return false;
    if (!automaticScrapingEnabled && !forceMetadataScrape) return false;
    if (forceMetadataScrape) return true;
    if (previousSnapshot == null) return true;
    if (previousSnapshot.metadataScraperVersion != scraperVersion) return true;

    switch (previousSnapshot.metadataScrapeStatus) {
      case 'pending':
        return true;
      case 'noMatch':
      case 'matched':
      case 'notNeeded':
        return false;
      case 'failed':
        final retryAt = previousSnapshot.metadataScrapeRetryAt;
        return retryAt == null || retryAt <= now;
      default:
        return true;
    }
  }
}
