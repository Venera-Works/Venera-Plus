import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/features/reader/auto_reading.dart';

import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/network/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/chapter_completion.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reading_session.dart';
import 'package:venera_plus/features/reader/remote_progress.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/reader/volume.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:window_manager/window_manager.dart';

extension ReaderContext on BuildContext {
  ReaderState get reader => findAncestorStateOfType<ReaderState>()!;

  ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<ReaderScaffoldState>()!;
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    this.initialNavigationSource = ReadingNavigationSource.restore,
    required this.author,
    required this.tags,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  /// Origin of the position selected when this Reader is opened.
  final ReadingNavigationSource initialNavigationSource;

  final History history;

  @override
  State<Reader> createState() => ReaderState();
}

List<ReadingChapter>? _buildReadingChapters(ComicChapters? chapters) {
  if (chapters == null) return null;
  final entries = <ReadingChapter>[];
  if (chapters.isGrouped) {
    var group = 0;
    for (final groupId in chapters.groups) {
      group++;
      var ep = 0;
      for (final id in chapters.getGroup(groupId).keys) {
        ep++;
        entries.add(
          ReadingChapter(id: id, ep: ep, group: group, groupId: groupId),
        );
      }
    }
  } else {
    var ep = 0;
    for (final id in chapters.ids) {
      ep++;
      entries.add(ReadingChapter(id: id, ep: ep));
    }
  }
  return entries;
}

int? _resolveReadingChapterIndex(
  List<ReadingChapter> chapters,
  ComicChapters source,
  ReadingPosition position,
) {
  int? match;
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    final matches = position.chapterId != null
        ? chapter.id == position.chapterId &&
              (position.groupId == null || chapter.groupId == position.groupId)
        : position.groupId != null
        ? chapter.groupId == position.groupId && chapter.ep == position.ep
        : position.group != null
        ? chapter.group == position.group && chapter.ep == position.ep
        : !source.isGrouped && chapter.ep == position.ep;
    if (matches) {
      if (match != null) return null;
      match = i + 1;
    }
  }
  return match;
}

class _PendingReaderNavigation {
  const _PendingReaderNavigation({
    required this.source,
    required this.commandId,
    required this.observedProgress,
    this.chapter,
    this.page,
  });

  final ReadingNavigationSource source;
  final String commandId;
  final ReadingProgress? observedProgress;
  final int? chapter;
  final int? page;

  bool matches(int currentChapter, int currentPage) =>
      (chapter == null || chapter == currentChapter) &&
      (page == null || page == currentPage);

  _PendingReaderNavigation withPage(int value) => _PendingReaderNavigation(
    source: source,
    commandId: commandId,
    observedProgress: observedProgress,
    chapter: chapter,
    page: value,
  );
}

class ReaderState extends State<Reader>
    with
        ReaderLocation,
        ReaderWindow,
        ReaderVolumeListener,
        ReaderImagePerPageHandler,
        WidgetsBindingObserver {
  late final AutoReadingController autoReadingController;
  AutoReadingController get autoReading => autoReadingController;

  dynamic readerSetting(String key) =>
      appdata.settings.getReaderSetting(cid, type.sourceKey, key);
  @override
  void update() {
    setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPage).ceil()
        : 1 + ((images!.length - 1) / imagesPerPage).ceil();
  }

  /// Total pages including chapter comments page (used for internal page control).
  @override
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  @override
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && pageValue > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';
  ReadingChapter? get readingChapter =>
      _readingChapters.elementAtOrNull(chapter - 1);

  @override
  List<String>? images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;
  bool localPageOrderChecked = false;
  late final List<ReadingChapter> _readingChapters;
  late final ReadingCatalog? _readingCatalog;
  late String? sessionRoundId;
  late final String _initialNavigationCommandId;
  bool _initialNavigationSubmitted = false;
  ReadingProgress? _initialObservedProgress;
  bool _showProgressConflict = false;

  bool _reportedMissingLocalFiles = false;

  void onLocalChapterRecoveredOnline() {
    if (!mounted || _reportedMissingLocalFiles) return;
    _reportedMissingLocalFiles = true;
    showToast(
      context: context,
      message:
          'Local chapter files are unavailable. Reading online instead.'.tl,
    );
  }

  late final ReadingSessionTracker _readingSession;
  final _chapterCompletionNotifier = ReaderChapterCompletionNotifier();
  bool _readerContentReady = false;
  RemoteProgressTracker? _remoteProgressTracker;

  @override
  bool isLoading = false;
  @override
  bool get canAcceptReaderPageChanges => _readerContentReady;

  var focusNode = FocusNode();

  @override
  void initState() {
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
    autoReadingController = AutoReadingController(
      settings: () => AutoReadingSettings(
        gallery: mode.isGallery,
        pageInterval:
            (readerSetting('autoPageTurningInterval') as num?)?.toDouble() ??
            5.0,
        pixelsPerSecond:
            (readerSetting('autoScrollSpeed') as num?)?.toDouble() ?? 80.0,
        stepped: readerSetting('autoScrollStyle') == 'stepped',
        stepsPerSecond:
            (readerSetting('autoScrollFrequency') as num?)?.toDouble() ?? 2.0,
        pixelsPerStep:
            (readerSetting('autoScrollDistance') as num?)?.toDouble() ?? 40.0,
      ),
      canAdvance: () {
        final controller = imageViewController;
        if (controller is! AutoReadingViewport) return false;
        final viewport = controller as AutoReadingViewport;
        return mounted &&
            _readerContentReady &&
            !isLoading &&
            !isPageAnimating &&
            (ModalRoute.of(context)?.isCurrent ?? true) &&
            viewport.autoReadingReady;
      },
      advance: (distance) {
        final across = readerSetting('autoReadingAcrossChapters') == true;
        if (!mode.isGallery) {
          final controller = imageViewController;
          if (controller is! AutoReadingViewport) {
            return AutoReadingStep.waiting;
          }
          final viewport = controller as AutoReadingViewport;
          return viewport.autoScroll(distance, acrossChapters: across);
        }
        final controller = imageViewController;
        if (controller == null || isLoading) return AutoReadingStep.waiting;
        if (toNextPage(source: ReadingNavigationSource.automatic)) {
          return AutoReadingStep.advanced;
        }
        if (!controller.isAtLastVisualPartOfSource()) {
          return AutoReadingStep.waiting;
        }
        if (across && chapter < maxChapter) {
          return toNextChapter(source: ReadingNavigationSource.automatic)
              ? AutoReadingStep.advanced
              : AutoReadingStep.waiting;
        }
        return AutoReadingStep.finished;
      },
    )..addListener(update);
    history = widget.history;
    _readingChapters = _buildReadingChapters(widget.chapters) ?? const [];
    _readingCatalog = widget.chapters == null
        ? null
        : ReadingCatalog(_readingChapters);
    sessionRoundId = widget.history.activeRereadId;
    _initialNavigationCommandId = const Uuid().v4();
    final resumePosition = widget.history.resumePosition;
    final hasExplicitTarget =
        widget.initialChapter != null ||
        widget.initialPage != null ||
        widget.initialChapterGroup != null;
    final resolvedResumeChapter =
        resumePosition == null || widget.chapters == null
        ? null
        : _resolveReadingChapterIndex(
            _readingChapters,
            widget.chapters!,
            resumePosition,
          );
    final unresolvedResume =
        !hasExplicitTarget &&
        resumePosition != null &&
        widget.chapters != null &&
        resolvedResumeChapter == null;
    _showProgressConflict =
        !hasExplicitTarget &&
        (widget.history.hasOrderConflict || unresolvedResume);
    chapter =
        widget.initialChapter ??
        (hasExplicitTarget
            ? 1
            : resolvedResumeChapter ?? resumePosition?.ep ?? 1);
    if (chapter < 1) {
      chapter = 1;
    }
    final initialGroup = widget.initialChapterGroup;
    if (initialGroup != null && widget.chapters?.isGrouped == true) {
      for (int i = 0; i < (initialGroup - 1); i++) {
        chapter += widget.chapters!.getGroupByIndex(i).length;
      }
    }
    pageValue = normalizeReaderInitialPage(
      widget.initialPage ?? (hasExplicitTarget ? 1 : resumePosition?.page),
    );
    _initialObservedProgress = _captureReadingProgressSnapshot();
    _readingSession = ReadingSessionTracker(
      onDuration: (duration) =>
          HistoryManager().addReadDuration(widget.history, duration),
      onError: (error, stackTrace) {
        Log.error(
          "Reader",
          "Failed to save reading duration: $error",
          stackTrace,
        );
      },
    );
    if (!appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'showSystemStatusBar',
    )) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
    if (appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'enableTurnPageByVolumeKey',
    )) {
      handleVolumeEvent();
    }
    setImageCacheSize();
    Future.delayed(const Duration(milliseconds: 200), () {
      LocalFavoritesManager().onRead(cid, type);
    });
    final updateProgressFunc = ComicSource.find(
      type.sourceKey,
    )?.updateReadProgressFunc;
    if (updateProgressFunc != null) {
      _remoteProgressTracker = RemoteProgressTracker(
        comicId: cid,
        onUpdateProgress: updateProgressFunc,
        onError: (error, stackTrace) {
          Log.error(
            'Reader',
            'Failed to update remote read progress: $error',
            stackTrace,
          );
        },
      );
    }
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      initImagesPerPage(pageValue);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
  }

  void setImageCacheSize() async {
    var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
    if (availableRAM == null) return;
    int maxImageCacheSize;
    if (availableRAM < 1 << 30) {
      maxImageCacheSize = 100 << 20;
    } else if (availableRAM < 2 << 30) {
      maxImageCacheSize = 200 << 20;
    } else if (availableRAM < 4 << 30) {
      maxImageCacheSize = 300 << 20;
    } else {
      maxImageCacheSize = 500 << 20;
    }
    Log.info(
      "Reader",
      "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (isFullscreen) {
      fullscreen();
    }
    autoPageTurningTimer?.cancel();
    autoReadingController.removeListener(update);
    autoReadingController.dispose();
    clearNavigationCommands();
    unawaited(_remoteProgressTracker?.dispose());
    unawaited(() async {
      await _readingSession.dispose();
      await HistoryManager().flushReadingProgress(id: cid, type: type);
      final sync = DataSync();
      sync.onDataChanged(domains: {'history', 'historyChapter'});
      await sync.flushPendingChanges();
    }());
    focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    stopVolumeEvent();
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    disposeReaderWindow();
    super.dispose();
  }

  @override
  void onReaderContentLoading({bool keepImageViewController = false}) {
    super.onReaderContentLoading(
      keepImageViewController: keepImageViewController,
    );
    isLoading = true;
    _readerContentReady = false;
    flushRemoteProgress();
    unawaited(_readingSession.pause());
  }

  void onReaderContentReady() {
    isLoading = false;
    _readerContentReady = images?.isNotEmpty ?? false;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == null || lifecycleState == AppLifecycleState.resumed) {
      _readingSession.start();
    }
    unawaited(_notifyChapterCompletedIfNeeded());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    autoReadingController.pause(
      'lifecycle',
      state != AppLifecycleState.resumed,
    );
    switch (state) {
      case AppLifecycleState.resumed:
        if (_readerContentReady) {
          _readingSession.start();
          unawaited(_notifyChapterCompletedIfNeeded());
        }
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        flushRemoteProgress();
        unawaited(HistoryManager().flushReadingProgress(id: cid, type: type));
        unawaited(
          _readingSession.pause().whenComplete(
            () => DataSync().flushPendingChanges(),
          ),
        );
    }
  }

  @override
  void flushRemoteProgress() {
    unawaited(_remoteProgressTracker?.flush());
  }

  @override
  Widget build(BuildContext context) {
    if (_showProgressConflict) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Saved reading position is ambiguous. Select a chapter to continue.'
                      .tl,
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _readingChapters.length,
                  itemBuilder: (context, index) {
                    final chapterEntry = _readingChapters[index];
                    final title =
                        widget.chapters?.allChapters[chapterEntry.id] ??
                        chapterEntry.id;
                    return ListTile(
                      title: Text(
                        chapterEntry.groupId == null
                            ? title
                            : '${chapterEntry.groupId} · $title',
                      ),
                      onTap: () => _selectProgressConflictChapter(index + 1),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }
    _checkImagesPerPageChange();
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Overlay.wrap(
        child: ReaderScaffold(
          child: ReaderGestureDetector(
            child: ReaderImages(
              key: Key(mode.isWaterfall ? mode.key : chapter.toString()),
            ),
          ),
        ),
      ),
    );
  }

  void _selectProgressConflictChapter(int selectedChapter) {
    if (selectedChapter < 1 || selectedChapter > maxChapter) return;
    setState(() => _showProgressConflict = false);
    toChapter(selectedChapter, source: ReadingNavigationSource.userSeek);
  }

  void onKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    imageViewController?.handleKeyEvent(event);
  }

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  bool get isSplitDualPageEnabled =>
      mode.isGallery &&
      imagesPerPage == 1 &&
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'splitDualPage') ==
          true;

  @override
  void onPageChanged() {
    onPageChangedForNavigation(ReadingNavigationSource.passive);
  }

  @override
  void onPageChangedForNavigation(
    ReadingNavigationSource source, {
    String? commandId,
    bool recordProgress = true,
  }) {
    updateHistory(
      source: source,
      commandId: commandId,
      recordProgress: recordProgress,
    );
    if (consumeChapterCompletionSuppression()) {
      return;
    }
    unawaited(_notifyChapterCompletedIfNeeded());
  }

  void notifyChapterCompletedIfNeeded() {
    unawaited(_notifyChapterCompletedIfNeeded());
  }

  Future<void> _notifyChapterCompletedIfNeeded() async {
    if (!mounted) return;
    final chapters = widget.chapters;
    if (chapters == null) return;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (!canCompleteReaderChapter(
      isContentReady: _readerContentReady,
      isActive:
          lifecycleState == null || lifecycleState == AppLifecycleState.resumed,
      hasImages: images?.isNotEmpty ?? false,
      page: page,
      lastImagePage: maxPage,
      totalPages: totalPages,
      chapter: chapter,
      maxChapter: chapters.length,
      isGallerySplitEnabled: isSplitDualPageEnabled,
      controller: imageViewController,
    )) {
      return;
    }
    final chapterKey = chapters.ids.elementAtOrNull(chapter - 1);
    final chapterTitle = chapters.titles.elementAtOrNull(chapter - 1);
    if (chapterKey == null || chapterTitle == null) {
      return;
    }
    try {
      await _chapterCompletionNotifier.notify(
        isAtEnd: true,
        event: ReaderChapterCompletedEvent(
          sourceKey: type.sourceKey,
          comicId: cid,
          chapterKey: chapterKey,
          chapterTitle: chapterTitle,
        ),
      );
    } catch (error, stackTrace) {
      Log.error(
        'Reader',
        'Failed to notify chapter completion: $error',
        stackTrace,
      );
    }
  }

  void updateHistory({
    ReadingNavigationSource source = ReadingNavigationSource.passive,
    String? commandId,
    bool recordProgress = true,
  }) {
    if (!recordProgress ||
        !_readerContentReady ||
        isLoading ||
        images == null ||
        images!.isEmpty ||
        _showProgressConflict) {
      return;
    }
    final item = history;
    if (item == null) return;

    var submittedSource = source;
    var submittedCommandId = commandId;
    final pending = _pendingNavigation;
    if (pending != null) {
      if (!pending.matches(chapter, page)) return;
      submittedSource = pending.source;
      submittedCommandId = pending.commandId;
      _pendingNavigation = null;
    } else if (!_initialNavigationSubmitted &&
        submittedSource == ReadingNavigationSource.passive) {
      submittedSource = widget.initialNavigationSource;
      submittedCommandId = _initialNavigationCommandId;
    }
    if (!_initialNavigationSubmitted && submittedCommandId == null) {
      submittedCommandId = _initialNavigationCommandId;
    }
    if ((submittedSource == ReadingNavigationSource.userBackward ||
            submittedSource == ReadingNavigationSource.userSeek ||
            submittedSource == ReadingNavigationSource.userConfirm) &&
        submittedCommandId == null) {
      submittedCommandId = createNavigationCommandId();
    }
    final isInitialCommand = submittedCommandId == _initialNavigationCommandId;
    final storedObservedProgress =
        submittedCommandId == null || isInitialCommand
        ? null
        : takeObservedProgressForNavigation(submittedCommandId);
    final actionObservedProgress = isInitialCommand
        ? _initialObservedProgress
        : pending?.observedProgress ?? storedObservedProgress;
    final retainsObservation =
        submittedCommandId != null &&
        _retainObservedProgressCommandIds.contains(submittedCommandId);

    final sourcePage = sourceImagePageForCurrentReaderPage();
    final chapterEntry = _readingChapters.elementAtOrNull(chapter - 1);
    final localEpisode = chapterEntry?.ep ?? chapter;
    final position = ReadingPosition(
      ep: localEpisode,
      page: sourcePage,
      group: chapterEntry?.group,
      chapterId: chapterEntry?.id,
      groupId: chapterEntry?.groupId,
    );

    item.page = sourcePage;
    item.maxPage = images!.length;
    item.ep = localEpisode;
    if (chapterEntry?.group != null) {
      item.group = chapterEntry!.group;
      item.readEpisode.add('${chapterEntry.group}-$localEpisode');
    } else {
      item.group = null;
      item.readEpisode.add(chapter.toString());
    }
    item.time = DateTime.now();

    final progress = HistoryManager().recordReadingProgress(
      item,
      position: position,
      source: submittedSource,
      sessionRoundId: sessionRoundId,
      commandId: submittedCommandId,
      catalog: _readingCatalog,
      observedProgress:
          retainsObservation ||
              submittedSource == ReadingNavigationSource.userBackward ||
              submittedSource == ReadingNavigationSource.userSeek ||
              submittedSource == ReadingNavigationSource.userConfirm
          ? actionObservedProgress
          : null,
      onLocalProgressRecorded: retainsObservation
          ? retainLocallyRecordedNavigationProgress
          : null,
    );
    if ((submittedSource == ReadingNavigationSource.userBackward ||
            submittedSource == ReadingNavigationSource.userSeek) &&
        submittedCommandId != null &&
        progress.isActiveRound(submittedCommandId)) {
      sessionRoundId = submittedCommandId;
    }
    _initialNavigationSubmitted = true;
    if (isInitialCommand) _initialObservedProgress = null;

    final remoteEpId =
        chapterEntry?.id ?? widget.chapters?.ids.elementAtOrNull(chapter - 1);
    if (remoteEpId != null && remoteEpId.isNotEmpty) {
      _remoteProgressTracker?.schedule(remoteEpId, sourcePage);
    }
  }

  @override
  ReadingProgress? captureObservedProgressForNavigation() =>
      _captureReadingProgressSnapshot();

  ReadingProgress? _captureReadingProgressSnapshot() {
    final item = history;
    if (item == null) return null;
    final latestManager = HistoryManager.cache;
    final latestProgress = latestManager?.isInitialized == true
        ? latestManager!.find(widget.cid, widget.type)?.readingProgress
        : null;
    final progress = item.readingProgress;
    if (latestProgress != null) {
      return progress == null || identical(progress, latestProgress)
          ? latestProgress
          : latestProgress.merge(progress);
    }
    if (progress != null) return progress;

    final savedPosition = item.resumePosition;
    final savedChapterIndex = savedPosition == null || widget.chapters == null
        ? null
        : _resolveReadingChapterIndex(
            _readingChapters,
            widget.chapters!,
            savedPosition,
          );
    final chapterEntry = savedPosition == null
        ? readingChapter
        : savedChapterIndex == null
        ? null
        : _readingChapters.elementAtOrNull(savedChapterIndex - 1);
    final sourcePage =
        savedPosition?.page ??
        (images == null || images!.isEmpty
            ? pageValue
            : sourceImagePageForReaderPage(
                readerPage: page,
                imageCount: images!.length,
                imagesPerPage: imagesPerPage,
                showSingleImageOnFirstPage: showSingleImageOnFirstPage(),
              ));
    final position = savedPosition != null && chapterEntry == null
        ? savedPosition
        : ReadingPosition(
            ep: chapterEntry?.ep ?? savedPosition?.ep ?? chapter,
            page: sourcePage,
            group: chapterEntry?.group ?? savedPosition?.group,
            chapterId: chapterEntry?.id ?? savedPosition?.chapterId,
            groupId: chapterEntry?.groupId ?? savedPosition?.groupId,
          );
    return ReadingProgress.seed(position, catalog: _readingCatalog);
  }

  bool get isFirstChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      int c = chapter - 1;
      int g = 1;
      while (c > 0) {
        c -= widget.chapters!.getGroupByIndex(g - 1).length;
        g++;
      }
      if (c == 0) {
        return true;
      } else {
        return false;
      }
    }
    return chapter == 1;
  }

  bool get isLastChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      int c = chapter;
      int g = 1;
      while (c > 0) {
        c -= widget.chapters!.getGroupByIndex(g - 1).length;
        g++;
      }
      if (c == 0) {
        return true;
      } else {
        return false;
      }
    }
    return chapter == maxChapter;
  }

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }
}

mixin ReaderImagePerPageHandler on ReaderLocation {
  late int _lastImagesPerPage;

  late bool _lastOrientation;

  late bool _lastSingleImageOnFirstPage;
  int? _sourceImageAnchor;
  int? _sourceAnchorChapter;
  int? _sourceAnchorReaderPage;

  /// Track if we were on the chapter comments page before orientation change
  bool _wasOnCommentsPage = false;

  bool get isPortrait;

  ReaderMode get mode;

  /// Whether the current page is the chapter comments page
  bool get isOnChapterCommentsPage;

  /// Get images list for calculating maxPage
  List<String>? get images;

  /// Preserve the open Reader's source image independently of synced resume.
  int sourceImagePageForCurrentReaderPage({int? perPage, bool? singleImage}) {
    final count = images?.length ?? 0;
    if (count == 0) return _sourceImageAnchor ?? page;
    final perPageValue = perPage ?? imagesPerPage;
    final singleImageValue = singleImage ?? showSingleImageOnFirstPage();
    final anchor = _sourceImageAnchor;
    if (anchor != null &&
        anchor <= count &&
        _sourceAnchorChapter == chapter &&
        _sourceAnchorReaderPage == page &&
        readerPageForSourceImagePage(
              sourceImagePage: anchor,
              imageCount: count,
              imagesPerPage: perPageValue,
              showSingleImageOnFirstPage: singleImageValue,
            ) ==
            page) {
      return anchor;
    }
    final sourcePage = sourceImagePageForReaderPage(
      readerPage: page,
      imageCount: count,
      imagesPerPage: perPageValue,
      showSingleImageOnFirstPage: singleImageValue,
    );
    _sourceImageAnchor = sourcePage;
    _sourceAnchorChapter = chapter;
    _sourceAnchorReaderPage = page;
    return sourcePage;
  }

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastOrientation = isPortrait;
    _lastSingleImageOnFirstPage = showSingleImageOnFirstPage();
    _sourceImageAnchor = initialPage;
    _sourceAnchorChapter = chapter;
    _wasOnCommentsPage = false;
    if (imagesPerPage != 1) {
      pageValue = calculateInitialReaderPageForImagesPerPage(
        initialPage: initialPage,
        imagesPerPage: imagesPerPage,
        showSingleImageOnFirstPage: showSingleImageOnFirstPage(),
      );
    }
    _sourceAnchorReaderPage = pageValue;
  }

  bool showSingleImageOnFirstPage() => appdata.settings.getReaderSetting(
    cid,
    type.sourceKey,
    'showSingleImageOnFirstPage',
  );

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (isPortrait) {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForPortrait',
          ) ??
          1;
    } else {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForLandscape',
          ) ??
          1;
    }
  }

  /// Calculate maxPage with a specific imagesPerPage value
  int _calcMaxPage(int imagesPerPageValue, bool singleImage) {
    if (images == null) return 1;
    return !singleImage
        ? (images!.length / imagesPerPageValue).ceil()
        : 1 + ((images!.length - 1) / imagesPerPageValue).ceil();
  }

  /// Check if the number of images per page has changed
  void _checkImagesPerPageChange() {
    int currentImagesPerPage = imagesPerPage;
    bool currentOrientation = isPortrait;
    final currentSingleImage = showSingleImageOnFirstPage();

    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastOrientation != currentOrientation ||
        _lastSingleImageOnFirstPage != currentSingleImage) {
      // Calculate old maxPage using old imagesPerPage to correctly determine
      // if we were on the comments page before the orientation change
      int oldMaxPage = _calcMaxPage(
        _lastImagesPerPage,
        _lastSingleImageOnFirstPage,
      );
      _wasOnCommentsPage = page > oldMaxPage;

      _adjustPageForImagesPerPageChange(
        _lastImagesPerPage,
        currentImagesPerPage,
        _lastSingleImageOnFirstPage,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
      _lastSingleImageOnFirstPage = currentSingleImage;
    }
  }

  /// Adjust the page number when the number of images per page changes
  void _adjustPageForImagesPerPageChange(
    int oldImagesPerPage,
    int newImagesPerPage,
    bool oldSingleImage,
  ) {
    final singleImage = showSingleImageOnFirstPage();
    final imageCount = images?.length ?? 0;
    final sourceImagePage = sourceImagePageForCurrentReaderPage(
      perPage: oldImagesPerPage,
      singleImage: oldSingleImage,
    );
    var newPage = imageCount > 0
        ? readerPageForSourceImagePage(
            sourceImagePage: sourceImagePage,
            imageCount: imageCount,
            imagesPerPage: newImagesPerPage,
            showSingleImageOnFirstPage: singleImage,
          )
        : calculateInitialReaderPageForImagesPerPage(
            initialPage: sourceImagePage,
            imagesPerPage: newImagesPerPage,
            showSingleImageOnFirstPage: singleImage,
          );

    // Clamp to valid range (1 to maxPage)
    newPage = newPage.clamp(1, maxPage).toInt();
    if (!_wasOnCommentsPage) {
      _sourceImageAnchor = sourceImagePage;
      _sourceAnchorChapter = chapter;
      _sourceAnchorReaderPage = newPage;
    }

    // Gallery is keyed by these layout settings and opens its replacement
    // controller at this remapped page. This is not a new reading action.
    pageValue = _wasOnCommentsPage ? maxPage + 1 : newPage;
  }
}

abstract mixin class ReaderVolumeListener {
  bool toNextPage({
    ReadingNavigationSource source = ReadingNavigationSource.userForward,
  });

  bool toPrevPage({
    ReadingNavigationSource source = ReadingNavigationSource.userBackward,
  });

  bool toNextChapter({
    ReadingNavigationSource source = ReadingNavigationSource.userForward,
  });

  bool toPrevChapter({
    bool toLastPage = false,
    ReadingNavigationSource source = ReadingNavigationSource.userBackward,
  });

  VolumeListener? volumeListener;

  void onDown() {
    if (!toNextPage(source: ReadingNavigationSource.userForward)) {
      toNextChapter(source: ReadingNavigationSource.userForward);
    }
  }

  void onUp() {
    if (!toPrevPage(source: ReadingNavigationSource.userBackward)) {
      toPrevChapter(
        toLastPage: true,
        source: ReadingNavigationSource.userBackward,
      );
    }
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class ReaderLocation {
  int pageValue = 1;
  int? _pendingPage;
  _PendingReaderNavigation? _pendingNavigation;
  final Map<String, ReadingProgress?> _observedProgressByCommandId = {};
  final Set<String> _retainObservedProgressCommandIds = {};

  /// Flag to indicate that the page should jump to the last page after images are loaded.
  bool jumpToLastPageOnLoad = false;

  /// Flag to indicate that the initial visual page should be the last visual page
  /// (e.g. when jumping to the previous chapter's end).
  bool targetLastVisualPage = false;
  int get page => pageValue;

  set page(int value) {
    pageValue = value;
    onPageChangedForNavigation(ReadingNavigationSource.passive);
  }

  int chapter = 1;

  int get maxPage;

  /// Total pages including chapter comments page (for internal page control).
  int get totalPages;

  int get maxChapter;

  bool get isLoading;
  bool get canAcceptReaderPageChanges => true;

  String get cid;

  ComicType get type;

  void onReaderContentLoading({bool keepImageViewController = false}) {
    if (!keepImageViewController) {
      imageViewController = null;
    }
  }

  void update();

  void flushRemoteProgress();

  bool enablePageAnimation(String cid, ComicType type) => appdata.settings
      .getReaderSetting(cid, type.sourceKey, 'enablePageAnimation');

  ReaderImageViewController? imageViewController;

  void onPageChanged();

  void onPageChangedForNavigation(
    ReadingNavigationSource source, {
    String? commandId,
    bool recordProgress = true,
  }) {
    onPageChanged();
  }

  ReadingNavigationSource? get pendingNavigationSource =>
      _pendingNavigation?.source;

  int? get pendingNavigationPage => _pendingNavigation?.page;

  int? get pendingNavigationChapter => _pendingNavigation?.chapter;

  ReadingProgress? captureObservedProgressForNavigation() => null;

  String createNavigationCommandId({bool retainObservedProgress = false}) {
    final pending = _pendingNavigation;
    if (pending != null) {
      cancelNavigationCommand(pending.commandId);
    }
    final commandId = const Uuid().v4();
    _observedProgressByCommandId[commandId] =
        captureObservedProgressForNavigation();
    if (retainObservedProgress) {
      _retainObservedProgressCommandIds.add(commandId);
    }
    return commandId;
  }

  ReadingProgress? takeObservedProgressForNavigation(String commandId) {
    final progress = _observedProgressByCommandId[commandId];
    if (!_retainObservedProgressCommandIds.contains(commandId)) {
      _observedProgressByCommandId.remove(commandId);
    }
    return progress;
  }

  String renewNavigationCommand(String commandId) {
    final observed = _observedProgressByCommandId[commandId];
    final retained = _retainObservedProgressCommandIds.contains(commandId);
    finishNavigationCommand(commandId);
    final nextId = const Uuid().v4();
    _observedProgressByCommandId[nextId] = observed;
    if (retained) _retainObservedProgressCommandIds.add(nextId);
    return nextId;
  }

  void retainLocallyRecordedNavigationProgress(
    String commandId,
    ReadingProgress progress,
  ) {
    if (_retainObservedProgressCommandIds.contains(commandId)) {
      _observedProgressByCommandId[commandId] = progress;
    }
  }

  String beginNavigationCommand(
    ReadingNavigationSource source, {
    int? chapter,
    int? page,
  }) {
    final commandId = createNavigationCommandId();
    _pendingNavigation = _PendingReaderNavigation(
      source: source,
      commandId: commandId,
      observedProgress: _observedProgressByCommandId[commandId],
      chapter: chapter,
      page: page,
    );
    return commandId;
  }

  void finishNavigationCommand(String commandId) {
    _observedProgressByCommandId.remove(commandId);
    _retainObservedProgressCommandIds.remove(commandId);
    if (_pendingNavigation?.commandId == commandId) {
      _pendingNavigation = null;
    }
  }

  void cancelNavigationCommand(String commandId) =>
      finishNavigationCommand(commandId);

  void cancelPendingNavigation() {
    final commandId = _pendingNavigation?.commandId;
    if (commandId != null) cancelNavigationCommand(commandId);
  }

  void clearNavigationCommands() {
    _pendingNavigation = null;
    _observedProgressByCommandId.clear();
    _retainObservedProgressCommandIds.clear();
  }

  bool _suppressNextChapterCompletion = false;

  /// Sets [page] while suppressing chapter completion notification for this update.
  /// Used exclusively during comments tail-growth recovery.
  void setPageSuppressingCompletion(
    int page, {
    ReadingNavigationSource source = ReadingNavigationSource.passive,
  }) {
    _suppressNextChapterCompletion = true;
    try {
      setPage(page, source: source);
    } finally {
      _suppressNextChapterCompletion = false;
    }
  }

  /// Consumes and clears the chapter completion suppression flag.
  @protected
  bool consumeChapterCompletionSuppression() {
    final suppressed = _suppressNextChapterCompletion;
    _suppressNextChapterCompletion = false;
    return suppressed;
  }

  void setPage(
    int page, {
    ReadingNavigationSource source = ReadingNavigationSource.passive,
    String? commandId,
    bool navigationCompleted = false,
  }) {
    if (isLoading || !canAcceptReaderPageChanges) {
      if (source == ReadingNavigationSource.layout) {
        pageValue = page;
      }
      return;
    }
    if (_animationCount > 0 &&
        _pendingPage != null &&
        page != _pendingPage &&
        !navigationCompleted) {
      return;
    }
    pageValue = page;
    var resolvedSource = source;
    var resolvedCommandId = commandId;
    var recordProgress = true;
    final pending = _pendingNavigation;
    if (pending != null) {
      if (pending.matches(chapter, page) ||
          (navigationCompleted &&
              _validatePage(page) &&
              (pending.chapter == null || pending.chapter == chapter))) {
        resolvedSource = pending.source;
        resolvedCommandId = pending.commandId;
        _pendingNavigation = null;
      } else {
        // Animated controllers may report intermediate positions. They are
        // visual state only; a command commits only its validated destination.
        recordProgress = false;
      }
    }
    onPageChangedForNavigation(
      resolvedSource,
      commandId: resolvedCommandId,
      recordProgress: recordProgress,
    );
  }

  bool _validatePage(int page) {
    return page >= 1 && page <= totalPages;
  }

  int _animationCount = 0;
  int _pageAnimationGeneration = 0;

  void resetPageAnimation() {
    _pageAnimationGeneration++;
    _animationCount = 0;
    _pendingPage = null;
  }

  int startPageAnimation() {
    _animationCount++;
    update();
    return _pageAnimationGeneration;
  }

  void endPageAnimation([int? generation]) {
    if (generation != null && generation != _pageAnimationGeneration) {
      return;
    }
    if (_animationCount > 0) {
      _animationCount--;
      update();
    }
  }

  /// Returns true if the page is changed
  bool toNextPage({
    ReadingNavigationSource source = ReadingNavigationSource.userForward,
  }) {
    final controller = imageViewController;
    if (controller != null) {
      final commandId = beginNavigationCommand(source, chapter: chapter);
      if (controller.toNextPage()) {
        return true;
      }
      cancelNavigationCommand(commandId);
    }
    return toPage(page + 1, source: source);
  }

  /// Returns true if the page is changed
  bool toPrevPage({
    ReadingNavigationSource source = ReadingNavigationSource.userBackward,
  }) {
    final controller = imageViewController;
    if (controller != null) {
      final commandId = beginNavigationCommand(source, chapter: chapter);
      if (controller.toPrevPage()) {
        return true;
      }
      cancelNavigationCommand(commandId);
    }
    targetLastVisualPage = false;
    return toPage(page - 1, source: source);
  }

  bool toPage(
    int page, {
    bool animated = true,
    ReadingNavigationSource source = ReadingNavigationSource.userSeek,
    String? commandId,
  }) {
    final controller = imageViewController;
    if (controller == null || isLoading) {
      return false;
    }
    if (_validatePage(page)) {
      if (page == this.page && !isPageAnimating) {
        if (source == ReadingNavigationSource.userSeek) {
          source = ReadingNavigationSource.userConfirm;
          final id =
              commandId ??
              beginNavigationCommand(source, chapter: chapter, page: page);
          setPage(page, source: source, commandId: id);
          return true;
        }
        return false;
      }
      final id =
          commandId ??
          beginNavigationCommand(source, chapter: chapter, page: page);
      if (_pendingNavigation?.commandId == id) {
        _pendingNavigation = _pendingNavigation!.withPage(page);
      }
      resetPageAnimation();
      final hasAnimation = animated && enablePageAnimation(cid, type);
      if (hasAnimation) {
        _pendingPage = page;
        _animationCount++;
        final generation = _pageAnimationGeneration;
        update();
        void finishAnimation() {
          if (generation != _pageAnimationGeneration) return;
          _animationCount--;
          if (_pendingPage == page) {
            _pendingPage = null;
          }
          update();
        }

        unawaited(
          Future<void>.sync(() => controller.animateToPage(page)).then(
            (_) => finishAnimation(),
            onError: (Object error, StackTrace stackTrace) {
              Log.error('Reader', 'Page navigation failed: $error', stackTrace);
              cancelNavigationCommand(id);
              finishAnimation();
            },
          ),
        );
      } else {
        update();
        controller.toPage(page);
      }
      return true;
    }
    return false;
  }

  void toVisualEnd({
    ReadingNavigationSource source = ReadingNavigationSource.userSeek,
  }) {
    if (imageViewController != null) {
      beginNavigationCommand(source, chapter: chapter);
      imageViewController!.toVisualEnd();
      return;
    } else if (isLoading) {
      jumpToLastPageOnLoad = true;
      beginNavigationCommand(source, chapter: chapter);
    }
  }

  bool get isPageAnimating => _animationCount > 0;

  bool _validateChapter(int chapter) {
    return chapter >= 1 && chapter <= maxChapter;
  }

  /// Returns true if the chapter is changed
  bool toNextChapter({
    ReadingNavigationSource source = ReadingNavigationSource.userForward,
  }) {
    return toChapter(chapter + 1, source: source);
  }

  /// Returns true if the chapter is changed
  /// If [toLastPage] is true, the page will be set to the last page of the previous chapter.
  bool toPrevChapter({
    bool toLastPage = false,
    ReadingNavigationSource source = ReadingNavigationSource.userBackward,
  }) {
    return toChapter(chapter - 1, toLastPage: toLastPage, source: source);
  }

  bool toChapter(
    int c, {
    bool toLastPage = false,
    ReadingNavigationSource source = ReadingNavigationSource.userSeek,
  }) {
    if (_validateChapter(c) && !isLoading) {
      flushRemoteProgress();
      beginNavigationCommand(source, chapter: c);
      if (imageViewController?.toChapter(c, toLastPage: toLastPage) ?? false) {
        return true;
      }
      onReaderContentLoading();
      chapter = c;
      pageValue = 1;
      jumpToLastPageOnLoad = toLastPage;
      update();
      return true;
    }
    return false;
  }

  Timer? autoPageTurningTimer;

  void autoPageTurning(String cid, ComicType type) {
    final reader = this as ReaderState;
    reader.autoReading.toggle();
    update();
  }
}

mixin class ReaderWindow {
  bool isFullscreen = false;

  late WindowFrameController windowFrame;

  bool _isInit = false;

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    windowFrame = WindowFrame.of(App.rootContext);
    windowFrame.addCloseListener(onWindowClose);
    _isInit = true;
  }

  void fullscreen() async {
    if (!App.isDesktop) return;
    await windowManager.hide();
    await windowManager.setFullScreen(!isFullscreen);
    await windowManager.show();
    isFullscreen = !isFullscreen;
    WindowFrame.of(App.rootContext).setWindowFrame(!isFullscreen);
  }

  bool onWindowClose() {
    if (Navigator.of(App.rootContext).canPop()) {
      Navigator.of(App.rootContext).pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!App.isDesktop) return;
    windowFrame.removeCloseListener(onWindowClose);
  }
}

enum ReaderMode {
  waterfallTopToBottom('waterfallTopToBottom'),
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isWaterfall => key.startsWith('waterfall');

  bool get isContinuous => key.startsWith('continuous') || isWaterfall;

  bool get isTopToBottom =>
      this == galleryTopToBottom ||
      this == continuousTopToBottom ||
      this == waterfallTopToBottom;

  const ReaderMode(this.key);

  static ReaderMode fromKey(String key) {
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return waterfallTopToBottom;
  }
}

/// Immutable reference to an image within the Reader.
///
/// Distinguishes four distinct identity dimensions:
/// - [imageKey]: image loading identity (URL, `file://`, or cache key).
/// - [sourceKey]: comic source identifier.
/// - [cid]: comic identifier.
/// - [eid]: opaque chapter identifier from comic source.
/// - [chapter]: 1-based chapter index in Reader.
/// - [page]: 1-based source image page within chapter.
/// - [file]: local file handle if backed by a file.
@immutable
class ReaderImageReference {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int? chapter;
  final int? page;
  final File? file;

  const ReaderImageReference({
    required this.imageKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
    this.chapter,
    this.page,
    this.file,
  });
}

abstract interface class ReaderImageViewController
    implements ChapterCompletionSourceController {
  void toPage(int page);

  void toVisualEnd();

  Future<void> animateToPage(int page);

  bool toNextPage();

  bool toPrevPage();

  @override
  bool isAtLastVisualPartOfSource();

  @override
  bool isCurrentSourceSizeResolved();

  @override
  bool isReadyForChapter(int chapter);

  bool toChapter(int chapter, {bool toLastPage = false});

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  ReaderImageReference? getImageReferenceByOffset(Offset offset);

  ReaderImageReference? getImageReferenceByIndex(int index);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}

/// Builds a sanitized reader image file name using [sanitizeFileNameWithSuffix].
String buildReaderImageFileName(
  String title,
  int chapter,
  int page,
  String extension,
) {
  return sanitizeFileNameWithSuffix(
    title,
    middle: '_EP${chapter}_P$page',
    extension: extension,
  );
}

typedef ReaderOriginalImageLoader =
    Future<Uint8List> Function(
      String imageKey,
      String? sourceKey,
      String cid,
      String eid, {
      ComicImageLoadTarget? target,
    });

/// Loads original unscaled image bytes for [ref].
///
/// When backed by a local file, reads file directly or throws [FileSystemException]
/// if it does not exist. For remote images, delegates to [loader] with [target] forced to `null`.
Future<Uint8List> loadReaderOriginalImageBytes(
  ReaderImageReference ref, {
  String? fallbackSourceKey,
  ReaderOriginalImageLoader loader = ImageDownloader.loadComicImageBytes,
}) async {
  if (ref.file != null) {
    if (!await ref.file!.exists()) {
      throw FileSystemException("File not found", ref.file!.path);
    }
    return await ref.file!.readAsBytes();
  }
  if (ref.imageKey.startsWith("file://")) {
    final file = File(ref.imageKey.substring(7));
    if (!await file.exists()) {
      throw FileSystemException("File not found", file.path);
    }
    return await file.readAsBytes();
  }
  return await loader(
    ref.imageKey,
    ref.sourceKey ?? fallbackSourceKey,
    ref.cid,
    ref.eid,
    target: null,
  );
}

/// Normalizes reader initial page: null or non-positive values resolve to 1.
int normalizeReaderInitialPage(int? page) {
  if (page == null || page < 1) {
    return 1;
  }
  return page;
}

/// Calculates initial reader page when [imagesPerPage] is configured.
int calculateInitialReaderPageForImagesPerPage({
  required int initialPage,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  final normalized = normalizeReaderInitialPage(initialPage);
  if (imagesPerPage <= 1) {
    return normalized;
  }
  int newPage;
  if (showSingleImageOnFirstPage) {
    newPage = ((normalized - 1) / imagesPerPage).ceil() + 1;
  } else {
    newPage = (normalized / imagesPerPage).ceil();
  }
  return newPage < 1 ? 1 : newPage;
}

/// Maps the Reader's visual page to its first source-image index.
int sourceImagePageForReaderPage({
  required int readerPage,
  required int imageCount,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  if (imageCount <= 0) return 1;
  final perPage = imagesPerPage < 1 ? 1 : imagesPerPage;
  final maxPage = showSingleImageOnFirstPage
      ? 1 + ((imageCount - 1) / perPage).ceil()
      : (imageCount / perPage).ceil();
  final sourcePage = readerPage >= maxPage
      ? imageCount
      : !showSingleImageOnFirstPage || perPage == 1
      ? (readerPage - 1) * perPage + 1
      : readerPage == 1
      ? 1
      : (readerPage - 2) * perPage + 2;
  return sourcePage.clamp(1, imageCount).toInt();
}

/// Maps a source-image index to the Reader's current visual page.
int readerPageForSourceImagePage({
  required int sourceImagePage,
  required int imageCount,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  if (imageCount <= 0) return 1;
  final sourcePage = sourceImagePage.clamp(1, imageCount).toInt();
  final perPage = imagesPerPage < 1 ? 1 : imagesPerPage;
  if (perPage == 1) return sourcePage;
  if (showSingleImageOnFirstPage) {
    return sourcePage == 1 ? 1 : ((sourcePage - 1) / perPage).ceil() + 1;
  }
  return (sourcePage / perPage).ceil();
}
