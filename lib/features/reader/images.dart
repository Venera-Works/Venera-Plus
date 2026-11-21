import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/features/reader/auto_reading.dart';
import 'package:venera_plus/features/reader/chapter_comments.dart';
import 'package:venera_plus/features/reader/chapter_loader.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/features/reader/gallery_page_plan.dart';
import 'package:venera_plus/features/reader/gallery_coordinator.dart';
import 'package:venera_plus/features/reader/image_preloader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/waterfall_flow.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_read_scheduler.dart';

class ReaderImages extends StatefulWidget {
  const ReaderImages({super.key});

  @override
  State<ReaderImages> createState() => ReaderImagesState();
}

class ReaderImagesState extends State<ReaderImages> {
  String? error;

  bool inProgress = false;

  bool _forceRefresh = false;

  late ReaderState reader;

  void retryImage(int chapter, int sourcePage) {
    if (inProgress) return;
    reader.onReaderContentLoading();
    reader.chapter = chapter;
    reader.pageValue = sourcePage;
    reader.initImagesPerPage(sourcePage);
    setState(() {
      _forceRefresh = true;
      reader.isLoading = true;
      error = null;
    });
  }

  @override
  void initState() {
    reader = context.reader;
    reader.onReaderContentLoading();
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  /// Handle jumping to last page when jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader.jumpToLastPageOnLoad) {
      if (!reader.mode.isContinuous || !reader.mode.isTopToBottom) {
        reader.targetLastVisualPage =
            reader.isSplitDualPageEnabled || reader.usesGallerySpread;
      }
      reader.pageValue = reader.maxPage;
      reader.jumpToLastPageOnLoad = false;
    } else if (!reader.isSplitDualPageEnabled) {
      reader.targetLastVisualPage = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    error = null;
    var fellBackOnline = false;
    try {
      final images = await loadReaderChapterImages(
        comicId: reader.cid,
        type: reader.type,
        chapter: reader.chapter,
        chapters: reader.widget.chapters,
        forceRefresh: _forceRefresh,
        onOnlineFallback: () {
          fellBackOnline = true;
          reader.onLocalChapterRecoveredOnline();
        },
      );
      if (!mounted) return;
      reader.images = images;
      _forceRefresh = false;
      var spreadSourcePage = reader.usesGallerySpread
          ? reader.initialGallerySpreadSourcePage
          : null;

      if (!reader.localPageOrderChecked) {
        final history = reader.history;
        if (history != null) {
          final previousPage = history.page;
          final savedPosition = history.resumePosition;
          final currentChapter = reader.readingChapter;
          final isSameChapter =
              currentChapter != null &&
              (savedPosition?.chapterId != null
                  ? savedPosition!.chapterId == currentChapter.id
                  : savedPosition != null
                  ? savedPosition.ep == currentChapter.ep &&
                        savedPosition.group == currentChapter.group
                  : history.ep == currentChapter.ep &&
                        history.group == currentChapter.group);
          final currentSourcePage =
              spreadSourcePage ??
              sourceImagePageForReaderPage(
                readerPage: reader.pageValue,
                imageCount: images.length,
                imagesPerPage: reader.imagesPerPage,
                showSingleImageOnFirstPage: reader.showSingleImageOnFirstPage(),
              );
          final savedSourcePage = savedPosition?.page ?? previousPage;
          final isLocalOrDownloaded =
              !fellBackOnline &&
              (reader.type == ComicType.local ||
                  LocalManager().isDownloaded(
                    reader.cid,
                    reader.type,
                    reader.chapter,
                    reader.widget.chapters,
                  ));
          final isLegacyRemoteLibrary =
              reader.type == ComicType.fromKey(RemoteLibrarySource.sourceKey);

          if ((isLocalOrDownloaded || isLegacyRemoteLibrary) && isSameChapter) {
            try {
              await LocalManager().migrateLegacyPageOrder(history, images);
              if (!mounted) return;
              if (isSameChapter && currentSourcePage == savedSourcePage) {
                if (spreadSourcePage != null) {
                  spreadSourcePage = history.page;
                } else {
                  reader.pageValue = readerPageForSourceImagePage(
                    sourceImagePage: history.page,
                    imageCount: images.length,
                    imagesPerPage: reader.imagesPerPage,
                    showSingleImageOnFirstPage: reader
                        .showSingleImageOnFirstPage(),
                  );
                }
              }
            } catch (e, s) {
              Log.error(
                'Migration',
                'Failed to migrate legacy page order: $e',
                s,
              );
            }
          }
        }
        reader.localPageOrderChecked = true;
      }

      if (spreadSourcePage != null) {
        reader.setGallerySpreadSourcePage(spreadSourcePage);
      }
      setState(() {
        reader.isLoading = false;
        inProgress = false;
        _handleJumpToLastPage();
        Future.microtask(() {
          if (!mounted) return;
          reader.onReaderContentReady();
          reader.updateHistory();
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        reader.isLoading = false;
        inProgress = false;
      });
    }
    if (mounted) {
      if (error != null || reader.images?.isEmpty == true) {
        reader.autoReading.stop();
      }
      context.readerScaffold.update();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        var splitDualPage =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'splitDualPage',
            ) ==
            true;
        var splitDualPageInvert =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'splitDualPageInvert',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${reader.showSingleImageOnFirstPage()}_${showComments}_${showCommentsAtEnd}_${splitDualPage}_${splitDualPageInvert}_${reader.chapter}',
          ),
        );
      } else {
        return _ContinuousMode(
          key: Key(reader.mode.key),
          crossChapter: reader.mode.isWaterfall,
        );
      }
    }
  }
}

GalleryReadingDirection _galleryReadingDirectionOf(ReaderMode mode) {
  switch (mode) {
    case ReaderMode.galleryRightToLeft:
    case ReaderMode.continuousRightToLeft:
      return GalleryReadingDirection.rightToLeft;
    case ReaderMode.galleryTopToBottom:
    case ReaderMode.continuousTopToBottom:
    case ReaderMode.waterfallTopToBottom:
      return GalleryReadingDirection.topToBottom;
    case ReaderMode.galleryLeftToRight:
    case ReaderMode.continuousLeftToRight:
      return GalleryReadingDirection.leftToRight;
  }
}

@visibleForTesting
class GalleryMode extends StatefulWidget {
  const GalleryMode({super.key});

  @override
  State<GalleryMode> createState() => GalleryModeState();
}

typedef _GalleryMode = GalleryMode;

class GalleryModeState extends State<_GalleryMode>
    implements
        ReaderImageViewController,
        AutoReadingViewport,
        AutoReadingImageViewport {
  late PageController controller;

  int get preCacheCount => reader.readerSetting('preloadImageCount');

  final _pool = GalleryPhotoViewControllerPool();
  final _preloader = ReaderImagePreloader();
  bool _preloadScheduled = false;
  String? _lastVisibleStableIdentity;
  int? _targetControllerIndex;
  int _visualAnimationGeneration = 0;
  int? _visualAnimationToken;
  bool get _isAnimatingVisualPage => _visualAnimationToken != null;

  String _controllerKeyForIndex(int index) {
    if (index < 1 || index > totalVisualPages) return 'boundary:$index';
    return resolveControllerKey(
      controllerIndex: index,
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      isCommentsPage: isChapterCommentsPage(index),
      getPageImagesRange: getPageImagesRange,
    );
  }

  String? _visibleStableIdentityForIndex(int index) {
    return resolveVisibleStableIdentity(
      controllerIndex: index,
      totalVisualPages: totalVisualPages,
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      isCommentsPage: isChapterCommentsPage(index),
      getPageImagesRange: getPageImagesRange,
    );
  }

  late ReaderState reader;

  GalleryPagePlan? _pagePlan;
  int _currentControllerIndex = 1;
  bool _isUserPaging = false;
  String? _userPagingCommandId;
  int? _attachedChapter;
  final Set<int> _resolvedSourceIndices = <int>{};
  final _coalescer = GallerySizeUpdateCoalescer();
  bool _recoveryScheduled = false;
  final _spreadSizes = <int, Size>{};
  final _pendingSpreadSizes = <int, Size>{};
  bool isSourceSizeResolved(int sourceIndex) =>
      _resolvedSourceIndices.contains(sourceIndex);

  @override
  bool isReadyForChapter(int chapter) =>
      mounted &&
      _attachedChapter == chapter &&
      (_pagePlan != null || reader.usesGallerySpread);

  @override
  bool isCurrentSourceSizeResolved() {
    if (reader.usesGallerySpread) {
      final current = controller.hasClients
          ? controller.page?.round() ?? _currentControllerIndex
          : _currentControllerIndex;
      if (isChapterCommentsPage(current)) {
        return _spreadSizes.containsKey(reader.images!.length - 1);
      }
      if (current < 1 || current > totalVisualImagePages) return false;
      final (start, end) = getPageImagesRange(current);
      for (var index = start; index < end; index++) {
        if (!_spreadSizes.containsKey(index)) return false;
      }
      return true;
    }
    if (!isSplitEnabled || _pagePlan == null) return true;
    final current = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    if (isChapterCommentsPage(current)) {
      return isCommentsSourceSizeResolved(
        isSplitEnabled: isSplitEnabled,
        sourcePageCount: reader.images?.length ?? 0,
        resolvedSourceIndices: _resolvedSourceIndices,
      );
    }
    final visualIndex = current - 1;
    final displayPage = _pagePlan!.maybeDisplayPageAt(visualIndex);
    if (displayPage == null) return false;
    return _resolvedSourceIndices.contains(displayPage.sourceIndex);
  }

  @override
  AutoReadingImageReadiness get autoReadingImages =>
      _visibleAutoReadingImages(imageStates);

  @override
  bool get autoReadingReady {
    if (!controller.hasClients ||
        fingers > 0 ||
        _isAnimatingVisualPage ||
        reader.isPageAnimating ||
        controller.position.isScrollingNotifier.value) {
      return false;
    }
    if (reader.images == null || reader.images!.isEmpty) {
      return false;
    }
    final currentIndex = controller.page?.round() ?? _currentControllerIndex;
    if (reader.isOnChapterCommentsPage || isChapterCommentsPage(currentIndex)) {
      return true;
    }
    if (currentIndex < 1 || currentIndex > totalVisualPages) {
      return false;
    }
    if (isSplitEnabled) {
      if (_pagePlan == null ||
          (!isCurrentSourceSizeResolved() &&
              reader.readerSetting('autoReadingSkipUnavailableImages') !=
                  true)) {
        return false;
      }
    }
    final key = _controllerKeyForIndex(currentIndex);
    final photo = _pool[key];
    final initialScale = photo?.getInitialScale?.call();
    // PhotoView installs this callback only after its image is decoded.
    if ((initialScale == null &&
            reader.readerSetting('autoReadingSkipUnavailableImages') != true) ||
        (initialScale != null &&
            ((photo?.scale ?? initialScale) - initialScale).abs() > 0.01)) {
      return false;
    }
    final visible = imageStates
        .whereType<ComicImageState>()
        .where((image) => image.visibleInReader)
        .toList();
    return visible.isNotEmpty &&
        (reader.readerSetting('autoReadingSkipUnavailableImages') == true ||
            visible.every((image) => image.readyForAutoReading));
  }

  @override
  AutoReadingStep autoScroll(double distance, {required bool acrossChapters}) =>
      AutoReadingStep.finished;

  bool get isSplitEnabled => reader.imagesPerPage == 1 && _splitDualPage;

  bool get _splitDualPage =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPage',
      ) ==
      true;

  bool get _splitDualPageInvert =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPageInvert',
      ) ==
      true;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages => reader.maxPage;

  int get totalVisualImagePages => (isSplitEnabled && _pagePlan != null)
      ? _pagePlan!.displayPageCount
      : totalImagePages;

  int get totalVisualPages {
    var pages = totalVisualImagePages;
    if (showChapterCommentsAtEnd) pages++;
    return pages;
  }

  int get totalPages => totalVisualPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalVisualImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  int fingers = 0;

  void _initPagePlan() {
    _resolvedSourceIndices.clear();
    _lastVisibleStableIdentity = null;
    _attachedChapter = reader.chapter;
    if (!isSplitEnabled) {
      _pagePlan = null;
      return;
    }
    final wideIndices = <int>[];
    if (reader.images != null) {
      for (int i = 0; i < reader.images!.length; i++) {
        final provider = _createImageProvider(i + 1, context);
        final size = ComicImage.getCachedImageSize(provider);
        if (size != null) {
          _resolvedSourceIndices.add(i);
          if (shouldSplitWideImage(size)) {
            wideIndices.add(i);
          }
        }
      }
    }
    _pagePlan = GalleryPagePlan(
      sourcePageCount: reader.images?.length ?? 0,
      direction: _galleryReadingDirectionOf(reader.mode),
      splitDualPage: isSplitEnabled,
      splitDualPageInvert: _splitDualPageInvert,
      wideSourceIndices: wideIndices,
    );
  }

  int _computeInitialControllerIndex() {
    if (reader.usesGallerySpread && reader.targetLastVisualPage) {
      return totalVisualImagePages;
    }
    if (!isSplitEnabled || _pagePlan == null) {
      return reader.page;
    }
    if (reader.targetLastVisualPage) {
      final lastSourceIndex = (reader.images?.length ?? 0) - 1;
      if (isSourceSizeResolved(lastSourceIndex)) {
        reader.targetLastVisualPage = false;
        final lastVisual = _pagePlan!.sourceIndexToLastVisualIndex(
          lastSourceIndex,
        );
        return lastVisual != -1 ? lastVisual + 1 : _pagePlan!.displayPageCount;
      } else {
        return _pagePlan!.displayPageCount;
      }
    }
    if (reader.isOnChapterCommentsPage || reader.page > reader.maxPage) {
      return totalVisualImagePages + 1;
    }
    final sourceIndex = (reader.page - 1)
        .clamp(0, math.max(0, (reader.images?.length ?? 1) - 1))
        .toInt();
    final firstVisual = _pagePlan!.sourceIndexToFirstVisualIndex(sourceIndex);
    return firstVisual != -1 ? firstVisual + 1 : 1;
  }

  @override
  void initState() {
    reader = context.reader;
    reader.imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
      if (mounted) {
        reader.notifyChapterCompletedIfNeeded();
      }
    });
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_attachedChapter != null) return;
    // Image decode targets depend on MediaQuery, which cannot be read in initState.
    _initPagePlan();
    if (reader.usesGallerySpread) _restoreCachedSpreadSizes();
    final initialPage = _computeInitialControllerIndex();
    _currentControllerIndex = initialPage;
    controller = PageController(initialPage: initialPage);
  }

  @override
  void dispose() {
    if (reader.imageViewController == this) {
      reader.imageViewController = null;
    }
    final commandId = _userPagingCommandId;
    if (commandId != null) reader.finishNavigationCommand(commandId);
    _coalescer.reset();
    _preloader.dispose();
    controller.dispose();
    _endVisualPageAnimation();
    _pool.disposeAll();
    super.dispose();
  }

  void _restoreCachedSpreadSizes() {
    final chapter = reader.chapter;
    final target = _spreadTarget(context, MediaQuery.sizeOf(context));
    for (var index = 0; index < reader.images!.length; index++) {
      final image = _createImageProviderFromKey(
        reader.images![index],
        context,
        index + 1,
        target: target,
      );
      final size = ComicImage.getCachedSourceImageSize(image);
      if (size != null) _pendingSpreadSizes[index] = size;
    }
    if (_pendingSpreadSizes.isNotEmpty) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && reader.chapter == chapter) _applyPendingSpreadSizes();
      });
    }
  }

  ComicImageLoadTarget _spreadTarget(BuildContext context, Size size) =>
      ComicImageLoadTarget(
        logicalWidth: size.width,
        logicalHeight: size.height,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        fit: ComicImageTargetFit.contain,
      );

  ReaderImageProvider _galleryImageProvider(
    int sourcePage,
    BuildContext context,
  ) {
    if (!reader.usesGallerySpread) {
      return _createImageProvider(sourcePage, context);
    }
    final viewport = MediaQuery.sizeOf(context);
    final plan = reader.gallerySpreadPlan!;
    final (start, end) = plan.range(plan.pageForSourcePage(sourcePage));
    final first = _spreadSizes[start];
    final second = _spreadSizes[start + 1];
    final ComicImageLoadTarget target;
    if (end - start == 2 && first != null && second != null) {
      final (firstSlot, secondSlot) = gallerySpreadSizes(
        viewport,
        first,
        second,
      );
      target = _spreadTarget(
        context,
        sourcePage == start + 1 ? firstSlot : secondSlot,
      );
    } else {
      // 未确认宽高比前按单图加载，原图可能独占整屏。
      target = _spreadTarget(context, viewport);
    }
    return _createImageProviderFromKey(
      reader.images![sourcePage - 1],
      context,
      sourcePage,
      target: target,
    );
  }

  void _onSpreadSize(int index, Size size) {
    if (!mounted ||
        !reader.usesGallerySpread ||
        _attachedChapter != reader.chapter) {
      return;
    }
    // 后续解码可能使用适配后的图源目标，始终依据首次尺寸确定该章的排版。
    if (_spreadSizes.containsKey(index) ||
        _pendingSpreadSizes.containsKey(index)) {
      return;
    }
    final schedule = _pendingSpreadSizes.isEmpty;
    _pendingSpreadSizes[index] = size;
    if (!schedule) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyPendingSpreadSizes();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _applyPendingSpreadSizes() {
    if (!reader.usesGallerySpread || _attachedChapter != reader.chapter) return;
    if (controller.hasClients &&
        controller.position.isScrollingNotifier.value) {
      return;
    }
    final sizes = Map<int, Size>.of(_pendingSpreadSizes);
    _pendingSpreadSizes.clear();
    if (sizes.isEmpty) return;
    _spreadSizes.addAll(sizes);
    final changed = reader.applyGallerySpreadImageSizes(sizes);
    if (reader.targetLastVisualPage &&
        _spreadSizes.containsKey(reader.images!.length - 1)) {
      reader.setGallerySpreadSourcePage(reader.images!.length);
      reader.targetLastVisualPage = false;
    }
    if (changed) {
      _endVisualPageAnimation();
      reader.resetPageAnimation();
      _currentControllerIndex = reader.page;
      _lastVisibleStableIdentity = _visibleStableIdentityForIndex(reader.page);
      if (reader.pendingNavigationPage != null) {
        reader.setPendingNavigationPage(reader.page);
      }
      if (controller.hasClients && controller.page?.round() != reader.page) {
        // 新分组可能多出数屏，以新页数挂载，避免旧页数触发跨章占位。
        final previous = controller;
        controller = PageController(initialPage: reader.page, keepPage: false);
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => previous.dispose(),
        );
      }
      context.readerScaffold.updatePage();
    }
    if (reader.page == reader.maxPage && isCurrentSourceSizeResolved()) {
      reader.updateHistory();
    }
    reader.notifyChapterCompletedIfNeeded();
    setState(() {});
  }

  void _onSourceImageSize(int sourceIndex, Size size) {
    if (!mounted || !isSplitEnabled || _pagePlan == null) return;
    final wasResolved = _resolvedSourceIndices.contains(sourceIndex);
    _resolvedSourceIndices.add(sourceIndex);

    final lastSourceIndex = (reader.images?.length ?? 0) - 1;
    final isLastSource = sourceIndex == lastSourceIndex;

    final isWide = shouldSplitWideImage(size);
    final wasWide = _pagePlan!.isWide(sourceIndex);
    final wideChanged = wasWide != isWide;

    if (!wideChanged) {
      if (isLastSource && reader.targetLastVisualPage) {
        reader.targetLastVisualPage = false;
      }
      if (!wasResolved) {
        reader.notifyChapterCompletedIfNeeded();
      }
      return;
    }

    if (!_coalescer.hasPendingUpdates) {
      final current = controller.hasClients && controller.page != null
          ? controller.page!.round()
          : _currentControllerIndex;
      final GalleryVisualLocation loc;
      if (isChapterCommentsPage(current)) {
        loc = const GalleryCommentsLocation();
      } else if (reader.targetLastVisualPage) {
        loc = const GalleryTargetLastVisualLocation();
      } else {
        final currentVisual = (current - 1)
            .clamp(0, math.max(0, _pagePlan!.displayPageCount - 1))
            .toInt();
        loc = GalleryPageLocation(
          stableId:
              _pagePlan!.maybeDisplayPageAt(currentVisual)?.stableId ??
              '$currentVisual:full',
          fallbackVisualIndex: currentVisual,
        );
      }
      _coalescer.recordInitialLocation(loc);
    }

    final isCommentsLocation =
        _coalescer.initialLocation is GalleryCommentsLocation;
    if (shouldRecoverCommentsToFinalVisualHalf(
      isCommentsLocation: isCommentsLocation,
      isLastSource: isLastSource,
      isWide: isWide,
      wasWide: wasWide,
      wasResolved: wasResolved,
    )) {
      _coalescer.markCommentsTailGrowth();
    }

    final modified = _pagePlan!.markWide(sourceIndex, isWide);
    if (!modified) return;

    _scheduleRecovery();
  }

  void _scheduleRecovery() {
    if (_recoveryScheduled) return;
    _recoveryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _recoveryScheduled = false;
      _applyPendingSizeRecovery();
    });
  }

  void _applyPendingSizeRecovery() {
    if (!mounted) return;
    final hadCommentsTailGrowth = _coalescer.hasCommentsTailGrowth;
    final location = _coalescer.flush();
    if (location == null) return;

    final lastSourceIndex = (reader.images?.length ?? 0) - 1;
    final isLastResolved = isSourceSizeResolved(lastSourceIndex);

    if (location is GalleryTargetLastVisualLocation && isLastResolved) {
      reader.targetLastVisualPage = false;
    }

    final targetIndex = resolveRecoveredControllerIndex(
      location: location,
      plan: _pagePlan!,
      isLastSourceResolved: isLastResolved,
      totalVisualImagePages: totalVisualImagePages,
      hasCommentsTailGrowth: hadCommentsTailGrowth,
    );

    _currentControllerIndex = targetIndex;
    if (controller.hasClients && controller.page?.round() != targetIndex) {
      controller.jumpToPage(targetIndex);
    }

    if (location is GalleryCommentsLocation) {
      final recoveryTarget = resolveCommentsRecoveryTarget(
        hasCommentsTailGrowth: hadCommentsTailGrowth,
        totalVisualImagePages: totalVisualImagePages,
        maxPage: reader.maxPage,
      );
      if (hadCommentsTailGrowth) {
        reader.setPageSuppressingCompletion(recoveryTarget.targetReaderPage);
      } else {
        reader.setPage(recoveryTarget.targetReaderPage);
      }
      if (recoveryTarget.notifyChapterCompleted) {
        reader.notifyChapterCompletedIfNeeded();
      }
    } else {
      reader.notifyChapterCompletedIfNeeded();
    }

    setState(() {});
  }

  int controllerIndexToSourcePage(int index) {
    if (isChapterCommentsPage(index)) {
      return reader.maxPage + 1;
    }
    if (isSplitEnabled && _pagePlan != null) {
      final visualIndex = index - 1;
      if (visualIndex >= 0 && visualIndex < _pagePlan!.displayPageCount) {
        return _pagePlan!.visualIndexToSourcePage(visualIndex);
      }
    }
    return index;
  }

  int _sourcePageToControllerIndex(int sourcePage) {
    if (showChapterCommentsAtEnd && sourcePage > reader.maxPage) {
      return totalVisualImagePages + 1;
    }
    if (isSplitEnabled && _pagePlan != null) {
      final sourceIndex = (sourcePage - 1)
          .clamp(0, math.max(0, (reader.images?.length ?? 1) - 1))
          .toInt();
      final visualIndex = _pagePlan!.sourceIndexToFirstVisualIndex(sourceIndex);
      if (visualIndex != -1) {
        return visualIndex + 1;
      }
    }
    return sourcePage;
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    final spreadPlan = reader.gallerySpreadPlan;
    if (spreadPlan != null) return spreadPlan.range(page);
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null ||
        reader.images!.isEmpty ||
        reader.isOnChapterCommentsPage ||
        reader.page > reader.maxPage ||
        reader.page < 1) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void _promoteVisiblePage(int page) {
    if (page <= 0 || page > totalPages || isChapterCommentsPage(page)) return;
    final Iterable<int> sourcePages;
    if (isSplitEnabled && _pagePlan != null) {
      sourcePages = [_pagePlan!.displayPageAt(page - 1).sourceIndex + 1];
    } else {
      final (start, end) = getPageImagesRange(page);
      sourcePages = [for (var i = start; i < end; i++) i + 1];
    }
    for (final sourcePage in sourcePages) {
      _promoteReaderImage(_galleryImageProvider(sourcePage, context));
    }
  }

  void _schedulePreload() {
    _promoteVisiblePage(_currentControllerIndex);
    if (_preloadScheduled) return;
    _preloadScheduled = true;
    // onPageChanged runs halfway through a swipe. Wait for scrolling to stop,
    // then let the visible page resolve its image before background work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadScheduled = false;
      if (!mounted ||
          (controller.hasClients &&
              controller.position.isScrollingNotifier.value)) {
        return;
      }
      final startPage = _currentControllerIndex;
      _promoteVisiblePage(startPage);
      _preloader.update([
        ..._cachePage(startPage + 1),
        ..._cachePage(startPage - 1),
        for (var offset = 2; offset <= preCacheCount; offset++)
          ..._cachePage(startPage + offset),
      ]);
      _preloader.setPaused(false);
      _pool.pruneExcept(
        resolveKeepControllerKeys(
          currentIndex: startPage,
          totalVisualPages: totalVisualPages,
          resolveKeyForIndex: _controllerKeyForIndex,
        ),
      );
    });
  }

  Iterable<ReaderImagePreload> _cachePage(int page) sync* {
    if (page <= 0 || page > totalPages || isChapterCommentsPage(page)) return;
    Iterable<int> sourcePages;
    if (isSplitEnabled && _pagePlan != null) {
      sourcePages = [_pagePlan!.displayPageAt(page - 1).sourceIndex + 1];
    } else {
      final (start, end) = getPageImagesRange(page);
      sourcePages = [for (var i = start; i < end; i++) i + 1];
    }
    for (final sourcePage in sourcePages) {
      final provider = _galleryImageProvider(sourcePage, context);
      yield _createReaderImagePreload(
        provider,
        context,
        onImageSize: reader.usesGallerySpread
            ? (size) => _onSpreadSize(sourcePage - 1, size)
            : null,
      );
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_attachedChapter != reader.chapter) {
      _attachedChapter = reader.chapter;
      _lastVisibleStableIdentity = null;
    }
    _schedulePreload();
    final gallery = Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth != 0) return false;
          if (notification is ScrollStartNotification) {
            _preloader.setPaused(true);
            if (notification.dragDetails != null) {
              if (_isAnimatingVisualPage) {
                _endVisualPageAnimation();
                reader.resetPageAnimation();
              }
              _isUserPaging = true;
              _userPagingCommandId ??= reader.createNavigationCommandId(
                retainObservedProgress: true,
              );
            }
          } else if (notification is ScrollEndNotification) {
            final commandId = _userPagingCommandId;
            if (commandId != null) reader.finishNavigationCommand(commandId);
            _isUserPaging = false;
            _userPagingCommandId = null;
            if (_pendingSpreadSizes.isNotEmpty) {
              SchedulerBinding.instance.addPostFrameCallback((_) {
                if (mounted) _applyPendingSpreadSizes();
              });
            }
            _schedulePreload();
          }
          return false;
        },
        child: PhotoViewGallery.builder(
          key: ValueKey(controller),
          backgroundDecoration: BoxDecoration(
            color: context.colorScheme.surface,
          ),
          reverse: reader.mode == ReaderMode.galleryRightToLeft,
          scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
              ? Axis.vertical
              : Axis.horizontal,
          itemCount: totalVisualPages + 2,
          builder: (BuildContext context, int index) {
            if (index == 0 || index == totalVisualPages + 1) {
              return PhotoViewGalleryPageOptions.customChild(
                child: const SizedBox(),
              );
            } else if (isChapterCommentsPage(index)) {
              return PhotoViewGalleryPageOptions.customChild(
                child: _buildChapterCommentsPage(),
              );
            } else {
              final key = _controllerKeyForIndex(index);
              final photoViewController = _pool.getOrCreate(key);

              if (isSplitEnabled && _pagePlan != null) {
                final visualIndex = index - 1;
                final displayPage = _pagePlan![visualIndex];
                final sourceIndex = displayPage.sourceIndex;
                final part = displayPage.part;
                final imageKey = reader.images![sourceIndex];
                final provider = _createImageProviderFromKey(
                  imageKey,
                  context,
                  sourceIndex + 1,
                );
                final viewportSize = MediaQuery.of(context).size;
                return PhotoViewGalleryPageOptions.customChild(
                  childSize: viewportSize,
                  controller: photoViewController,
                  minScale: PhotoViewComputedScale.contained * 1.0,
                  maxScale: PhotoViewComputedScale.covered * 10.0,
                  child: SizedBox.fromSize(
                    size: viewportSize,
                    child: ComicImage(
                      showDimensions:
                          reader.readerSetting('showImagePixelDimensions') ==
                          true,
                      image: provider,
                      zoomController: photoViewController,
                      onRetry: () => context
                          .findAncestorStateOfType<ReaderImagesState>()!
                          .retryImage(reader.chapter, sourceIndex + 1),
                      wideImagePart: part,
                      onImageSize: (size) =>
                          _onSourceImageSize(sourceIndex, size),
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      onInit: (state) => imageStates.add(state),
                      onDispose: (state) => imageStates.remove(state),
                    ),
                  ),
                );
              }
              var (startIndex, endIndex) = getPageImagesRange(index);
              List<String> pageImages = reader.images!.sublist(
                startIndex,
                endIndex,
              );

              final viewportSize = MediaQuery.of(context).size;
              return PhotoViewGalleryPageOptions.customChild(
                childSize: viewportSize,
                controller: photoViewController,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 10.0,
                child: buildPageImages(
                  pageImages,
                  startIndex,
                  photoViewController,
                ),
              );
            }
          },
          pageController: controller,
          loadingBuilder: (context, event) {
            // Scope inherited dependencies to the placeholder to preserve
            // PhotoView's loaded state when system bars change.
            return Builder(
              builder: (context) => PhotoView.customChild(
                childSize: MediaQuery.of(context).size,
                initialScale: PhotoViewComputedScale.contained,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 10.0,
                backgroundDecoration: BoxDecoration(
                  color: context.colorScheme.surface,
                ),
                child: Center(
                  child: SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(
                      backgroundColor: context.colorScheme.surfaceContainerHigh,
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
              ),
            );
          },
          onPageChanged: (i) {
            final previousIndex = _currentControllerIndex;
            final navigationSource = _isUserPaging
                ? i < previousIndex
                      ? ReadingNavigationSource.userBackward
                      : ReadingNavigationSource.userForward
                : reader.pendingNavigationSource ??
                      ReadingNavigationSource.passive;
            var commandId = _isUserPaging
                ? (_userPagingCommandId ??= reader.createNavigationCommandId(
                    retainObservedProgress: true,
                  ))
                : null;
            if (commandId != null &&
                navigationSource == ReadingNavigationSource.userBackward &&
                commandId == reader.sessionRoundId) {
              commandId = reader.renewNavigationCommand(commandId);
              _userPagingCommandId = commandId;
            }
            _currentControllerIndex = i;
            _schedulePreload();
            var shouldRefresh = false;
            if (i == 0) {
              _lastVisibleStableIdentity = null;
              if (reader.isFirstChapterOfGroup ||
                  !reader.toPrevChapter(
                    toLastPage: true,
                    source: navigationSource,
                  )) {
                reader.cancelPendingNavigation();
                controller.jumpToPage(1);
              } else {
                shouldRefresh = true;
              }
            } else if (i == totalVisualPages + 1) {
              _lastVisibleStableIdentity = null;
              if (reader.isLastChapterOfGroup ||
                  !reader.toNextChapter(source: navigationSource)) {
                reader.cancelPendingNavigation();
                controller.jumpToPage(totalVisualPages);
              } else {
                shouldRefresh = true;
              }
            } else {
              final targetSourcePage = controllerIndexToSourcePage(i);
              if (reader.page != targetSourcePage ||
                  _isUserPaging ||
                  reader.pendingNavigationSource != null) {
                if (targetSourcePage < reader.maxPage) {
                  reader.targetLastVisualPage = false;
                }
                reader.setPage(
                  targetSourcePage,
                  source: navigationSource,
                  commandId: commandId,
                );
              } else {
                reader.notifyChapterCompletedIfNeeded();
              }
              context.readerScaffold.updatePage();

              final currentIdentity = _visibleStableIdentityForIndex(i);
              shouldRefresh = shouldRefreshEInk(
                previousIdentity: _lastVisibleStableIdentity,
                currentIdentity: currentIdentity,
                isCommentsPage: isChapterCommentsPage(i),
              );
              if (currentIdentity != null) {
                _lastVisibleStableIdentity = currentIdentity;
              }

              // Auto close toolbar when entering chapter comments page
              if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
                context.readerScaffold.openOrClose();
              }
            }
            if (shouldRefresh) {
              context.readerScaffold.requestEInkRefresh();
            }
          },
        ),
      ),
    );
    return MouseDragScrollRegion(child: gallery);
  }

  Widget buildPageImages(
    List<String> images,
    int startIndex,
    PhotoViewController zoomController,
  ) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    var entries = buildGalleryPageEntries(
      images: images,
      startIndex: startIndex,
      isRightToLeft: reader.mode == ReaderMode.galleryRightToLeft,
    );

    if (reader.usesGallerySpread) {
      return _buildSpreadImages(entries, zoomController);
    }

    List<Widget> imageWidgets;

    if (entries.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            showDimensions:
                reader.readerSetting('showImagePixelDimensions') == true,
            zoomController: zoomController,
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              entries[0].imageKey,
              context,
              entries[0].sourcePage,
            ),
            onRetry: () => context
                .findAncestorStateOfType<ReaderImagesState>()!
                .retryImage(reader.chapter, entries[0].sourcePage),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            showDimensions:
                reader.readerSetting('showImagePixelDimensions') == true,
            zoomController: zoomController,
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              entries[1].imageKey,
              context,
              entries[1].sourcePage,
            ),
            onRetry: () => context
                .findAncestorStateOfType<ReaderImagesState>()!
                .retryImage(reader.chapter, entries[1].sourcePage),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = entries.map((entry) {
        ImageProvider imageProvider = _createImageProviderFromKey(
          entry.imageKey,
          context,
          entry.sourcePage,
        );
        return Expanded(
          child: ComicImage(
            showDimensions:
                reader.readerSetting('showImagePixelDimensions') == true,
            image: imageProvider,
            zoomController: zoomController,
            width: double.infinity,
            height: double.infinity,
            onRetry: () => context
                .findAncestorStateOfType<ReaderImagesState>()!
                .retryImage(reader.chapter, entry.sourcePage),
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  Widget _buildSpreadImages(
    List<({String imageKey, int sourcePage})> entries,
    PhotoViewController zoomController,
  ) {
    Widget imageForPage(int sourcePage) => ComicImage(
      key: ValueKey(sourcePage),
      showDimensions: reader.readerSetting('showImagePixelDimensions') == true,
      zoomController: zoomController,
      image: _galleryImageProvider(sourcePage, context),
      onRetry: () => context
          .findAncestorStateOfType<ReaderImagesState>()!
          .retryImage(reader.chapter, sourcePage),
      onSourceImageSize: (size) => _onSpreadSize(sourcePage - 1, size),
      gaplessPlayback: true,
      fit: BoxFit.contain,
      onInit: (state) => imageStates.add(state),
      onDispose: (state) => imageStates.remove(state),
    );

    if (entries.length == 1) {
      return SizedBox.expand(child: imageForPage(entries.single.sourcePage));
    }
    final first = entries[0].sourcePage;
    final second = entries[1].sourcePage;
    return LayoutBuilder(
      builder: (context, constraints) {
        final (firstSize, secondSize) = gallerySpreadSizes(
          constraints.biggest,
          _spreadSizes[first - 1],
          _spreadSizes[second - 1],
        );
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          textDirection: TextDirection.ltr,
          children: [
            SizedBox.fromSize(size: firstSize, child: imageForPage(first)),
            SizedBox.fromSize(size: secondSize, child: imageForPage(second)),
          ],
        );
      },
    );
  }

  @override
  bool toNextPage() {
    return _moveVisualPage(1);
  }

  @override
  bool toPrevPage() {
    reader.targetLastVisualPage = false;
    return _moveVisualPage(-1);
  }

  @override
  bool isAtLastVisualPartOfSource() {
    if (reader.usesGallerySpread) return isCurrentSourceSizeResolved();
    if (!isSplitEnabled || _pagePlan == null) return true;
    if (!isCurrentSourceSizeResolved()) return false;
    final current = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    if (isChapterCommentsPage(current)) {
      return isCommentsAtLastVisualPartOfSource(
        isSplitEnabled: isSplitEnabled,
        sourcePageCount: reader.images?.length ?? 0,
        resolvedSourceIndices: _resolvedSourceIndices,
      );
    }
    final visualIndex = current - 1;
    final displayPage = _pagePlan!.maybeDisplayPageAt(visualIndex);
    if (displayPage == null) return false;
    return _pagePlan!.isLastVisualPageOfSource(visualIndex);
  }

  bool _moveVisualPage(int delta) {
    if (!controller.hasClients) return false;
    final current = controller.page?.round() ?? _currentControllerIndex;
    final decision = decideVisualMove(
      isAnimating: reader.isPageAnimating || _isAnimatingVisualPage,
      currentIndex: current,
      pendingTargetIndex: _targetControllerIndex,
      delta: delta,
      totalVisualPages: totalVisualPages,
    );
    if (!decision.consumed) {
      return false;
    }
    final target = decision.targetIndex ?? _targetControllerIndex;
    if (target != null) {
      reader.setPendingNavigationPage(controllerIndexToSourcePage(target));
    }
    if (!decision.canMove || target == null) {
      return true;
    }
    reader.resetPageAnimation();
    if (reader.enablePageAnimation(reader.cid, reader.type)) {
      animateToControllerPage(target);
    } else {
      _endVisualPageAnimation();
      controller.jumpToPage(target);
      _completeVisualPageNavigation(target);
    }
    return true;
  }

  void _endVisualPageAnimation() {
    _visualAnimationGeneration++;
    _targetControllerIndex = null;
    final token = _visualAnimationToken;
    _visualAnimationToken = null;
    if (token != null) reader.endPageAnimation(token);
  }

  void _completeVisualPageNavigation(int target) {
    if (mounted &&
        controller.hasClients &&
        controller.page == target.toDouble() &&
        reader.pendingNavigationSource != null) {
      // Reversing before the first animation frame can return to the same page
      // without a PageView.onPageChanged callback.
      reader.setPage(controllerIndexToSourcePage(target));
    }
  }

  Future<void> animateToControllerPage(int target) async {
    _endVisualPageAnimation();
    _targetControllerIndex = target;
    final generation = _visualAnimationGeneration;
    final token = reader.startPageAnimation();
    _visualAnimationToken = token;
    try {
      final current = controller.hasClients && controller.page != null
          ? controller.page!.round()
          : _currentControllerIndex;
      if ((target - current).abs() > 1) {
        controller.jumpToPage(target > current ? target - 1 : target + 1);
      }
      await controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
      if (generation == _visualAnimationGeneration) {
        _completeVisualPageNavigation(target);
      }
    } finally {
      if (generation == _visualAnimationGeneration) {
        _endVisualPageAnimation();
      }
    }
  }

  @override
  Future<void> animateToPage(int page) {
    if (page < reader.maxPage) {
      reader.targetLastVisualPage = false;
    }
    final target = _sourcePageToControllerIndex(page);
    return animateToControllerPage(target);
  }

  @override
  void toPage(int page) {
    if (page < reader.maxPage) {
      reader.targetLastVisualPage = false;
    }
    _endVisualPageAnimation();
    final target = _sourcePageToControllerIndex(page);
    controller.jumpToPage(target);
    _completeVisualPageNavigation(target);
  }

  @override
  void toVisualEnd() {
    _endVisualPageAnimation();
    if (reader.usesGallerySpread) {
      reader.targetLastVisualPage = !_spreadSizes.containsKey(
        reader.images!.length - 1,
      );
      final end = totalVisualImagePages;
      if (controller.hasClients) {
        controller.jumpToPage(end);
      } else {
        _currentControllerIndex = end;
      }
      reader.setGallerySpreadSourcePage(reader.images!.length);
      reader.setPage(reader.maxPage);
      return;
    }
    final result = resolveVisualEndTarget(
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      sourcePageCount: reader.images?.length ?? 0,
      isLastSourceResolved: isSourceSizeResolved(
        (reader.images?.length ?? 0) - 1,
      ),
      sourcePageToControllerIndex: _sourcePageToControllerIndex,
    );
    reader.targetLastVisualPage = result.retainTargetLastVisualPage;
    if (controller.hasClients) {
      controller.jumpToPage(result.targetIndex);
    } else {
      _currentControllerIndex = result.targetIndex;
    }
    reader.setPage(reader.maxPage);
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    return false;
  }

  bool get canPullToCollect {
    final index = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    final photo = _pool[_controllerKeyForIndex(index)];
    final initial = photo?.getInitialScale?.call();
    return initial != null &&
        ((photo?.scale ?? initial) - initial).abs() < 0.01;
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    final currentIndex = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    final key = _controllerKeyForIndex(currentIndex);
    var controllerForPage = _pool[key];
    final initialScale = controllerForPage?.getInitialScale?.call();
    if (initialScale == null) return;
    final target = controllerForPage!.scale == initialScale
        ? initialScale * 1.75
        : initialScale;
    final size = reader.size;
    controllerForPage.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toNextPage(source: ReadingNavigationSource.userForward);
      } else if (forward == false) {
        reader.toPrevPage(source: ReadingNavigationSource.userBackward);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toNextPage(source: ReadingNavigationSource.userForward);
          } else if (forward == false) {
            reader.toPrevPage(source: ReadingNavigationSource.userBackward);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  ReaderImageProvider? _findProviderByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;

    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        final image = imageState.widget.image;
        if (image is ReaderImageProvider) {
          final index = image.page - 1;
          if (index >= startIndex && index < endIndex) {
            return image;
          }
        }
      }
    }
    return null;
  }

  @override
  ReaderImageReference? getImageReferenceByOffset(Offset offset) {
    final provider = _findProviderByOffset(offset);
    if (provider != null) {
      return createReaderImageReferenceFromProvider(
        provider,
        fallbackSourceKey: reader.type.comicSource?.key,
        fallbackChapter: reader.chapter,
      );
    }
    final imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    final int? page = (reader.images?.indexOf(imageKey) ?? -1) >= 0
        ? reader.images!.indexOf(imageKey) + 1
        : null;
    final File? file = imageKey.startsWith("file://")
        ? File(imageKey.substring(7))
        : null;
    return ReaderImageReference(
      imageKey: imageKey,
      sourceKey: reader.type.comicSource?.key,
      cid: reader.cid,
      eid: reader.eid,
      chapter: reader.chapter,
      page: page,
      file: file,
    );
  }

  @override
  ReaderImageReference? getImageReferenceByIndex(int index) {
    if (index < 0 || index >= (reader.images?.length ?? 0)) return null;
    final imageKey = reader.images![index];
    final File? file = imageKey.startsWith("file://")
        ? File(imageKey.substring(7))
        : null;
    return ReaderImageReference(
      imageKey: imageKey,
      sourceKey: reader.type.comicSource?.key,
      cid: reader.cid,
      eid: reader.eid,
      chapter: reader.chapter,
      page: index + 1,
      file: file,
    );
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    final ref = getImageReferenceByOffset(offset);
    if (ref == null) return null;
    if (ref.file != null) {
      if (await ref.file!.exists()) {
        return await ref.file!.readAsBytes();
      }
      return null;
    }
    return await ImageDownloader.loadComicImageBytes(
      ref.imageKey,
      ref.sourceKey,
      ref.cid,
      ref.eid,
      target: null,
    );
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const double _kChangeChapterOffset = 160;

@visibleForTesting
class ContinuousMode extends StatefulWidget {
  const ContinuousMode({super.key, this.crossChapter = false});

  final bool crossChapter;

  @override
  State<ContinuousMode> createState() => ContinuousModeState();
}

typedef _ContinuousMode = ContinuousMode;

class ContinuousModeState extends State<_ContinuousMode>
    implements
        ReaderImageViewController,
        AutoReadingViewport,
        AutoReadingImageViewport {
  bool _isUserScrolling = false;
  String? _userScrollCommandId;
  Timer? _userScrollEndTimer;
  late ReaderState reader;
  late final bool _initiallyAtChapterEnd;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  double? _viewportTurnTarget;
  Future<void>? _viewportTurnAnimation;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  final _preloader = ReaderImagePreloader();

  final _waterfallFlow = WaterfallChapterFlow();

  bool _isLoadingNextSegment = false;

  bool _isLoadingPrevSegment = false;

  bool _isRestoringPrependedSegmentPosition = false;

  bool _isNavigatingWaterfallLocation = false;

  int _waterfallRequestGeneration = 0;

  Completer<void>? _waterfallScrollIdle;

  String? _nextSegmentError;

  int get preCacheCount => reader.readerSetting('preloadImageCount');

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;
  final _delayedScrollingTimers = <Timer>{};

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 300), () {
      _delayedScrollingTimers.remove(timer);
      delayedIsScrolling = value;
    });
    _delayedScrollingTimers.add(timer);
  }

  void _beginUserScroll({bool endWhenIdle = false}) {
    _isUserScrolling = true;
    _userScrollCommandId ??= reader.createNavigationCommandId(
      retainObservedProgress: true,
    );
    _userScrollEndTimer?.cancel();
    _userScrollEndTimer = endWhenIdle
        ? Timer(const Duration(milliseconds: 250), _endUserScroll)
        : null;
  }

  void _finishUserScrollAfterLayout() {
    if (!_isUserScrolling) return;
    final commandId = _userScrollCommandId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _userScrollCommandId != commandId ||
          _viewportTurnTarget != null) {
        return;
      }
      if (_scrollController?.hasClients == true &&
          scrollController.position.isScrollingNotifier.value) {
        return;
      }
      // Item positions are delivered after layout, including the final drag
      // position. Keep the input observation until that position is recorded.
      if (reader.pendingNavigationSource == null) onPositionChanged();
      _endUserScroll();
    });
  }

  void _endUserScroll() {
    _userScrollEndTimer?.cancel();
    _userScrollEndTimer = null;
    final commandId = _userScrollCommandId;
    if (commandId != null) reader.finishNavigationCommand(commandId);
    _isUserScrolling = false;
    _userScrollCommandId = null;
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool get crossChapter => widget.crossChapter;

  bool get _splitWideImages =>
      reader.mode.isTopToBottom &&
      appdata.settings.getReaderSetting(
            reader.cid,
            reader.type.sourceKey,
            'splitDualPage',
          ) ==
          true;

  bool get _splitWideImagesInvert =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPageInvert',
      ) ==
      true;

  int get _flowImageCount =>
      crossChapter ? _waterfallFlow.imageCount : reader.maxPage;

  int get _flowItemCount => _flowImageCount + 2;

  void _initSegments() {
    if (!crossChapter || !_waterfallFlow.isEmpty || reader.images == null) {
      return;
    }
    _waterfallFlow.addAfter(
      WaterfallChapterSegment(
        chapter: reader.chapter,
        eid: reader.eid,
        images: reader.images!,
      ),
    );
  }

  WaterfallChapterSegment? _segmentOfChapter(int chapter) {
    return _waterfallFlow.segmentOfChapter(chapter);
  }

  WaterfallImageRef? _imageRefAt(int index) {
    if (!crossChapter) {
      if (index <= 0 || index > reader.images!.length) return null;
      return WaterfallImageRef(
        chapter: reader.chapter,
        page: index,
        eid: reader.eid,
        imageKey: reader.images![index - 1],
        isFirstInSegment: index == 1,
      );
    }
    return _waterfallFlow.imageRefAt(index);
  }

  Future<List<String>> _loadChapterImages(int chapter) {
    return loadReaderChapterImages(
      comicId: reader.cid,
      type: reader.type,
      chapter: chapter,
      chapters: reader.widget.chapters,
      onOnlineFallback: reader.onLocalChapterRecoveredOnline,
    );
  }

  bool _isCurrentWaterfallRequest(int generation) =>
      mounted &&
      generation == _waterfallRequestGeneration &&
      reader.imageViewController == this;

  int _invalidateWaterfallRequests() {
    _viewportTurnTarget = null;
    _waterfallRequestGeneration++;
    final idle = _waterfallScrollIdle;
    _waterfallScrollIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
    _isLoadingPrevSegment = false;
    _isLoadingNextSegment = false;
    _isRestoringPrependedSegmentPosition = false;
    _isNavigatingWaterfallLocation = false;
    return _waterfallRequestGeneration;
  }

  Future<bool> _waitForWaterfallScrollIdle(int generation) async {
    while (_isCurrentWaterfallRequest(generation)) {
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return false;
      final scrolling = controller.position.isScrollingNotifier;
      if (scrolling.value) {
        final idle = Completer<void>();
        _waterfallScrollIdle = idle;
        void changed() {
          if (!scrolling.value && !idle.isCompleted) idle.complete();
        }

        scrolling.addListener(changed);
        try {
          await idle.future;
        } finally {
          scrolling.removeListener(changed);
          if (identical(_waterfallScrollIdle, idle)) {
            _waterfallScrollIdle = null;
          }
        }
      }
      if (!_isCurrentWaterfallRequest(generation)) return false;
      // 等最后一次拖动完成布局，也跳过拖动转惯性滚动时的短暂空闲。
      final layout = Completer<void>();
      _waterfallScrollIdle = layout;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!layout.isCompleted) layout.complete();
      });
      SchedulerBinding.instance.scheduleFrame();
      try {
        await layout.future;
      } finally {
        if (identical(_waterfallScrollIdle, layout)) {
          _waterfallScrollIdle = null;
        }
      }
      if (!_isCurrentWaterfallRequest(generation)) return false;
      if (_scrollController?.hasClients != true) return false;
      if (!scrollController.position.isScrollingNotifier.value) return true;
    }
    return false;
  }

  Future<void> _ensureWaterfallImagesAfter(int current) async {
    if (!crossChapter ||
        _isNavigatingWaterfallLocation ||
        _isLoadingNextSegment ||
        _nextSegmentError != null) {
      return;
    }
    _initSegments();
    var threshold = math.max(preCacheCount, 1);
    if (!_waterfallFlow.shouldLoadAfter(
      current: current,
      threshold: threshold,
      maxChapter: reader.maxChapter,
      isLastChapter: reader.isLastChapterOfGroupFor,
    )) {
      return;
    }
    var nextChapter = _waterfallFlow.lastChapter! + 1;
    final generation = _waterfallRequestGeneration;
    setState(() => _isLoadingNextSegment = true);
    var loaded = false;
    try {
      var images = await _loadChapterImages(nextChapter);
      if (!_isCurrentWaterfallRequest(generation)) return;
      setState(() {
        _waterfallFlow.addAfter(
          WaterfallChapterSegment(
            chapter: nextChapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(nextChapter - 1) ??
                '0',
            images: images,
          ),
        );
        _nextSegmentError = null;
      });
      loaded = true;
    } catch (e) {
      if (!_isCurrentWaterfallRequest(generation)) return;
      setState(() => _nextSegmentError = e.toString());
    } finally {
      if (_isCurrentWaterfallRequest(generation)) {
        setState(() => _isLoadingNextSegment = false);
        if (loaded && _flowImageCount - current < threshold) {
          _ensureWaterfallImagesAfter(current);
        }
      }
    }
  }

  Future<void> _ensureWaterfallImagesBefore(int current) async {
    if (!crossChapter ||
        _isNavigatingWaterfallLocation ||
        _isLoadingPrevSegment) {
      return;
    }
    _initSegments();
    var threshold = math.max(preCacheCount, 1);
    if (!_waterfallFlow.shouldLoadBefore(
      current: current,
      threshold: threshold,
      isFirstChapter: reader.isFirstChapterOfGroupFor,
    )) {
      return;
    }
    var prevChapter = _waterfallFlow.firstChapter! - 1;
    final generation = _waterfallRequestGeneration;
    _isLoadingPrevSegment = true;
    try {
      var images = await _loadChapterImages(prevChapter);
      if (!await _waitForWaterfallScrollIdle(generation) ||
          !_isCurrentWaterfallRequest(generation)) {
        return;
      }
      ItemPosition? anchor;
      for (final item in itemPositionsListener.itemPositions.value) {
        if (_imageRefAt(item.index) != null &&
            item.itemTrailingEdge > 0 &&
            item.itemLeadingEdge < 1 &&
            (anchor == null || item.index < anchor.index)) {
          anchor = item;
        }
      }
      if (anchor == null) return;
      // 请求期间用户可能已滚到另一页，以插入前的真实图片和部分偏移为准。
      final anchorRef = _imageRefAt(anchor.index)!;
      final alignment = anchor.itemLeadingEdge;
      _isRestoringPrependedSegmentPosition = true;
      setState(() {
        _waterfallFlow.addBefore(
          WaterfallChapterSegment(
            chapter: prevChapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(prevChapter - 1) ??
                '0',
            images: images,
          ),
        );
      });
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrentWaterfallRequest(generation)) return;
        final index = _waterfallIndexOfChapterPage(
          anchorRef.chapter,
          anchorRef.page,
        )!;
        itemScrollController.jumpTo(index: index, alignment: alignment);
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_isCurrentWaterfallRequest(generation)) return;
          _isRestoringPrependedSegmentPosition = false;
        });
      });
    } catch (e) {
      if (!_isCurrentWaterfallRequest(generation)) return;
      _isRestoringPrependedSegmentPosition = false;
      Log.error("Reader", "Failed to load previous chapter", e);
    } finally {
      if (_isCurrentWaterfallRequest(generation)) {
        _isLoadingPrevSegment = false;
      }
    }
  }

  void _setReaderLocation(
    WaterfallImageRef imageRef, {
    required ReadingNavigationSource source,
    String? commandId,
    bool navigationCompleted = false,
  }) {
    var segment = _segmentOfChapter(imageRef.chapter);
    var chapterChanged = reader.chapter != imageRef.chapter;
    if (segment != null && chapterChanged) {
      reader.flushRemoteProgress();
      reader.chapter = imageRef.chapter;
      reader.images = segment.images;
    }
    if (chapterChanged || reader.page != imageRef.page || navigationCompleted) {
      reader.setPage(
        imageRef.page,
        source: source,
        commandId: commandId,
        navigationCompleted: navigationCompleted,
      );
    }
  }

  int? _waterfallIndexOfChapterPage(int chapter, int page) {
    if (!crossChapter) return page;
    return _waterfallFlow.imageIndexOf(chapter: chapter, page: page);
  }

  Future<bool> _loadWaterfallNavigationChapter(
    int chapter,
    int generation,
  ) async {
    if (_segmentOfChapter(chapter) != null) return true;
    try {
      var images = await _loadChapterImages(chapter);
      if (!_isCurrentWaterfallRequest(generation)) return false;
      if (images.isEmpty) return false;
      setState(() {
        _waterfallFlow.reset(
          WaterfallChapterSegment(
            chapter: chapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0',
            images: images,
          ),
        );
        _nextSegmentError = null;
      });
      return true;
    } catch (e) {
      if (!_isCurrentWaterfallRequest(generation)) return false;
      Log.error("Reader", "Failed to load chapter $chapter", e);
      context.showMessage(message: e.toString());
      return false;
    }
  }

  Future<void> _navigateToWaterfallChapter(
    int chapter, {
    required bool toLastPage,
  }) async {
    final generation = _invalidateWaterfallRequests();
    _isNavigatingWaterfallLocation = true;
    final needsLoading = _segmentOfChapter(chapter) == null;
    if (needsLoading) {
      reader.onReaderContentLoading(keepImageViewController: true);
    }
    try {
      if (!await _loadWaterfallNavigationChapter(chapter, generation) ||
          !_isCurrentWaterfallRequest(generation)) {
        if (_isCurrentWaterfallRequest(generation)) {
          _isNavigatingWaterfallLocation = false;
        }
        return;
      }
    } finally {
      if (_isCurrentWaterfallRequest(generation)) {
        if (needsLoading) reader.onReaderContentReady();
        reader.imageViewController ??= this;
      }
    }
    if (!_isCurrentWaterfallRequest(generation)) return;
    reader.imageViewController = this;
    var segment = _segmentOfChapter(chapter);
    if (segment == null || segment.images.isEmpty) {
      _isNavigatingWaterfallLocation = false;
      return;
    }
    var page = toLastPage ? segment.images.length : 1;
    var index = _waterfallIndexOfChapterPage(chapter, page);
    if (index == null) return;
    var imageRef = _imageRefAt(index);
    if (imageRef == null) return;
    setState(() {
      reader.chapter = chapter;
      reader.images = segment.images;
      reader.pageValue = page;
      reader.jumpToLastPageOnLoad = false;
    });
    context.readerScaffold.update();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentWaterfallRequest(generation)) return;
      itemScrollController.jumpTo(index: index);
      _futurePosition = null;
      cacheImages(index);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrentWaterfallRequest(generation)) return;
        final positions = itemPositionsListener.itemPositions.value;
        if (positions.isNotEmpty) {
          final actualIndex = resolveFlowCurrentImageIndex(
            visibleIndex: positions.first.index,
            imageCount: _flowImageCount,
            isTopToBottom: reader.mode.isTopToBottom,
            isAtScrollEnd: _isAtScrollEnd,
          );
          final actualRef = _imageRefAt(actualIndex);
          if (actualRef?.chapter == chapter) {
            _setReaderLocation(
              actualRef!,
              source:
                  reader.pendingNavigationSource ??
                  ReadingNavigationSource.passive,
            );
          }
        }
        _isNavigatingWaterfallLocation = false;
      });
    });
  }

  @override
  void initState() {
    reader = context.reader;
    _initiallyAtChapterEnd =
        reader.mode.isTopToBottom &&
        !crossChapter &&
        reader.targetLastVisualPage;
    reader.targetLastVisualPage = false;
    reader.imageViewController = this;
    _initSegments();
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    super.initState();
  }

  @override
  void dispose() {
    _invalidateWaterfallRequests();
    if (reader.imageViewController == this) {
      reader.imageViewController = null;
    }
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    _endUserScroll();
    for (final timer in _delayedScrollingTimers) {
      timer.cancel();
    }
    _delayedScrollingTimers.clear();
    _preloader.dispose();
    super.dispose();
  }

  void _promoteVisibleImages() {
    for (final position in itemPositionsListener.itemPositions.value) {
      if (position.itemLeadingEdge >= 1 || position.itemTrailingEdge <= 0) {
        continue;
      }
      final imageRef = _imageRefAt(position.index);
      if (imageRef != null) {
        _promoteReaderImage(_createImageProviderFromRef(imageRef, context));
      }
    }
  }

  void onPositionChanged() {
    _promoteVisibleImages();
    if (itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    var page = resolveFlowCurrentImageIndex(
      visibleIndex: itemPositionsListener.itemPositions.value.first.index,
      imageCount: _flowImageCount,
      isTopToBottom: reader.mode.isTopToBottom,
      isAtScrollEnd: _isAtScrollEnd,
    );
    var imageRef = _imageRefAt(page);
    if (imageRef == null) return;
    // A scroll target near the tail can be visible even though the flow's
    // current image resolves to the last image. Acknowledge only that
    // rendered target, not an intermediate animation position.
    final pendingPage = reader.pendingNavigationPage;
    final pendingChapter = reader.pendingNavigationChapter ?? reader.chapter;
    final targetIndex = pendingPage == null
        ? null
        : _waterfallIndexOfChapterPage(pendingChapter, pendingPage);
    final navigationCompleted =
        targetIndex != null &&
        imageRef.chapter == pendingChapter &&
        _isAtScrollEnd &&
        itemPositionsListener.itemPositions.value.any(
          (position) =>
              position.index == targetIndex &&
              position.itemLeadingEdge < 1 &&
              position.itemTrailingEdge > 0,
        );
    final movedBackward =
        imageRef.chapter < reader.chapter ||
        (imageRef.chapter == reader.chapter && imageRef.page < reader.page);
    final source = _isUserScrolling
        ? movedBackward
              ? ReadingNavigationSource.userBackward
              : ReadingNavigationSource.userForward
        : reader.pendingNavigationSource ?? ReadingNavigationSource.passive;
    var commandId = _isUserScrolling
        ? (_userScrollCommandId ??= reader.createNavigationCommandId(
            retainObservedProgress: true,
          ))
        : null;
    if (commandId != null &&
        source == ReadingNavigationSource.userBackward &&
        commandId == reader.sessionRoundId) {
      commandId = reader.renewNavigationCommand(commandId);
      _userScrollCommandId = commandId;
    }
    if (crossChapter) {
      if (_isRestoringPrependedSegmentPosition ||
          _isNavigatingWaterfallLocation) {
        return;
      }
      final chapterChanged = reader.chapter != imageRef.chapter;
      final pageChanged = reader.page != imageRef.page;
      _setReaderLocation(
        imageRef,
        source: source,
        commandId: commandId,
        navigationCompleted: navigationCompleted,
      );
      if (chapterChanged) {
        context.readerScaffold.update();
      } else if (pageChanged || navigationCompleted) {
        context.readerScaffold.updatePage();
      }
    } else if (page != reader.page || navigationCompleted) {
      reader.setPage(
        page,
        source: source,
        commandId: commandId,
        navigationCompleted: navigationCompleted,
      );
      context.readerScaffold.updatePage();
    }
    cacheImages(page);
    if (crossChapter) {
      _ensureWaterfallImagesBefore(page);
      _ensureWaterfallImagesAfter(page);
    }
  }

  bool get _isAtScrollEnd {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) {
      return false;
    }
    final position = controller.position;
    return position.pixels >= position.maxScrollExtent - 1;
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    _viewportTurnTarget = null;
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      _beginUserScroll(endWhenIdle: true);
      smoothTo(event.scrollDelta.dy);
    }
  }

  void cacheImages(int current) {
    if (!mounted) return;
    _promoteVisibleImages();
    if (itemPositionsListener.itemPositions.value.isEmpty) {
      final imageRef = _imageRefAt(current);
      if (imageRef != null) {
        _promoteReaderImage(_createImageProviderFromRef(imageRef, context));
      }
    }
    _preloader.update([
      ..._cachePage(current + 1),
      ..._cachePage(current - 1),
      for (var offset = 2; offset <= preCacheCount; offset++)
        ..._cachePage(current + offset),
    ]);
  }

  Iterable<ReaderImagePreload> _cachePage(int page) sync* {
    final imageRef = _imageRefAt(page);
    if (imageRef == null) return;
    yield _createReaderImagePreload(
      _createImageProviderFromRef(imageRef, context),
      context,
    );
  }

  Widget _buildFlowEnd(BuildContext context) {
    if (!crossChapter) return const SizedBox();
    if (_isLoadingNextSegment) {
      return SizedBox(
        height: 96,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Flexible(child: Text('Loading next chapter'.tl)),
            ],
          ),
        ),
      );
    }
    if (_nextSegmentError != null) {
      return ClickInkWell(
        onTap: () {
          setState(() => _nextSegmentError = null);
          _ensureWaterfallImagesAfter(_flowImageCount);
        },
        child: SizedBox(
          height: 120,
          child: Center(
            child: Text(
              '${'Failed to load next chapter'.tl}\n${'Tap to retry'.tl}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    var lastChapter = !_waterfallFlow.isEmpty
        ? _waterfallFlow.lastChapter!
        : reader.chapter;
    if (reader.isLastChapterOfGroupFor(lastChapter)) {
      return SizedBox(
        height: 96,
        child: Center(child: Text('No more chapters'.tl)),
      );
    }
    return const SizedBox(height: 48);
  }

  String _chapterTitle(int chapter) {
    return reader.widget.chapters?.titles.elementAtOrNull(chapter - 1) ??
        '${'Chapter'.tl} $chapter';
  }

  Widget _buildChapterDivider(
    BuildContext context,
    WaterfallImageRef imageRef,
  ) {
    if (!crossChapter || !imageRef.isFirstInSegment) {
      return const SizedBox();
    }
    var isInitialChapter = imageRef.chapter == _waterfallFlow.firstChapter;
    if (isInitialChapter) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.colorScheme.surfaceContainerHighest.toOpacity(0.72),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: context.colorScheme.outlineVariant.toOpacity(0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Text(
              'Continue to @chapter'.tlParams({
                'chapter': _chapterTitle(imageRef.chapter),
              }),
              style: TextStyle(
                color: context.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onScroll() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - _kChangeChapterOffset;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + _kChangeChapterOffset;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    _viewportTurnTarget = null;
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _waterfallIndexOfChapterPage(reader.chapter, reader.page);
      if (current != null) cacheImages(current);
    });
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: _initiallyAtChapterEnd
          ? _flowImageCount + 1
          : reader.page,
      initialAlignment: _initiallyAtChapterEnd ? 1 : 0,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        _viewportTurnTarget = null;
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: _flowItemCount,
      addSemanticIndexes: false,
      scrollDirection: reader.mode.isTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const SizedBox();
        }
        if (index == _flowImageCount + 1) {
          return _buildFlowEnd(context);
        }
        var imageRef = _imageRefAt(index);
        if (imageRef == null) {
          return const SizedBox();
        }
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = _createImageProviderFromRef(imageRef, context);

        var comicImage = ComicImage(
          showDimensions:
              reader.readerSetting('showImagePixelDimensions') == true,
          filterQuality: FilterQuality.medium,
          image: image,
          zoomController: photoViewController,
          onRetry: () => context
              .findAncestorStateOfType<ReaderImagesState>()!
              .retryImage(imageRef.chapter, imageRef.page),
          width: width,
          height: height,
          fit: BoxFit.contain,
          splitWideImage: _splitWideImages,
          splitWideImageInvert: _splitWideImagesInvert,
          onInit: (state) => imageStates.add(state),
          onDispose: (state) => imageStates.remove(state),
        );

        return ColoredBox(
          color: context.colorScheme.surface,
          child: reader.mode.isTopToBottom
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildChapterDivider(context, imageRef),
                    comicImage,
                  ],
                )
              : comicImage,
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (jumpToPrevChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toPrevChapter(
              toLastPage: true,
              source: ReadingNavigationSource.userBackward,
            );
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toNextChapter(source: ReadingNavigationSource.userForward);
          }
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          _beginUserScroll(endWhenIdle: true);
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode.isTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
          if (notification.dragDetails != null) {
            _viewportTurnTarget = null;
            _beginUserScroll();
          }
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
          if (_userScrollEndTimer == null) {
            _finishUserScrollAfterLayout();
          }
        }
        var scale = photoViewController.scale ?? 1.0;
        if (notification is ScrollUpdateNotification &&
            notification.dragDetails != null &&
            (scale - 1).abs() < 0.05) {
          _beginUserScroll();
        }

        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup &&
              !crossChapter) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup &&
              !crossChapter) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }

        return true;
      },
      child: widget,
    );
    final safeSize = _getSafeReaderViewportSize(context, reader);
    final limitImageWidth =
        appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'limitImageWidth',
        ) ==
        true;
    final rawMargin = appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'readerSideMargin',
    );
    final readerSideMargin = rawMargin is num && rawMargin.isFinite
        ? rawMargin
        : 0;
    final contentSize = calculateReaderContentSize(
      mode: reader.mode,
      viewportSize: safeSize,
      limitImageWidth: limitImageWidth,
      readerSideMargin: readerSideMargin,
    );
    final width = contentSize.width;
    final height = contentSize.height;
    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: contentSize,
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    _invalidateWaterfallRequests();
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    return itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  bool get canPullToCollect => photoViewController.scale == 1;

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void toPage(int page) {
    _invalidateWaterfallRequests();
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    itemScrollController.jumpTo(index: index);
    _futurePosition = null;
  }

  @override
  void toVisualEnd() => toPage(reader.maxPage);

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    if (!crossChapter) return false;
    _navigateToWaterfallChapter(chapter, toLastPage: toLastPage);
    return true;
  }

  bool get supportsViewportTurns => reader.mode.isTopToBottom;

  bool turnViewport({required bool forward}) {
    if (reader.isLoading ||
        !reader.canAcceptReaderPageChanges ||
        reader.isPageAnimating ||
        _isRestoringPrependedSegmentPosition ||
        _isNavigatingWaterfallLocation ||
        fingers > 0 ||
        _scrollController?.hasClients != true) {
      return true;
    }
    final position = scrollController.position;
    if (!position.hasContentDimensions || position.viewportDimension <= 0) {
      return true;
    }

    final min = position.minScrollExtent;
    final max = position.maxScrollExtent;
    final current = position.pixels.clamp(min, max);
    final direction = forward ? 1.0 : -1.0;
    final scale = (photoViewController.scale ?? 1.0).clamp(1.0, 2.5);
    final distance = position.viewportDimension * 0.9;
    final base = (_viewportTurnTarget ?? current).clamp(min, max);
    final target = (base + direction * distance / scale).clamp(min, max);

    if ((target - base).abs() <= 0.5) {
      if (position.isScrollingNotifier.value || (base - current).abs() > 0.5) {
        return true;
      }
      // 放大时，先走完列表到边界后仍能看到的内容，再切换章节。
      final zoomOverflow = position.viewportDimension * (scale - 1) / 2;
      final pan = photoViewController.position;
      final remaining = zoomOverflow + direction * pan.dy;
      if (remaining > 0.5) {
        photoViewController.updateMultiple(
          position: pan.translate(
            0,
            -direction * math.min(distance, remaining),
          ),
        );
        return true;
      }
      for (final state in imageStates.whereType<ComicImageState>()) {
        if (state.visibleInReader &&
            state.autoReadingImageState == AutoReadingImageState.loading) {
          return true;
        }
      }
      if (crossChapter) {
        if (forward) {
          _ensureWaterfallImagesAfter(_flowImageCount);
        } else {
          _ensureWaterfallImagesBefore(1);
        }
        return true;
      }
      if (forward) {
        return reader.toNextChapter(
          source: ReadingNavigationSource.userForward,
        );
      }
      final moved = reader.toPrevChapter(
        toLastPage: true,
        source: ReadingNavigationSource.userBackward,
      );
      if (moved) reader.targetLastVisualPage = true;
      return moved;
    }

    reader.cancelPendingNavigation();
    _beginUserScroll();
    _futurePosition = null;
    if (reader.enablePageAnimation(reader.cid, reader.type)) {
      _viewportTurnTarget = target;
      final animation = position.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
      _viewportTurnAnimation = animation;
      unawaited(
        animation.then((_) {
          if (!mounted || !identical(_viewportTurnAnimation, animation)) return;
          _viewportTurnAnimation = null;
          if (_viewportTurnTarget == null) return;
          _viewportTurnTarget = null;
          _finishUserScrollAfterLayout();
        }),
      );
    } else {
      position.jumpTo(target);
      _viewportTurnTarget = null;
      _finishUserScrollAfterLayout();
    }
    return true;
  }

  @override
  bool toNextPage() => false;

  @override
  bool toPrevPage() => false;

  @override
  bool isAtLastVisualPartOfSource() => true;

  @override
  bool isCurrentSourceSizeResolved() => true;

  @override
  bool isReadyForChapter(int chapter) => mounted;

  @override
  AutoReadingImageReadiness get autoReadingImages =>
      _visibleAutoReadingImages(imageStates);

  @override
  bool get autoReadingReady {
    final controller = _scrollController;
    if (controller == null ||
        !controller.hasClients ||
        fingers > 0 ||
        _isRestoringPrependedSegmentPosition ||
        _isNavigatingWaterfallLocation ||
        controller.position.isScrollingNotifier.value) {
      return false;
    }
    final visible = imageStates
        .whereType<ComicImageState>()
        .where((image) => image.visibleInReader)
        .toList();
    return visible.isNotEmpty &&
        (reader.readerSetting('autoReadingSkipUnavailableImages') == true ||
            visible.every((image) => image.readyForAutoReading));
  }

  @override
  AutoReadingStep autoScroll(double distance, {required bool acrossChapters}) {
    if (!autoReadingReady) return AutoReadingStep.waiting;
    final position = scrollController.position;
    final scale = (photoViewController.scale ?? 1.0).clamp(1.0, 2.5);
    final pan = photoViewController.position;
    final direction = reader.mode == ReaderMode.continuousRightToLeft
        ? -1.0
        : 1.0;
    final panAlongAxis = reader.mode.isTopToBottom ? pan.dy : pan.dx;
    final zoomOverflow = position.viewportDimension * (scale - 1) / 2;
    final lastIndex = crossChapter && !acrossChapters
        ? _waterfallIndexOfChapterPage(reader.chapter, reader.maxPage)
        : _flowImageCount;
    final last = lastIndex == null
        ? null
        : itemPositionsListener.itemPositions.value
              .where((item) => item.index == lastIndex)
              .firstOrNull;
    var available = position.maxScrollExtent - position.pixels;
    double? remaining;
    if (last != null) {
      remaining =
          (last.itemTrailingEdge - 1) * position.viewportDimension * scale +
          zoomOverflow +
          direction * panAlongAxis;
      available = math.min(available, math.max(0.0, remaining / scale));
      if (remaining <= 0.5) {
        if (crossChapter &&
            acrossChapters &&
            _waterfallFlow.lastChapter != null &&
            !reader.isLastChapterOfGroupFor(_waterfallFlow.lastChapter!)) {
          if (_nextSegmentError != null) return AutoReadingStep.finished;
          _ensureWaterfallImagesAfter(_flowImageCount);
          return AutoReadingStep.waiting;
        }
        if (!crossChapter && acrossChapters && !reader.isLastChapterOfGroup) {
          reader.toNextChapter(source: ReadingNavigationSource.automatic);
          return AutoReadingStep.waiting;
        }
        return AutoReadingStep.finished;
      }
    }
    if (available <= 0) {
      final tail = math.min(
        remaining ?? 0.0,
        zoomOverflow + direction * panAlongAxis,
      );
      if (tail <= 0.5) return AutoReadingStep.waiting;
      final shift = math.min(distance, tail) * direction;
      photoViewController.updateMultiple(
        position: reader.mode.isTopToBottom
            ? pan.translate(0, -shift)
            : pan.translate(-shift, 0),
      );
      return AutoReadingStep.advanced;
    }
    _futurePosition = null;
    _viewportTurnTarget = null;
    reader.beginNavigationCommand(
      ReadingNavigationSource.automatic,
      chapter: reader.chapter,
    );
    scrollController.jumpTo(
      position.pixels + math.min(distance / scale, available),
    );
    return AutoReadingStep.advanced;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    if (reader.mode.isTopToBottom) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.pageDown) {
        reader.toNextPage();
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.pageUp) {
        reader.toPrevPage();
      }
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling && _viewportTurnTarget == null) {
      return true;
    }
    return false;
  }

  ReaderImageProvider? _findProviderByOffset(Offset offset) {
    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        final image = imageState.widget.image;
        if (image is ReaderImageProvider) {
          return image;
        }
      }
    }
    return null;
  }

  WaterfallImageRef? _currentWaterfallImageRef() {
    final page = reader.page;
    if (page < 1) return null;
    final globalIndex = _waterfallIndexOfChapterPage(reader.chapter, page);
    if (globalIndex == null) return null;
    return _imageRefAt(globalIndex);
  }

  @override
  ReaderImageReference? getImageReferenceByOffset(Offset offset) {
    final provider = _findProviderByOffset(offset);
    if (provider != null) {
      return createReaderImageReferenceFromProvider(
        provider,
        fallbackSourceKey: reader.type.comicSource?.key,
        fallbackChapter: reader.chapter,
        segments: crossChapter ? _waterfallFlow.segments : null,
      );
    }
    final imageKey = getImageKeyByOffset(offset);
    if (imageKey != null) {
      final file = imageKey.startsWith("file://")
          ? File(imageKey.substring(7))
          : null;
      final ref = _currentWaterfallImageRef();
      return ReaderImageReference(
        imageKey: imageKey,
        sourceKey: reader.type.comicSource?.key,
        cid: reader.cid,
        eid: ref?.eid ?? reader.eid,
        chapter: ref?.chapter ?? reader.chapter,
        page: ref?.page ?? reader.page,
        file: file,
      );
    }
    final ref = _currentWaterfallImageRef();
    if (ref != null) {
      final file = ref.imageKey.startsWith("file://")
          ? File(ref.imageKey.substring(7))
          : null;
      return ReaderImageReference(
        imageKey: ref.imageKey,
        sourceKey: reader.type.comicSource?.key,
        cid: reader.cid,
        eid: ref.eid,
        chapter: ref.chapter,
        page: ref.page,
        file: file,
      );
    }
    final page = reader.page;
    if (page > 0 && page <= (reader.images?.length ?? 0)) {
      final key = reader.images![page - 1];
      final file = key.startsWith("file://") ? File(key.substring(7)) : null;
      return ReaderImageReference(
        imageKey: key,
        sourceKey: reader.type.comicSource?.key,
        cid: reader.cid,
        eid: reader.eid,
        chapter: reader.chapter,
        page: page,
        file: file,
      );
    }
    return null;
  }

  @override
  ReaderImageReference? getImageReferenceByIndex(int index) {
    if (index < 0) return null;

    if (crossChapter) {
      final globalIndex = _waterfallIndexOfChapterPage(
        reader.chapter,
        index + 1,
      );
      if (globalIndex == null) return null;
      final ref = _imageRefAt(globalIndex);
      if (ref == null) return null;
      final file = ref.imageKey.startsWith("file://")
          ? File(ref.imageKey.substring(7))
          : null;
      return ReaderImageReference(
        imageKey: ref.imageKey,
        sourceKey: reader.type.comicSource?.key,
        cid: reader.cid,
        eid: ref.eid,
        chapter: ref.chapter,
        page: ref.page,
        file: file,
      );
    }

    if (index >= (reader.images?.length ?? 0)) return null;
    final imageKey = reader.images![index];
    final file = imageKey.startsWith("file://")
        ? File(imageKey.substring(7))
        : null;
    return ReaderImageReference(
      imageKey: imageKey,
      sourceKey: reader.type.comicSource?.key,
      cid: reader.cid,
      eid: reader.eid,
      chapter: reader.chapter,
      page: index + 1,
      file: file,
    );
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    final ref = getImageReferenceByOffset(offset);
    if (ref == null) return null;
    if (ref.file != null) {
      if (await ref.file!.exists()) {
        return await ref.file!.readAsBytes();
      }
      return null;
    }
    return await ImageDownloader.loadComicImageBytes(
      ref.imageKey,
      ref.sourceKey,
      ref.cid,
      ref.eid,
      target: null,
    );
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

/// Pure calculation helper for reader content size.
///
/// Safely handles invalid/zero size by clamping to >= 0 and finite numbers.
/// For vertical Continuous/Waterfall mode, limits width according to
/// [limitImageWidth] setting (width = height * 0.7 when width / height > 0.7).
/// Gallery mode maintains real viewport dimensions without limiting width.
Size calculateReaderContentSize({
  required ReaderMode mode,
  required Size viewportSize,
  bool limitImageWidth = false,
  num readerSideMargin = 0,
}) {
  var width = viewportSize.width;
  var height = viewportSize.height;
  if (!width.isFinite || width < 0) width = 0;
  if (!height.isFinite || height < 0) height = 0;

  if (mode.isContinuous &&
      mode.isTopToBottom &&
      limitImageWidth &&
      height > 0) {
    if (width / height > 0.7) {
      width = height * 0.7;
    }
  }

  if (mode.isContinuous && mode.isTopToBottom) {
    final percent = (readerSideMargin.isFinite ? readerSideMargin : 0).clamp(
      0,
      30,
    );
    width *= 1 - percent * 2 / 100;
  }

  return Size(width, height);
}

Size _getSafeReaderViewportSize(BuildContext context, ReaderState reader) {
  if (reader.mode.isGallery) {
    return MediaQuery.of(context).size;
  }
  try {
    final renderBox = reader.context.findRenderObject();
    if (renderBox is RenderBox && renderBox.hasSize) {
      final size = renderBox.size;
      if (size.width > 0 &&
          size.height > 0 &&
          size.width.isFinite &&
          size.height.isFinite) {
        return size;
      }
    }
  } catch (_) {}
  return MediaQuery.of(context).size;
}

bool _isSplitWideImagesEnabled(ReaderState reader) {
  final setting =
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPage',
      ) ==
      true;
  if (reader.mode.isGallery) {
    return reader.imagesPerPage == 1 && setting;
  } else if (reader.mode.isContinuous) {
    return reader.mode.isTopToBottom && setting;
  }
  return false;
}

/// Pure calculation helper for reader image target.
ComicImageLoadTarget calculateReaderImageTarget({
  required ReaderMode mode,
  required Size viewportSize,
  required double devicePixelRatio,
  required int page,
  required int totalImages,
  int imagesPerPage = 1,
  bool showSingleImageOnFirstPage = false,
  bool splitWideImage = false,
  bool limitImageWidth = false,
  num readerSideMargin = 0,
}) {
  final contentSize = calculateReaderContentSize(
    mode: mode,
    viewportSize: viewportSize,
    limitImageWidth: limitImageWidth,
    readerSideMargin: readerSideMargin,
  );

  final dpr = (devicePixelRatio.isFinite && devicePixelRatio > 0)
      ? devicePixelRatio
      : 1.0;

  if (mode.isContinuous) {
    if (mode.isTopToBottom) {
      // 纵向Continuous/Waterfall为fitWidth且高度null，受limitImageWidth约束contentSize.width
      return ComicImageLoadTarget(
        logicalWidth: contentSize.width,
        logicalHeight: null,
        devicePixelRatio: dpr,
        fit: ComicImageTargetFit.fitWidth,
        splitWideImage: splitWideImage,
      );
    } else {
      // 横向Continuous为fitHeight且宽度null
      return ComicImageLoadTarget(
        logicalWidth: null,
        logicalHeight: contentSize.height,
        devicePixelRatio: dpr,
        fit: ComicImageTargetFit.fitHeight,
        splitWideImage: splitWideImage,
      );
    }
  }

  // Gallery mode保持真实viewport规则
  if (page <= 0) {
    return ComicImageLoadTarget(
      logicalWidth: contentSize.width,
      logicalHeight: contentSize.height,
      devicePixelRatio: dpr,
      fit: ComicImageTargetFit.contain,
      splitWideImage: splitWideImage,
    );
  }

  if (imagesPerPage == 1) {
    // Gallery单图全视口
    return ComicImageLoadTarget(
      logicalWidth: contentSize.width,
      logicalHeight: contentSize.height,
      devicePixelRatio: dpr,
      fit: ComicImageTargetFit.contain,
      splitWideImage: splitWideImage,
    );
  }

  // Gallery dual-page mode (imagesPerPage == 2)
  bool isSingle = false;
  if (showSingleImageOnFirstPage) {
    if (page == 1) {
      // 封面单图全视口
      isSingle = true;
    } else {
      final pairStart = 2 + ((page - 2) ~/ 2) * 2;
      if (pairStart == totalImages) {
        // 奇数单图全视口
        isSingle = true;
      }
    }
  } else {
    final pairStart = 1 + ((page - 1) ~/ 2) * 2;
    if (pairStart == totalImages) {
      // 奇数单图全视口
      isSingle = true;
    }
  }

  if (isSingle) {
    return ComicImageLoadTarget(
      logicalWidth: contentSize.width,
      logicalHeight: contentSize.height,
      devicePixelRatio: dpr,
      fit: ComicImageTargetFit.contain,
      splitWideImage: splitWideImage,
    );
  }

  if (mode == ReaderMode.galleryTopToBottom) {
    // 纵向双图半高
    return ComicImageLoadTarget(
      logicalWidth: contentSize.width,
      logicalHeight: contentSize.height / 2,
      devicePixelRatio: dpr,
      fit: ComicImageTargetFit.contain,
      splitWideImage: splitWideImage,
    );
  } else {
    // 横向双图半宽
    return ComicImageLoadTarget(
      logicalWidth: contentSize.width / 2,
      logicalHeight: contentSize.height,
      devicePixelRatio: dpr,
      fit: ComicImageTargetFit.contain,
      splitWideImage: splitWideImage,
    );
  }
}

/// Context-based helper for reader image target calculation.
ComicImageLoadTarget calculateReaderImageTargetFromContext(
  BuildContext context,
  int page, {
  bool? splitWideImage,
}) {
  final reader = context.reader;
  final safeSize = _getSafeReaderViewportSize(context, reader);
  final mediaQuery = MediaQuery.of(context);
  final split = splitWideImage ?? _isSplitWideImagesEnabled(reader);
  final limitImageWidth =
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'limitImageWidth',
      ) ==
      true;
  final rawMargin = appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'readerSideMargin',
  );
  final readerSideMargin = rawMargin is num && rawMargin.isFinite
      ? rawMargin
      : 0;
  return calculateReaderImageTarget(
    mode: reader.mode,
    viewportSize: safeSize,
    devicePixelRatio: mediaQuery.devicePixelRatio,
    page: page,
    totalImages: reader.images?.length ?? 0,
    imagesPerPage: reader.imagesPerPage,
    showSingleImageOnFirstPage: reader.showSingleImageOnFirstPage(),
    splitWideImage: split,
    limitImageWidth: limitImageWidth,
    readerSideMargin: readerSideMargin,
  );
}

ReaderImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page, {
  ComicImageLoadTarget? target,
}) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    reader.eid,
    page,
    chapter: reader.chapter,
    enableResize: true,
    target: target ?? calculateReaderImageTargetFromContext(context, page),
  );
}

ReaderImageProvider _createImageProviderFromRef(
  WaterfallImageRef imageRef,
  BuildContext context,
) {
  var reader = context.reader;
  final target = calculateReaderImageTargetFromContext(context, imageRef.page);
  return ReaderImageProvider(
    imageRef.imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    imageRef.eid,
    imageRef.page,
    chapter: imageRef.chapter,
    enableResize: true,
    target: target,
  );
}

ReaderImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

ReaderImagePreload _createReaderImagePreload(
  ReaderImageProvider provider,
  BuildContext context, {
  void Function(Size)? onImageSize,
}) => ReaderImagePreload(
  key: provider,
  isCached: () =>
      PaintingBinding.instance.imageCache.statusForKey(provider).tracked,
  load: () => RemoteReadContext(priority: RemoteReadPriority.preload).run(
    () async {
      if (onImageSize != null) {
        final configuration = createLocalImageConfiguration(context);
        final stream = provider.resolve(configuration);
        final completion = Completer<void>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, synchronousCall) {
            if (completion.isCompleted) {
              info.dispose();
              return;
            }
            onImageSize(
              ReaderImageProvider.sourceSizeOf(stream.completer) ??
                  Size(
                    info.image.width.toDouble(),
                    info.image.height.toDouble(),
                  ),
            );
            completion.complete();
            SchedulerBinding.instance.addPostFrameCallback((_) {
              info.dispose();
              stream.removeListener(listener);
            });
            SchedulerBinding.instance.ensureVisualUpdate();
          },
          onError: (Object error, StackTrace? stack) {
            if (!completion.isCompleted) completion.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          await completion.future;
        } catch (_) {
          stream.removeListener(listener);
          rethrow;
        }
        return;
      }
      Object? loadError;
      StackTrace? loadStack;
      await precacheImage(
        provider,
        context,
        onError: (error, stack) {
          loadError = error;
          loadStack = stack;
        },
      );
      if (loadError != null) {
        Error.throwWithStackTrace(loadError!, loadStack ?? StackTrace.current);
      }
    },
  ),
);

// A visible widget may reuse precacheImage's pending completer without calling
// ImageDownloader again, so promote the existing transport explicitly.
void _promoteReaderImage(ImageProvider image) {
  if (image is! ReaderImageProvider) return;
  ImageDownloader.promoteComicImage(
    image.imageKey,
    image.sourceKey,
    image.cid,
    image.eid,
    target: image.target,
  );
}

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;

  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;

  late final isPrev = widget.isPrev;

  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    controller?.removeListener(onScroll);
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(16),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}

typedef GalleryPageEntry = ({String imageKey, int sourcePage});

/// Sorts gallery page entries based on reading direction.
List<GalleryPageEntry> sortGalleryPageEntries(
  List<GalleryPageEntry> entries, {
  bool isRightToLeft = false,
}) {
  if (isRightToLeft) {
    return entries.reversed.toList();
  }
  return List<GalleryPageEntry>.from(entries);
}

/// Builds and orders gallery page entries from [images] starting at [startIndex].
List<GalleryPageEntry> buildGalleryPageEntries({
  required List<String> images,
  required int startIndex,
  bool isRightToLeft = false,
}) {
  final entries = <GalleryPageEntry>[
    for (var i = 0; i < images.length; i++)
      (imageKey: images[i], sourcePage: startIndex + i + 1),
  ];
  return sortGalleryPageEntries(entries, isRightToLeft: isRightToLeft);
}

/// Creates a [ReaderImageReference] from a [ReaderImageProvider] with optional fallbacks.
ReaderImageReference createReaderImageReferenceFromProvider(
  ReaderImageProvider provider, {
  String? fallbackSourceKey,
  int? fallbackChapter,
  List<WaterfallChapterSegment>? segments,
}) {
  final imageKey = provider.imageKey;
  final file = imageKey.startsWith("file://")
      ? File(imageKey.substring(7))
      : null;
  int? chapter = provider.chapter ?? fallbackChapter;
  if (provider.chapter == null && segments != null) {
    for (var segment in segments) {
      if (segment.eid == provider.eid) {
        chapter = segment.chapter;
        break;
      }
    }
  }
  return ReaderImageReference(
    imageKey: imageKey,
    sourceKey: provider.sourceKey ?? fallbackSourceKey,
    cid: provider.cid,
    eid: provider.eid,
    chapter: chapter,
    page: provider.page,
    file: file,
  );
}

AutoReadingImageReadiness _visibleAutoReadingImages(
  Iterable<State<ComicImage>> states,
) {
  final visible = states
      .whereType<ComicImageState>()
      .where((image) => image.visibleInReader)
      .toList();
  return AutoReadingImageReadiness(
    combineAutoReadingImageStates(
      visible.map((image) => image.autoReadingImageState),
    ),
    <Object>{for (final image in visible) image.autoReadingIdentity},
  );
}
