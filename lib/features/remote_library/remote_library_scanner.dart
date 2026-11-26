part of 'remote_library_engine.dart';

class _RemoteLibraryScanner {
  _RemoteLibraryScanner(this._engine);
  final RemoteLibraryEngine _engine;

  Future<Res<bool>> synchronize({
    bool force = false,
    bool automatic = false,
    bool deep = true,
  }) {
    if (_engine._state.disposed) {
      return Future.value(const Res.error('Remote comic library is closed'));
    }
    if (!_engine._config.isValid) {
      return Future.value(
        const Res.error('Invalid remote comic library configuration'),
      );
    }
    return start(force: force, automatic: automatic, deep: deep).complete;
  }

  _RemoteLibrarySyncRun start({
    bool force = false,
    bool automatic = false,
    bool deep = true,
  }) {
    final state = _engine._state;
    final config = _engine._config;
    final current = state.syncRun;
    if (!force &&
        current != null &&
        _engine._isSynchronizationCurrent(current)) {
      return current;
    }
    // 强刷建立新 generation，旧扫描和补全在提交前失效。
    if (force) state.missingCovers.clear();
    state.syncGeneration++;
    _engine._metadata.discardObsoleteTasks(state.syncGeneration);
    state.scanToken.cancel('Remote Library scan superseded');
    state.scanToken = CancelToken();
    final ready = Completer<Res<bool>>();
    late final _RemoteLibrarySyncRun run;
    final complete = Future<Res<bool>>.microtask(
      () => RemoteReadContext(
        priority: RemoteReadPriority.background,
      ).run(() => _scanRoots(config, run, ready, automatic: automatic)),
    );
    run = _RemoteLibrarySyncRun(
      configurationIdentity: _engine._configurationIdentity(config),
      generation: state.syncGeneration,
      indexReady: ready.future,
      complete: complete,
      refresh: force,
      deep: deep,
    );
    state.syncRun = run;
    unawaited(
      complete.whenComplete(() {
        if (identical(state.syncRun, run)) state.syncRun = null;
      }),
    );
    return run;
  }

  Future<Res<bool>> _scanRoots(
    RemoteLibraryConfig config,
    _RemoteLibrarySyncRun run,
    Completer<Res<bool>> ready, {
    required bool automatic,
  }) async {
    if (!_engine._isSynchronizationCurrent(run)) {
      ready.complete(const Res(true));
      return const Res(true);
    }
    final state = _engine._state;
    final scheduler = _engine._archiveAccount(config).scheduler;
    final rootPhases = {
      for (final root in config.directories)
        root: RemoteLibrarySyncPhase.listingRoots,
    };
    final newComics = <String>{};
    final reusedDirectories = <String>{};
    var processed = 0;
    var failed = 0;
    Res<bool>? failure;

    void progress({bool isSyncing = true, String? errorMessage}) {
      if (!_engine._isSynchronizationCurrent(run)) return;
      final pending = _engine._metadata.pendingCompletionCount;
      final RemoteLibrarySyncPhase phase;
      if (!isSyncing) {
        phase = pending > 0
            ? RemoteLibrarySyncPhase.completingMetadata
            : RemoteLibrarySyncPhase.idle;
      } else if (rootPhases.containsValue(
        RemoteLibrarySyncPhase.scanningPriority,
      )) {
        phase = RemoteLibrarySyncPhase.scanningPriority;
      } else if (rootPhases.isEmpty ||
          rootPhases.containsValue(RemoteLibrarySyncPhase.scanningCatalog)) {
        phase = RemoteLibrarySyncPhase.scanningCatalog;
      } else {
        phase = RemoteLibrarySyncPhase.listingRoots;
      }
      _engine.syncStatus.value = RemoteLibrarySyncStatus(
        isSyncing: isSyncing,
        lastSuccessfulSync: state.lastSuccessfulSync,
        processed: processed,
        total: processed,
        failed: failed,
        errorMessage: errorMessage,
        phase: phase,
        reused: reusedDirectories.length,
        discoveredNew: newComics.length,
        pendingMetadata: pending,
        cooldownUntil: scheduler.cooldownUntil,
      );
    }

    void reuseDirectory(String path) {
      if (reusedDirectories.add(normalizeRemoteDirectory(path))) progress();
    }

    try {
      _engine._metadata.pauseDuringDiscovery(run);
      progress();
      final previousLastSync = await _engine._cache.lastSuccessfulSync(
        config.cacheKey,
      );
      final previous = await _engine._cache.versions(config.cacheKey);
      _engine._throwIfSynchronizationObsolete(run);
      state.lastSuccessfulSync = previousLastSync;
      state.failedRoots = await _engine._cache.rootFailures(config.cacheKey);
      _engine._throwIfSynchronizationObsolete(run);
      progress();
      final previousRootEntries = await _engine._readCachedDirectories(
        config,
        config.directories.map(normalizeRemoteDirectory),
      );
      _engine._throwIfSynchronizationObsolete(run);

      // 各根先独立推进，慢根不会挡住其他根的首批发现。
      await Future.wait(
        config.directories.map((root) async {
          final rootConfig = _engine._configFor(root);
          final batch = _RemoteLibrarySummaryBatch(
            _engine,
            rootConfig,
            run,
            () {
              if (!ready.isCompleted) ready.complete(const Res(true));
            },
          );
          try {
            final entries = await _engine._readDirectory(
              rootConfig,
              root,
              refresh: run.refresh,
              useCache: automatic && !run.refresh,
              previousRootEntries: previousRootEntries,
              onCacheHit: () => reuseDirectory(root),
            );
            _engine._throwIfSynchronizationObsolete(run);
            final oldEntries =
                previousRootEntries[normalizeRemoteDirectory(root)];
            final previousRootDirs = {
              for (final entry in oldEntries ?? const <RemoteLibraryEntry>[])
                if (entry.isDirectory) entry.name: entry,
            };
            final previouslyIndexed = oldEntries == null
                ? _previousRootDirectoryNames(rootConfig, previous.keys)
                : const <String>{};
            final priority = <RemoteLibraryEntry>[];
            final ordinary = <RemoteLibraryEntry>[];
            final reusable = <String>{};
            for (final directory in _sortedDirectories(entries)) {
              final old = previousRootDirs[directory.name];
              final sameVersion = old?._hasSameVersion(directory) == true;
              if (sameVersion || previouslyIndexed.contains(directory.name)) {
                ordinary.add(directory);
              } else {
                priority.add(directory);
              }
              if (run.refresh &&
                  !run.deep &&
                  sameVersion &&
                  directory._hasVersion) {
                reusable.add(directory.name);
              }
            }
            run.reusableRootChildren[rootConfig.remotePath] = reusable;
            var sequence = 0;
            final discovered = await _discoverComicDirectories(
              rootConfig,
              rootEntries: entries,
              syncRun: run,
              priorityDirectories: priority,
              ordinaryDirectories: ordinary,
              useCache: automatic,
              onDirectoryReused: reuseDirectory,
              onPhaseChanged: (phase) {
                if (rootPhases[root] == phase) return;
                rootPhases[root] = phase;
                progress();
              },
              onPriorityDiscovered: () async {
                await batch.flush();
                _engine._throwIfSynchronizationObsolete(run);
                _engine._notifyContent(immediate: true);
              },
              onDiscovered: (comic) async {
                _engine._throwIfSynchronizationObsolete(run);
                final id = _engine._stableComicPath(rootConfig, comic.id);
                final cached = previous[id];
                final directory = RemoteLibraryRemoteDirectory(
                  id: id,
                  sortIndex: cached?.sortIndex ?? sequence++,
                  eTag: comic.eTag,
                  modifiedAt: comic.modifiedAt,
                  sourceModifiedAt: comic.sourceModifiedAt,
                );
                final shouldRefresh =
                    cached == null ||
                    !cached.isReady ||
                    !cached.hasSameRemoteVersion(
                      eTag: comic.eTag,
                      modifiedAt: comic.modifiedAt,
                    ) ||
                    (RemoteLibrarySource._canScrapeMetadata &&
                        cached.shouldRetryMetadataScrape(
                          scraperVersion:
                              RemoteLibrarySource._metadataScraperVersion,
                          now: RemoteLibrarySource.metadataNowProvider(),
                        ));
                await batch.add(
                  comic,
                  directory,
                  completeMetadata: shouldRefresh,
                );
                if (!shouldRefresh) {
                  _engine._notifyMetadataSubject(
                    rootConfig,
                    id,
                    cached.snapshot?['bangumiSubjectId'] as int?,
                  );
                }
                if (cached == null) newComics.add(id);
                processed++;
                progress();
              },
            );
            await batch.flush();
            _engine._throwIfSynchronizationObsolete(run);
            final index = [
              for (var i = 0; i < discovered.length; i++)
                RemoteLibraryRemoteDirectory(
                  id: _engine._stableComicPath(rootConfig, discovered[i].id),
                  sortIndex: i,
                  eTag: discovered[i].eTag,
                  modifiedAt: discovered[i].modifiedAt,
                  sourceModifiedAt: discovered[i].sourceModifiedAt,
                ),
            ];
            // 在排队最终索引前固定排序，随后提交的后台快照使用同一顺序。
            for (final directory in index) {
              state.sortIndexes[directory.id] = directory.sortIndex;
            }
            if (config.remoteLibrary == null) {
              await _engine._cache.replaceDirectoryIndex(
                config.cacheKey,
                index,
              );
            } else {
              await _engine._cache.replaceRootDirectoryIndex(
                config.cacheKey,
                RemoteLibraryRootIndex(rootPath: root, directories: index),
              );
            }
            _engine._throwIfSynchronizationObsolete(run);
            state.failedRoots.remove(root);
            _engine._notifyContent(immediate: true);
            if (!ready.isCompleted) ready.complete(const Res(true));
          } on _RemoteSynchronizationObsoleteException {
            rethrow;
          } catch (error, stackTrace) {
            _engine._throwIfSynchronizationObsolete(run);
            await batch.flush();
            failed++;
            failure ??= Res.error(error.toString());
            state.failedRoots[root] = error.toString();
            if (config.remoteLibrary != null) {
              await _engine._cache.markRootFailure(
                config.cacheKey,
                root,
                error.toString(),
              );
            }
            Log.error('Remote Library scan', error, stackTrace);
          } finally {
            rootPhases.remove(root);
            progress();
            batch.cancel();
            await _engine._flushDirectoryCache();
          }
        }),
      );
      _engine._throwIfSynchronizationObsolete(run);
      await _engine._flushDirectoryCache();
      _engine._throwIfSynchronizationObsolete(run);
      if (failure == null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await _engine._cache.setLastSuccessfulSync(config.cacheKey, now);
        _engine._throwIfSynchronizationObsolete(run);
        state.lastSuccessfulSync = now;
      }
      final result = failure ?? const Res<bool>(true);
      if (!ready.isCompleted) ready.complete(result);
      progress(isSyncing: false, errorMessage: failure?.errorMessage);
      _engine._notifyContent(immediate: true);
      return result;
    } on _RemoteSynchronizationObsoleteException {
      if (!ready.isCompleted) ready.complete(const Res(true));
      return const Res(true);
    } catch (error, stackTrace) {
      final result = Res<bool>.error(error.toString());
      if (!ready.isCompleted) ready.complete(result);
      if (_engine._isSynchronizationCurrent(run)) {
        Log.error('Remote Library scan', error, stackTrace);
        progress(isSyncing: false, errorMessage: error.toString());
      }
      return result;
    } finally {
      _engine._metadata.resumeAfterDiscovery(run);
    }
  }

  Set<String> _previousRootDirectoryNames(
    RemoteLibraryConfig config,
    Iterable<String> ids,
  ) {
    final names = <String>{};
    final root = config.remotePath;
    for (final id in ids) {
      final path = id.startsWith(remoteComicWorkPrefix)
          ? RemoteComicWork.location(id).directory
          : config.childDirectoryPath(id);
      if (!path.startsWith(root)) continue;
      final end = path.indexOf('/', root.length);
      if (end != -1) names.add(path.substring(root.length, end));
    }
    return names;
  }

  bool _looksLikeChapterName(String name) {
    final normalized = name.trim().toLowerCase();
    return RegExp(
      r'^(?:'
      r'\d+(?:[._-]\d+)?|'
      r'第?\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:话|話|章|卷|册|冊|回|集)(?:[\s._:—–~\[-].*)?|'
      r'\d+\s+第?\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:话|話|章|卷|册|冊|回|集)?(?:[\s._:—–~\[-].*)?|'
      r'卷\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)(?:[\s._:—–~\[-].*)?|'
      r'全\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:卷|册|冊|部|篇)(?:[\s._:—–~\[-].*)?|'
      r'(?:上|中|下|全)\s*(?:卷|册|冊|部|篇)(?:[\s._:—–~\[-].*)?|'
      r'(?:单行本|單行本)\s*\d+(?:[\s._:—–~\[-].*)?|'
      r'(?:ch(?:apter)?|ep(?:isode)?|vol(?:ume)?)\.?\s*\d+(?:[._-]\d+)?(?:[\s._:—–~\[-].*)?|'
      r'序章|终章|終章|番外(?:合集)?|外传|外傳|后日谈|後日談|后记|後記|短篇(?:集)?|特别篇(?:合集)?|附录|附錄|'
      r'prologue|epilogue|extra|extras|bonus|special|omake|side\s*story'
      r')$',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  Future<List<_RemoteDiscoveredDirectory>> _discoverComicDirectories(
    RemoteLibraryConfig config, {
    required List<RemoteLibraryEntry> rootEntries,
    required _RemoteLibrarySyncRun syncRun,
    required List<RemoteLibraryEntry> priorityDirectories,
    required List<RemoteLibraryEntry> ordinaryDirectories,
    required bool useCache,
    required void Function(String path) onDirectoryReused,
    required void Function(RemoteLibrarySyncPhase phase) onPhaseChanged,
    required Future<void> Function() onPriorityDiscovered,
    required Future<void> Function(_RemoteDiscoveredDirectory) onDiscovered,
  }) async {
    final result = <_RemoteDiscoveredDirectory>[];
    final concurrency = _engine
        ._archiveAccount(config)
        .scheduler
        .maxConcurrent
        .clamp(1, 8);
    final seenArchives = <String>{};
    var inspectedDirectories = 0;
    final maxDirectories =
        RemoteLibrarySource.discoveryDirectoryLimitOverride ??
        _maxDiscoveryDirectories;
    final publishedWorks = <String, _RemoteDiscoveredDirectory>{};
    final directoryReads = <String, FutureOr<List<RemoteLibraryEntry>>>{};
    Future<Map<String, List<RemoteLibraryEntry>>>? cachedRootChildren;

    Future<List<RemoteLibraryEntry>> fetchDirectory(
      String path,
      int depth,
    ) async {
      final reuseCache = syncRun.canReuseDirectory(config, path);
      List<RemoteLibraryEntry>? prefetched;
      if (reuseCache && depth == 0) {
        final paths = syncRun.reusableRootChildren[config.remotePath]!.map(
          config._discoveryDirectoryPath,
        );
        prefetched = (await (cachedRootChildren ??= _engine
            ._readCachedDirectories(config, paths)))[path];
        _engine._throwIfSynchronizationObsolete(syncRun);
        if (prefetched != null) onDirectoryReused(path);
      }
      final entries = List<RemoteLibraryEntry>.from(
        prefetched ??
            await _engine._readDirectory(
              config,
              path,
              refresh: syncRun.refresh,
              useCache: useCache && !syncRun.refresh,
              useStaleCache: reuseCache && depth > 0,
              onCacheHit: () => onDirectoryReused(path),
            ),
      );
      _engine._throwIfSynchronizationObsolete(syncRun);
      directoryReads[path] = entries;
      return entries;
    }

    Future<List<RemoteLibraryEntry>> readDirectory(String id, int depth) async {
      _engine._throwIfSynchronizationObsolete(syncRun);
      final path = config._discoveryDirectoryPath(id);
      final reading = directoryReads[path];
      if (reading != null) return reading;
      if (depth > _maxDiscoveryDepth ||
          inspectedDirectories >= maxDirectories) {
        throw FormatException('Remote Library discovery limit reached at $id');
      }
      inspectedDirectories++;
      return directoryReads[path] = fetchDirectory(path, depth);
    }

    Future<_RemoteDiscoveredDirectory> publishWork(
      RemoteComicWork work,
      List<RemoteLibraryEntry> entries,
    ) async {
      final published = publishedWorks[work.id];
      if (published != null) return published;
      for (final volume in work.volumes) {
        seenArchives.add(volume.id);
      }
      final comic = _RemoteDiscoveredDirectory(
        id: work.id,
        entries: entries,
        work: work,
        sourceModifiedAt: _latestModifiedAt(
          work.volumes.map((volume) => volume.archive.modifiedAt),
        ),
        eTag: _contentVersion([
          for (final volume in work.volumes)
            RemoteLibraryEntry(
              name: volume.id,
              isDirectory: false,
              size: volume.archive.size,
              eTag: volume.archive.eTag,
              modifiedAt: volume.archive.modifiedAt,
            ),
          ...entries.where(
            (entry) =>
                !entry.isDirectory &&
                (entry.name.toLowerCase() ==
                        work.metadataFileName.toLowerCase() ||
                    isNamedComicCover(entry.name)),
          ),
        ]).eTag,
      );
      await onDiscovered(comic);
      publishedWorks[work.id] = comic;
      return comic;
    }

    bool homogeneous(List<RemoteLibraryEntry> files) {
      if (files.isEmpty) return false;
      final names = files
          .map((file) => RemoteComicVolumeName.parse(file.name))
          .toList();
      return names.every((name) => name.numbered) &&
          names
                  .map((name) => remoteComicSeriesKey(name.series))
                  .where((name) => name.isNotEmpty)
                  .toSet()
                  .length <=
              1;
    }

    Future<_RemoteDiscoveredDirectory?> directoryWork(
      String id,
      List<RemoteLibraryEntry> entries,
      int depth,
    ) async {
      if (_imageEntries(
        entries,
      ).any((entry) => !isNamedComicCover(entry.name))) {
        return null;
      }
      final marked = _hasMetadataFile(entries);
      final children = _sortedDirectories(entries);
      if (children.isEmpty ||
          !marked &&
              !children.every(
                (child) => isRemoteComicEditionDirectory(child.name),
              )) {
        return null;
      }
      final direct = _engine._archiveFiles(entries);
      if (direct.isNotEmpty && !marked && !homogeneous(direct)) return null;
      final path = config._discoveryDirectoryPath(id);
      final volumes = [
        for (final file in direct)
          _engine._archiveVolume(
            config,
            file,
            path,
            edition: _directoryName(path),
          ),
      ];
      final childVolumes = <String, List<RemoteComicVolume>>{};
      final orderedChildren = id.isEmpty
          ? [...priorityDirectories, ...ordinaryDirectories]
          : children;

      Future<bool> probeChild(RemoteLibraryEntry child) async {
        final childId = _joinRelativeDirectoryPath(id, child.name);
        final childEntries = await readDirectory(childId, depth + 1);
        final files = _engine._archiveFiles(childEntries);
        if (_sortedDirectories(childEntries).isNotEmpty ||
            _imageEntries(
              childEntries,
            ).any((entry) => !isNamedComicCover(entry.name)) ||
            !marked && files.isNotEmpty && !homogeneous(files)) {
          return false;
        }
        if (files.isEmpty) return true;
        final childPath = config._discoveryDirectoryPath(childId);
        childVolumes[child.name] = [
          for (final file in files)
            _engine._archiveVolume(
              config,
              file,
              childPath,
              edition: child.name,
            ),
        ];
        return true;
      }

      // 遇到空目录时继续顺序探测，读到压缩包后才并发检查余下目录。
      var nextChild = 0;
      while (nextChild < orderedChildren.length && childVolumes.isEmpty) {
        if (!await probeChild(orderedChildren[nextChild])) return null;
        nextChild++;
      }
      var rejected = false;
      await runThrottledTasks(
        orderedChildren.skip(nextChild).toList(growable: false),
        concurrency: concurrency,
        throttleEvery: 0,
        run: (child) async {
          if (rejected) return;
          if (!await probeChild(child)) rejected = true;
        },
      );
      if (rejected) return null;

      volumes.addAll([
        for (final child in children) ...?childVolumes[child.name],
      ]);
      if (volumes.length < 2) return null;
      final work = RemoteComicWork(
        directory: path,
        title: _directoryName(path),
        volumes: separateRemoteComicEditions(volumes),
      );
      return publishWork(work, entries);
    }

    Future<List<_RemoteDiscoveredDirectory>> archives(
      List<RemoteLibraryEntry> entries,
      String parent,
    ) async {
      final files = _engine._archiveFiles(entries);
      final path = config._discoveryDirectoryPath(parent);
      if (files.length >= 2 &&
          _hasMetadataFile(entries) &&
          _sortedDirectories(entries).isEmpty &&
          !_imageEntries(
            entries,
          ).any((entry) => !isNamedComicCover(entry.name))) {
        final work = RemoteComicWork(
          directory: path,
          title: _directoryName(path),
          volumes: separateRemoteComicEditions([
            for (final file in files)
              _engine._archiveVolume(config, file, path),
          ]),
        );
        return [await publishWork(work, entries)];
      }
      final comics = <_RemoteDiscoveredDirectory>[];
      final families = <String, List<RemoteLibraryEntry>>{};
      final titles = <String, String>{};
      for (final file in files) {
        final name = RemoteComicVolumeName.parse(file.name);
        if (!name.numbered) continue;
        final family = remoteComicSeriesKey(name.series);
        (families[family] ??= []).add(file);
        titles.putIfAbsent(family, () => name.series);
      }
      final consumed = <String>{};
      for (final family in families.entries) {
        if (family.value.length < 2) continue;
        final ownDirectory =
            !config.directories.contains(path) &&
            family.value.length == files.length &&
            _sortedDirectories(entries).isEmpty &&
            !_imageEntries(
              entries,
            ).any((entry) => !isNamedComicCover(entry.name));
        final title = ownDirectory || titles[family.key]!.isEmpty
            ? _directoryName(path)
            : titles[family.key]!;
        final work = RemoteComicWork(
          directory: path,
          title: title,
          family: ownDirectory ? null : title,
          volumes: separateRemoteComicEditions([
            for (final file in family.value)
              _engine._archiveVolume(config, file, path),
          ]),
        );
        comics.add(await publishWork(work, entries));
        consumed.addAll(family.value.map((file) => file.name));
      }
      for (final file in files) {
        if (consumed.contains(file.name)) continue;
        _engine._throwIfSynchronizationObsolete(syncRun);
        final archiveId = _joinRelativeDirectoryPath(parent, file.name);
        if (!seenArchives.add(config.childFilePath(path, file.name))) {
          continue;
        }
        final comic = _RemoteDiscoveredDirectory(
          id: archiveId,
          entries: entries,
          eTag: _contentVersion([
            file,
            ...entries.where(
              (entry) =>
                  !entry.isDirectory &&
                  entry.name.toLowerCase() ==
                      '${file.name}.metadata.json'.toLowerCase(),
            ),
          ]).eTag,
          archiveFile: file,
          sourceModifiedAt: file.modifiedAt,
        );
        await onDiscovered(comic);
        comics.add(comic);
      }
      return comics;
    }

    onPhaseChanged(
      priorityDirectories.isEmpty
          ? RemoteLibrarySyncPhase.scanningCatalog
          : RemoteLibrarySyncPhase.scanningPriority,
    );
    final rootWork = await directoryWork('', rootEntries, -1);
    if (rootWork != null) return [rootWork];
    result.addAll(await archives(rootEntries, ''));

    Future<List<_RemoteDiscoveredDirectory>> scan({
      required RemoteLibraryEntry directory,
      required String id,
      required List<RemoteLibraryEntry> entries,
      required int depth,
      required bool preserveFallback,
      List<_RemoteDiscoveredDirectory>? knownArchives,
    }) async {
      _engine._throwIfSynchronizationObsolete(syncRun);
      final work = await directoryWork(id, entries, depth);
      if (work != null) return [...?knownArchives, work];
      final archiveComics = knownArchives ?? await archives(entries, id);
      final chapterArchives = <_RemoteDiscoveredDirectory>[];
      final version = _directoryContentVersion(directory, entries);
      Future<List<_RemoteDiscoveredDirectory>> current({
        Map<String, List<RemoteLibraryEntry>> childEntries = const {},
      }) async {
        final listedChildren = entries
            .where((entry) => entry.isDirectory && !_isIgnoredEntry(entry.name))
            .expand((child) {
              final path = config._discoveryDirectoryPath(
                _joinRelativeDirectoryPath(id, child.name),
              );
              final listing = directoryReads[path];
              return listing is List<RemoteLibraryEntry>
                  ? listing
                  : const <RemoteLibraryEntry>[];
            });
        final comic = _RemoteDiscoveredDirectory(
          id: id,
          entries: entries,
          childEntries: childEntries,
          eTag: version.eTag,
          modifiedAt: version.modifiedAt,
          sourceModifiedAt: _latestModifiedAt([
            directory.modifiedAt,
            for (final entry in entries.followedBy(listedChildren))
              if (!_isIgnoredEntry(entry.name)) entry.modifiedAt,
          ]),
        );
        await onDiscovered(comic);
        return [comic, ...archiveComics, ...chapterArchives];
      }

      if (_hasMetadataFile(entries) ||
          _imageEntries(
            entries,
          ).any((entry) => !isNamedComicCover(entry.name))) {
        return current();
      }
      final childDirectories = _sortedDirectories(entries);
      if (childDirectories.isEmpty) {
        return archiveComics.isNotEmpty
            ? archiveComics
            : preserveFallback
            ? current()
            : const [];
      }

      if (depth >= _maxDiscoveryDepth) {
        Log.warning(
          'Remote Library',
          'Discovery depth limit reached while inspecting $id',
        );
        throw FormatException(
          'Remote Library discovery depth limit reached at $id',
        );
      }

      if (inspectedDirectories >= maxDirectories) {
        Log.warning(
          'Remote Library',
          'Discovery inspection limit reached while inspecting $id',
        );
        throw FormatException(
          'Remote Library discovery directory limit reached at $id',
        );
      }
      final pendingChildren =
          <
            String,
            ({
              RemoteLibraryEntry directory,
              String id,
              List<RemoteLibraryEntry> entries,
              Future<List<_RemoteDiscoveredDirectory>> archiveComics,
            })
          >{};
      final nestedByChild = <String, List<_RemoteDiscoveredDirectory>>{};
      var isCategory = false;

      await runThrottledTasks(
        childDirectories,
        concurrency: concurrency,
        throttleEvery: 0,
        run: (child) async {
          final childId = _joinRelativeDirectoryPath(id, child.name);
          final childEntries = await readDirectory(childId, depth + 1);
          _engine._throwIfSynchronizationObsolete(syncRun);
          final pages = _imageEntries(
            childEntries,
          ).where((entry) => !isNamedComicCover(entry.name));
          isCategory =
              isCategory ||
              _hasMetadataFile(childEntries) ||
              (pages.isEmpty &&
                  childEntries.any(
                    (entry) =>
                        !entry.isDirectory && isRemoteComicArchive(entry.name),
                  )) ||
              _sortedDirectories(childEntries).isNotEmpty ||
              (!_looksLikeChapterName(child.name) && pages.isNotEmpty);
          final probed = (
            directory: child,
            id: childId,
            entries: childEntries,
            archiveComics: archives(childEntries, childId),
          );
          if (!isCategory) {
            pendingChildren[child.name] = probed;
            await probed.archiveComics;
            return;
          }

          // 确认为分类时立即接管已读完的子目录，不等其他读取结束。
          final ready = [...pendingChildren.values, probed];
          pendingChildren.clear();
          await Future.wait(
            ready.map((pending) async {
              nestedByChild[pending.directory.name] = await scan(
                directory: pending.directory,
                id: pending.id,
                entries: pending.entries,
                depth: depth + 1,
                preserveFallback: false,
                knownArchives: await pending.archiveComics,
              );
            }),
          );
        },
      );

      if (!isCategory) {
        final children = [
          for (final child in childDirectories) pendingChildren[child.name]!,
        ];
        final childEntriesMap = {
          for (final child in children) child.directory.name: child.entries,
        };
        for (final child in children) {
          chapterArchives.addAll(await child.archiveComics);
        }
        final childrenWithImages = children.where(
          (child) => _imageEntries(
            child.entries,
          ).any((entry) => !isNamedComicCover(entry.name)),
        );

        if (childrenWithImages.isNotEmpty) {
          final allImagesLookLikeChapters = childrenWithImages.every(
            (child) => _looksLikeChapterName(child.directory.name),
          );
          if (allImagesLookLikeChapters) {
            Log.info(
              'Remote Library',
              'Treating "$id" as comic root because all image child directories match chapter naming',
            );
            return current(childEntries: childEntriesMap);
          }
        } else if (childDirectories.every(
          (child) => _looksLikeChapterName(child.name),
        )) {
          Log.info(
            'Remote Library',
            'Treating "$id" as comic root because all child directory names match chapter naming',
          );
          return current(childEntries: childEntriesMap);
        }
      }

      final nested = [
        ...archiveComics,
        ...chapterArchives,
        for (final child in childDirectories) ...?nestedByChild[child.name],
      ];
      if (nested.isNotEmpty) return nested;
      return preserveFallback ? current() : const [];
    }

    Future<void> scanRootDirectories(List<RemoteLibraryEntry> directories) =>
        runThrottledTasks(
          directories,
          concurrency: concurrency,
          throttleEvery: 0,
          run: (directory) async {
            final id = directory.name;
            final entries = await readDirectory(id, 0);
            _engine._throwIfSynchronizationObsolete(syncRun);
            result.addAll(
              await scan(
                directory: directory,
                id: id,
                entries: entries,
                depth: 0,
                preserveFallback: true,
              ),
            );
            _engine._throwIfSynchronizationObsolete(syncRun);
          },
        );

    final initialCount = result.length;
    await scanRootDirectories(priorityDirectories);
    if (result.length > initialCount) await onPriorityDiscovered();
    if (ordinaryDirectories.isNotEmpty) {
      onPhaseChanged(RemoteLibrarySyncPhase.scanningCatalog);
      await scanRootDirectories(ordinaryDirectories);
    }

    final unique = {
      for (final comic in result) comic.id: comic,
    }.values.toList();
    unique.sort((a, b) {
      final comparison = compareComicFileNames(
        a.work?.title ?? a.id,
        b.work?.title ?? b.id,
      );
      return comparison != 0 ? comparison : a.id.compareTo(b.id);
    });
    return unique;
  }

  int? _latestModifiedAt(Iterable<int?> timestamps) {
    int? latest;
    for (final timestamp in timestamps) {
      if (timestamp != null && (latest == null || timestamp > latest)) {
        latest = timestamp;
      }
    }
    return latest;
  }

  ({String? eTag, int? modifiedAt}) _directoryContentVersion(
    RemoteLibraryEntry directory,
    List<RemoteLibraryEntry> entries,
  ) {
    final trackedEntries = entries
        .where((entry) => !_isIgnoredEntry(entry.name))
        .toList();
    return _contentVersion(trackedEntries, parent: directory);
  }

  ({String? eTag, int? modifiedAt}) _contentVersion(
    List<RemoteLibraryEntry> trackedEntries, {
    RemoteLibraryEntry? parent,
  }) {
    final hasReliableValidators =
        trackedEntries.isNotEmpty &&
        trackedEntries.every(
          (entry) => entry.eTag?.isNotEmpty == true || entry.modifiedAt != null,
        );
    if (!hasReliableValidators) return (eTag: null, modifiedAt: null);
    final sorted = List<RemoteLibraryEntry>.from(trackedEntries)
      ..sort((a, b) => compareComicFileNames(a.name, b.name));
    final identity = jsonEncode([
      parent?.eTag,
      parent?.modifiedAt,
      for (final entry in sorted)
        [
          entry.name,
          entry.isDirectory,
          entry.size,
          entry.eTag,
          entry.modifiedAt,
        ],
    ]);
    return (
      eTag: 'venera:${sha256.convert(utf8.encode(identity))}',
      modifiedAt: null,
    );
  }
}

class _RemoteDiscoveredDirectory {
  const _RemoteDiscoveredDirectory({
    required this.id,
    required this.entries,
    this.childEntries = const {},
    this.eTag,
    this.modifiedAt,
    this.sourceModifiedAt,
    this.archiveFile,
    this.work,
  });

  final String id;
  final List<RemoteLibraryEntry> entries;
  final Map<String, List<RemoteLibraryEntry>> childEntries;
  final String? eTag;
  final int? modifiedAt;
  final int? sourceModifiedAt;
  final RemoteLibraryEntry? archiveFile;
  final RemoteComicWork? work;
}

/// 首项立即提交，后续摘要和根成员在一个事务中合并。
class _RemoteLibrarySummaryBatch {
  _RemoteLibrarySummaryBatch(
    this._engine,
    this._config,
    this._run,
    this._onReady,
  );

  final RemoteLibraryEngine _engine;
  final RemoteLibraryConfig _config;
  final _RemoteLibrarySyncRun _run;
  final void Function() _onReady;
  final _pending =
      <
        ({
          _RemoteDiscoveredDirectory comic,
          RemoteLibraryRemoteDirectory directory,
          bool completeMetadata,
        })
      >[];
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  bool _first = true;
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> add(
    _RemoteDiscoveredDirectory comic,
    RemoteLibraryRemoteDirectory directory, {
    required bool completeMetadata,
  }) async {
    _pending.add((
      comic: comic,
      directory: directory,
      completeMetadata: completeMetadata,
    ));
    if (_first || _pending.length >= 64) {
      _first = false;
      await flush();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 200), () {
        _timer = null;
        unawaited(
          flush().catchError((Object error, StackTrace stackTrace) {
            _error = error;
            _stackTrace = stackTrace;
          }),
        );
      });
    }
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_error != null) Error.throwWithStackTrace(_error!, _stackTrace!);
    final rows = List.of(_pending);
    _pending.clear();
    final previous = _tail;
    final write = () async {
      await previous;
      if (rows.isEmpty) return;
      _engine._throwIfSynchronizationObsolete(_run);
      await _engine._cache.upsertSummaries(
        _config.cacheKey,
        [
          for (final row in rows)
            RemoteLibraryCachedComic(
              id: row.directory.id,
              sortIndex: row.directory.sortIndex,
              title:
                  row.comic.work?.title ??
                  (row.comic.archiveFile == null
                      ? _directoryName(row.directory.id)
                      : comicFileStem(row.comic.archiveFile!.name)),
              author: '',
              tags: const [],
              cover: _previewCover(row.comic, row.directory.id),
              snapshot: null,
              remoteETag: row.directory.eTag,
              remoteModifiedAt: row.directory.modifiedAt,
              sourceModifiedAt: row.directory.sourceModifiedAt,
            ),
        ],
        rootPath: _config.remoteLibrary == null ? null : _config.remotePath,
      );
      _engine._throwIfSynchronizationObsolete(_run);
      _onReady();
      _engine._notifyContent(immediate: !_run.hasPublished);
      _run.hasPublished = true;
      for (final row in rows) {
        if (row.completeMetadata) {
          _engine._metadata.enqueueCompletion(
            _config,
            row.comic,
            row.directory,
            _run,
          );
        }
      }
    }();
    _tail = write;
    await write;
  }

  String _previewCover(_RemoteDiscoveredDirectory comic, String id) {
    final named = _findNamedCover(comic.entries);
    if (named != null) {
      final directory =
          comic.work?.directory ??
          (comic.archiveFile != null
              ? _engine._metadataTarget(_config, id).directory
              : _config.childDirectoryPath(id));
      return _config.childFilePath(directory, named.name);
    }
    if (comic.archiveFile != null || comic.work != null) return '';
    final images = _imageEntries(
      comic.entries,
    ).where((entry) => !isNamedComicCover(entry.name));
    if (images.isNotEmpty) {
      return _config.childFilePath(
        _config.childDirectoryPath(id),
        images.first.name,
      );
    }
    for (final child in comic.childEntries.entries) {
      final pages = _imageEntries(
        child.value,
      ).where((entry) => !isNamedComicCover(entry.name));
      if (pages.isNotEmpty) {
        return _config.childFilePath(
          _config.childDirectoryPathFrom(
            _config.childDirectoryPath(id),
            child.key,
          ),
          pages.first.name,
        );
      }
    }
    return '';
  }

  void cancel() {
    _timer?.cancel();
    _pending.clear();
  }
}
