import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:venera_plus/components/button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/custom_slider.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/brightness.dart';
import 'package:venera_plus/features/reader/auto_reading.dart';
import 'package:venera_plus/features/reader/chapter_comments.dart';
import 'package:venera_plus/features/reader/chapters.dart';
import 'package:venera_plus/features/reader/eink_refresh.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/orientation.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/routing/settings.dart';
import 'package:venera_plus/routing/comic_source_switch.dart';

class ReaderScaffold extends StatefulWidget {
  const ReaderScaffold({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderScaffold> createState() => ReaderScaffoldState();
}

class ReaderScaffoldState extends State<ReaderScaffold>
    with ReaderOrientationState {
  bool _isOpen = false;
  final _imageSelectionPause = Object();
  ReaderState? _selectionReader;

  bool _isOnChapterCommentsPage = false;
  final _pageChanges = ValueNotifier(0);

  final _imageFavorites = <(String, int, int), ImageFavorite>{};

  final EInkRefreshController _eInkRefreshController = EInkRefreshController();

  static const kTopBarHeight = 56.0;

  static const kBottomBarHeight = 105.0;

  static const _chapterButtonSize = 56.0;

  bool get isOpen => _isOpen;

  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  int showFloatingButtonValue = 0;

  var lastValue = 0;

  ReaderGestureDetectorState? gestureDetectorState;

  void setFloatingButton(int value) {
    if (value == 0 && showFloatingButtonValue != 0) {
      lastValue = showFloatingButtonValue;
      showFloatingButtonValue = 0;
      update();
    } else if ((value == 1 || value == -1) && showFloatingButtonValue == 0) {
      showFloatingButtonValue = value;
      update();
    }
  }

  @override
  void initState() {
    sliderFocus.canRequestFocus = false;
    sliderFocus.addListener(() {
      if (sliderFocus.hasFocus) {
        sliderFocus.nextFocus();
      }
    });
    super.initState();
    _reloadImageFavorites();
    ImageFavoriteManager().addListener(_reloadImageFavorites);
  }

  @override
  void dispose() {
    if (_selectionReader case final reader?) {
      scheduleMicrotask(() {
        if (reader.mounted) {
          reader.autoReading.pause(_imageSelectionPause, false);
        }
      });
    }
    ImageFavoriteManager().removeListener(_reloadImageFavorites);
    _pageChanges.dispose();
    _eInkRefreshController.dispose();
    sliderFocus.dispose();
    super.dispose();
  }

  dynamic _readerSetting(String key) {
    return appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      key,
    );
  }

  void _applySystemUiMode() {
    unawaited(context.reader.applyReaderSystemUiMode(toolbarOpen: _isOpen));
  }

  void openOrClose() {
    setState(() {
      _isOpen = !_isOpen;
    });
    context.reader.autoReading.pause('menu', _isOpen);
    _applySystemUiMode();
  }

  void update() {
    setState(() {});
  }

  void updatePage() {
    if (_isOnChapterCommentsPage != context.reader.isOnChapterCommentsPage) {
      update();
    } else {
      _pageChanges.value++;
    }
  }

  void requestEInkRefresh() {
    if (!mounted || !context.reader.mode.isGallery) {
      return;
    }

    final settings = appdata.settings;
    final comicId = context.reader.cid;
    final sourceKey = context.reader.type.sourceKey;
    final enabled = settings.getReaderSetting(
      comicId,
      sourceKey,
      'eInkRefreshEnabled',
    );
    if (enabled != true) {
      _eInkRefreshController.reset();
      return;
    }

    _eInkRefreshController.onPageChanged(
      interval:
          (settings.getReaderSetting(comicId, sourceKey, 'eInkRefreshInterval')
                  as num)
              .round(),
      durationMilliseconds:
          (settings.getReaderSetting(comicId, sourceKey, 'eInkRefreshDuration')
                  as num)
              .round(),
      style: EInkRefreshStyle.fromKey(
        settings.getReaderSetting(comicId, sourceKey, 'eInkRefreshStyle'),
      ),
    );
  }

  void resetEInkRefreshCounter() {
    _eInkRefreshController.reset();
  }

  @override
  Widget build(BuildContext context) {
    _isOnChapterCommentsPage = context.reader.isOnChapterCommentsPage;
    final brightnessBarVisible = _isOpen && !_isOnChapterCommentsPage;
    final padding = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: context.reader.isPageAnimating,
            child: widget.child,
          ),
        ),
        if (!_isOnChapterCommentsPage)
          Positioned.fill(
            child: ReaderBrightnessOverlay(
              enabled: _readerSetting('readerBrightnessEnabled') == true,
              brightness: _readerSetting('readerBrightness'),
            ),
          ),
        if (!_isOnChapterCommentsPage) _buildReaderStatus(padding),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          right: 16 + padding.right,
          bottom: showFloatingButtonValue == 0
              ? -_chapterButtonSize
              : 48 + padding.bottom,
          child: buildEpChangeButton(),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          top: _isOpen ? 0 : -(kTopBarHeight + padding.top),
          left: 0,
          right: 0,
          height: kTopBarHeight + padding.top,
          child: ListenableBuilder(
            listenable: _pageChanges,
            builder: (context, child) => child ?? buildTop(),
            child: _isOpen ? null : buildTop(),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          bottom: _isOpen ? 0 : -(kBottomBarHeight + padding.bottom),
          left: 0,
          right: 0,
          child: ListenableBuilder(
            listenable: _pageChanges,
            builder: (context, child) => child ?? buildBottom(),
            child: _isOpen ? null : buildBottom(),
          ),
        ),
        if (App.isMobile)
          Positioned(
            top: kTopBarHeight + padding.top + 12,
            bottom: kBottomBarHeight + padding.bottom + 12,
            // The 32px surface starts 4px from the safe edge inside its 48px touch area.
            left: padding.left - 4,
            child: ExcludeFocus(
              excluding: !brightnessBarVisible,
              child: ExcludeSemantics(
                excluding: !brightnessBarVisible,
                child: IgnorePointer(
                  ignoring: !brightnessBarVisible,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    offset: brightnessBarVisible
                        ? Offset.zero
                        : const Offset(-1.5, 0),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: brightnessBarVisible ? 1 : 0,
                      child: buildBrightnessBar(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: EInkRefreshOverlay(controller: _eInkRefreshController),
        ),
      ],
    );
  }

  Widget buildTop() {
    final epName = context.reader.chapterTitle;
    final liked = isLiked();
    final padding = MediaQuery.paddingOf(context);
    final actions = <Widget>[
      if (shouldShowChapterComments())
        Tooltip(
          message: 'Chapter Comments'.tl,
          child: IconButton(
            icon: const Icon(Icons.comment),
            onPressed: openChapterComments,
          ),
        ),
      Tooltip(
        message: 'Collect the image'.tl,
        child: IconButton(
          icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
          color: liked ? context.colorScheme.primary : null,
          onPressed: context.reader.isOnChapterCommentsPage
              ? null
              : addImageFavorite,
        ),
      ),
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.swap_horiz,
            text: 'Switch source'.tl,
            onClick: changeSource,
          ),
          MenuEntry(icon: Icons.share, text: 'Share'.tl, onClick: share),
          MenuEntry(
            icon: Icons.speed,
            text: 'Reading diagnostics'.tl,
            onClick: context.reader.showDiagnostics,
          ),
        ],
      ),
    ];
    return BlurEffect(
      child: Container(
        padding: EdgeInsets.only(top: padding.top),
        color: context.colorScheme.surface.withValues(alpha: 0.92),
        child: Padding(
          padding: EdgeInsets.only(left: padding.left, right: padding.right),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 240) {
                return Row(
                  children: [
                    const Expanded(child: BackButton()),
                    for (final action in actions) Expanded(child: action),
                  ],
                );
              }
              return Row(
                children: [
                  const SizedBox(width: 8),
                  const BackButton(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: epName == null
                        ? Text(
                            context.reader.widget.name,
                            style: ts.s18,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                context.reader.widget.name,
                                style: ts.s16,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                epName,
                                style: ts.s12,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 8),
                  ...actions,
                  const SizedBox(width: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  bool isLiked([ReaderImageReference? image]) {
    final reader = context.reader;
    return canUncollectImageFavorite(
      _imageFavorites[(
        image?.eid ?? reader.eid,
        image?.chapter ?? reader.chapter,
        image?.page ?? reader.sourceImagePageForCurrentReaderPage(),
      )],
    );
  }

  void _reloadImageFavorites() {
    final comic = ImageFavoriteManager().find(
      context.reader.cid,
      context.reader.type.sourceKey,
    );
    // Page changes only read memory, even while the toolbar is hidden.
    _imageFavorites.clear();
    for (final ep in comic?.imageFavoritesEp ?? <ImageFavoritesEp>[]) {
      for (final image in ep.imageFavorites) {
        _imageFavorites.putIfAbsent((ep.eid, ep.ep, image.page), () => image);
      }
    }
    update();
  }

  void addImageFavorite() async {
    final selection = await _selectImageReference();
    if (!mounted || selection == null) return;
    toggleImageFavorite(selection);
  }

  bool? toggleImageFavorite(ReaderImageReference selection) {
    final reader = context.reader;
    final images = reader.images;
    final page = selection.page;
    final chapter = selection.chapter ?? reader.chapter;
    if (images == null ||
        images.isEmpty ||
        page == null ||
        selection.eid != reader.eid ||
        chapter != reader.chapter) {
      return null;
    }
    try {
      final sourceKey = reader.type.sourceKey;
      final comic =
          ImageFavoriteManager().find(reader.cid, sourceKey) ??
          ImageFavoritesComic(
            reader.cid,
            [],
            reader.widget.name,
            sourceKey,
            reader.widget.tags,
            reader.widget.tags.map((tag) => tag.translateTagsToCN).toList(),
            DateTime.now(),
            reader.widget.author,
            {},
            reader.history?.subtitle ?? '',
            images.length,
          );
      final collected = comic.toggleImageFavorite(
        ImageFavorite(
          page,
          selection.imageKey,
          false,
          selection.eid,
          reader.cid,
          chapter,
          sourceKey,
          reader.chapterTitle ?? "Full comic".tl,
        ),
        firstImageKey: images.first,
        chapterPageCount: images.length,
      );
      ImageFavoriteManager().addOrUpdateOrDelete(comic);
      if (!collected) {
        ImageFavoritesProvider.deleteFromCache(
          ImageFavorite(
            page,
            selection.imageKey,
            false,
            selection.eid,
            reader.cid,
            chapter,
            sourceKey,
            reader.chapterTitle ?? '',
          ),
        );
      }
      showToast(
        message: collected
            ? "Successfully collected".tl
            : "Uncollected the image".tl,
        context: context,
        seconds: 1,
      );
      return collected;
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
      return null;
    }
  }

  Widget buildBottom() {
    final padding = MediaQuery.paddingOf(context);
    final buttons = [
      if (App.isDesktop)
        Tooltip(
          message: "${"Full Screen".tl}(F12)",
          child: IconButton(
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              context.reader.fullscreen();
            },
          ),
        ),
      if (App.isAndroid)
        Tooltip(
          message: readerOrientationRestricted
              ? 'On large displays, Android 16 and later control screen rotation.'
                    .tl
              : 'Screen Rotation'.tl,
          triggerMode: readerOrientationRestricted
              ? TooltipTriggerMode.tap
              : null,
          child: IconButton(
            icon: Icon(switch (readerOrientation) {
              ReaderOrientation.system => Icons.screen_rotation,
              ReaderOrientation.portrait => Icons.screen_lock_portrait,
              ReaderOrientation.landscape => Icons.screen_lock_landscape,
            }),
            onPressed: readerOrientationLockEnabled
                ? cycleReaderOrientation
                : null,
          ),
        ),
      Tooltip(
        message: switch (context.reader.autoReading.status) {
          AutoReadingStatus.waiting =>
            'Automatic reading is waiting for content'.tl,
          AutoReadingStatus.paused => 'Automatic reading is paused'.tl,
          _ => 'Start or stop automatic reading'.tl,
        },
        child: IconButton(
          icon: context.reader.autoReading.isActive
              ? const Icon(Icons.pause_circle_outline)
              : const Icon(Icons.play_circle_outline),
          color: context.reader.autoReading.isActive
              ? context.colorScheme.primary
              : null,
          onPressed: () {
            context.reader.autoReading.toggle();
            if (context.reader.autoReading.isActive && isOpen) openOrClose();
            update();
          },
        ),
      ),
      Tooltip(
        message: "Chapters".tl,
        child: IconButton(
          icon: const Icon(Icons.library_books),
          onPressed: openChapterDrawer,
        ),
      ),
      Tooltip(
        message: "Settings".tl,
        child: IconButton(
          icon: const Icon(Icons.settings),
          onPressed: openSetting,
        ),
      ),
    ];

    final child = SizedBox(
      height: kBottomBarHeight,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 8),
              _buildChapterNavigationButton(
                next: isReversed,
                icon: Icons.first_page,
              ),
              Expanded(child: buildSlider()),
              _buildChapterNavigationButton(
                next: !isReversed,
                icon: Icons.last_page,
              ),
              const SizedBox(width: 8),
            ],
          ),
          Row(
            children: [
              for (final button in buttons)
                Expanded(child: Center(child: button)),
            ],
          ),
        ],
      ),
    );

    return BlurEffect(
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.surface.withValues(alpha: 0.92),
          border: isOpen
              ? Border(
                  top: BorderSide(
                    color: context.colorScheme.outlineVariant,
                    width: 0.5,
                  ),
                )
              : null,
        ),
        padding: EdgeInsets.fromLTRB(
          padding.left,
          0,
          padding.right,
          padding.bottom,
        ),
        child: child,
      ),
    );
  }

  String _chapterDirectionLabel(bool next) =>
      (next ? 'Next chapter' : 'Previous chapter').tl;

  Widget _buildChapterNavigationButton({
    required bool next,
    required IconData icon,
  }) {
    final reader = context.reader;
    final atBoundary = next
        ? reader.isLastChapterOfGroup
        : reader.isFirstChapterOfGroup;
    final localizations = MaterialLocalizations.of(context);
    final pageLabel = next
        ? localizations.lastPageTooltip
        : localizations.firstPageTooltip;
    return IconButton.filledTonal(
      tooltip: atBoundary ? pageLabel : _chapterDirectionLabel(next),
      onPressed: () {
        const source = ReadingNavigationSource.userSeek;
        if (next) {
          if (reader.isLastChapterOfGroup) {
            reader.toVisualEnd(source: source);
          } else {
            reader.toNextChapter(source: source);
          }
        } else if (reader.isFirstChapterOfGroup) {
          reader.toPage(1, source: source);
        } else {
          reader.toPrevChapter(source: source);
        }
      },
      icon: Icon(icon),
    );
  }

  Widget buildBrightnessBar() {
    return ReaderBrightnessBar(
      enabled: _readerSetting('readerBrightnessEnabled') == true,
      brightness: _readerSetting('readerBrightness'),
      onEnabledChanged: (enabled) {
        appdata.settings.setActiveReaderSetting(
          context.reader.cid,
          context.reader.type.sourceKey,
          'readerBrightnessEnabled',
          enabled,
        );
        setState(() {});
        appdata.saveData();
      },
      onBrightnessChanged: (brightness) {
        appdata.settings.setActiveReaderSetting(
          context.reader.cid,
          context.reader.type.sourceKey,
          'readerBrightness',
          brightness,
        );
        setState(() {});
      },
      onBrightnessChangeEnd: (_) => appdata.saveData(),
    );
  }

  var sliderFocus = FocusNode();

  Widget buildSlider() {
    // Clamp page to maxPage (excluding chapter comments page)
    final maxPage = context.reader.maxPage.clamp(1, 1 << 16);
    final displayPage = context.reader.page.clamp(1, maxPage);
    return CustomSlider(
      focusNode: sliderFocus,
      value: displayPage.toDouble(),
      min: 1,
      max: maxPage.toDouble(),
      reversed: isReversed,
      divisions: maxPage - 1,
      onChanged: (i) {
        context.reader.toPage(
          i.round(),
          animated: false,
          source: ReadingNavigationSource.userSeek,
        );
      },
    );
  }

  Widget buildPageInfoText() {
    var epName = context.reader.chapterTitle ?? "E${context.reader.chapter}";
    if (epName.length > 8) {
      epName = "${epName.substring(0, 8)}...";
    }
    var pageText = "${context.reader.page}/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return _buildStatusCapsule(
      child: Stack(
        children: [
          ExcludeSemantics(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.surface,
              ),
            ),
          ),
          Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildReaderStatus(EdgeInsets padding) {
    final showPageInfo = _readerSetting('showPageNumberInReader') == true;
    final showClock =
        _readerSetting('enableClockAndBatteryInfoInReader') == true;
    if (!showPageInfo && !showClock) return const SizedBox.shrink();

    return Positioned(
      left: 16 + padding.left,
      right: 16 + padding.right,
      bottom: 12 + padding.bottom,
      child: IgnorePointer(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showPageInfo)
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ListenableBuilder(
                    listenable: _pageChanges,
                    builder: (context, child) => buildPageInfoText(),
                  ),
                ),
              ),
            if (showPageInfo && showClock) const SizedBox(width: 8),
            if (showClock)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _buildStatusCapsule(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [_ClockWidget(), _BatteryWidget()],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCapsule({required Widget child}) {
    final colors = context.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: colors.onSurface, fontSize: 14),
          child: child,
        ),
      ),
    );
  }

  void openChapterDrawer() {
    _openSideBar(ReaderChaptersView(context.reader), width: 400);
  }

  void saveCurrentImage() async {
    final selection = await _selectImageReference();
    if (selection == null) {
      return;
    }
    final data = await _loadBytesFromReference(selection);
    if (data == null) {
      return;
    }
    var fileType = detectFileType(data);
    final chapter = selection.chapter ?? context.reader.chapter;
    var page =
        selection.page ??
        ((context.reader.images?.indexOf(selection.imageKey) ?? -1) + 1);
    if (page <= 0) page = context.reader.page;
    final filename = buildReaderImageFileName(
      context.reader.widget.name,
      chapter,
      page,
      fileType.ext,
    );
    saveFile(data: data, filename: filename);
  }

  bool _switchingSource = false;

  Future<void> changeSource() async {
    if (_switchingSource) return;
    _switchingSource = true;
    var switched = false;
    final reader = context.reader;
    reader.autoReading.pause('source-switch', true);
    try {
      final selected = await switchComicSource(
        context,
        id: reader.cid,
        sourceKey: reader.type.sourceKey,
        title: reader.widget.name,
      );
      if (selected == null || !mounted) return;
      switched = true;
      if (reader.widget.returnSourceChanges) {
        Navigator.of(context).pop(selected);
      } else {
        context.toReplacement(
          () => ComicPage(
            id: selected.id,
            sourceKey: selected.sourceKey,
            title: selected.title,
            cover: selected.cover,
            continueReading: true,
          ),
        );
      }
    } finally {
      _switchingSource = false;
      if (mounted && !switched) {
        reader.autoReading.pause('source-switch', false);
      }
    }
  }

  void share() async {
    final selection = await _selectImageReference();
    if (selection == null) {
      return;
    }
    final data = await _loadBytesFromReference(selection);
    if (data == null) {
      return;
    }
    var fileType = detectFileType(data);
    final chapter = selection.chapter ?? context.reader.chapter;
    var page =
        selection.page ??
        ((context.reader.images?.indexOf(selection.imageKey) ?? -1) + 1);
    if (page <= 0) page = context.reader.page;
    final filename = buildReaderImageFileName(
      context.reader.widget.name,
      chapter,
      page,
      fileType.ext,
    );
    Share.shareFile(data: data, filename: filename, mime: fileType.mime);
  }

  void openSetting() {
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.mode = ReaderMode.fromKey(
              appdata.settings.getReaderSetting(
                context.reader.cid,
                context.reader.type.sourceKey,
                key,
              ),
            );
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (appdata.settings.getReaderSetting(
              context.reader.cid,
              context.reader.type.sourceKey,
              key,
            )) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key.startsWith('eInkRefresh')) {
            resetEInkRefreshCounter();
          }
          if (key.startsWith('readerBrightness')) {
            update();
          }
          if (key == "showChapterComments" ||
              key == "showChapterCommentsAtEnd" ||
              key == "splitDualPage" ||
              key == "splitDualPageInvert") {
            update();
          }
          if (key == "showSystemStatusBar") {
            _applySystemUiMode();
            update();
          }
          if (key == "showPageNumberInReader" ||
              key == "enableClockAndBatteryInfoInReader") {
            update();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    context.reader.autoReading.pause('sidebar', true);
    gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        MouseDragScrollRegion(child: widget),
        width: width,
        dismissible: true,
      ).whenComplete(() {
        if (!mounted) return;
        context.reader.autoReading.pause('sidebar', false);
        gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      'showChapterComments',
    );
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    showSideBar(
      context,
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
    );
  }

  Widget buildEpChangeButton() {
    if (context.reader.widget.chapters == null) return const SizedBox.shrink();

    final colors = context.colorScheme;
    final borderRadius = BorderRadius.circular(16);
    final value = showFloatingButtonValue;
    final arrow = Center(
      child: Icon(
        _getArrowIcon(isReversed, value == 0 ? lastValue : value),
        size: 24,
        color: colors.onPrimaryContainer,
      ),
    );
    Widget child = arrow;
    if (value != 0) {
      final label = _chapterDirectionLabel(value == 1);
      child = Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Semantics(
          label: label,
          button: true,
          child: ClickInkWell(
            onTap: () {
              const source = ReadingNavigationSource.userSeek;
              if (value == 1) {
                context.reader.toNextChapter(source: source);
              } else {
                context.reader.toPrevChapter(source: source);
              }
              setFloatingButton(0);
            },
            borderRadius: borderRadius,
            child: arrow,
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: _chapterButtonSize,
      child: Material(
        color: colors.primaryContainer,
        borderRadius: borderRadius,
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  IconData _getArrowIcon(bool reversed, int value) {
    final next = value == 1;
    final pointsRight = reversed ? !next : next;
    return pointsRight
        ? Icons.arrow_forward_ios_rounded
        : Icons.arrow_back_ios_new_rounded;
  }

  Future<Uint8List?> _loadBytesFromReference(ReaderImageReference ref) async {
    try {
      final bytes = await loadReaderOriginalImageBytes(
        ref,
        fallbackSourceKey: context.reader.type.sourceKey,
      );
      return mounted ? bytes : null;
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
      return null;
    }
  }

  Future<ReaderImageReference?> _selectImageReference() async {
    var reader = context.reader;
    var imageViewController = context.reader.imageViewController;
    if (imageViewController == null || (reader.images?.isEmpty ?? true)) {
      return null;
    }

    bool needsSelection = false;
    int? singleImageIndex;

    if (imageViewController is GalleryModeState) {
      var range = imageViewController.getCurrentPageImageRange();
      if (range != null) {
        var (startIndex, endIndex) = range;
        int actualImageCount = endIndex - startIndex;
        if (actualImageCount == 1) {
          needsSelection = false;
          singleImageIndex = startIndex;
        } else {
          needsSelection = true;
        }
      }
    } else if (imageViewController is ContinuousModeState) {
      needsSelection = false;
      singleImageIndex = reader.page - 1;
    }

    if (!needsSelection && singleImageIndex != null) {
      final ref = imageViewController.getImageReferenceByIndex(
        singleImageIndex,
      );
      if (ref != null) {
        return ref;
      }
      final imageKey =
          (singleImageIndex >= 0 &&
              singleImageIndex < (reader.images?.length ?? 0))
          ? reader.images![singleImageIndex]
          : null;
      if (imageKey == null) return null;
      final file = imageKey.startsWith("file://")
          ? File(imageKey.substring(7))
          : null;
      return ReaderImageReference(
        imageKey: imageKey,
        sourceKey: reader.type.sourceKey,
        cid: reader.cid,
        eid: reader.eid,
        chapter: reader.chapter,
        page: singleImageIndex + 1,
        file: file,
      );
    } else {
      final location = await _showImageSelection();
      if (!mounted ||
          location == null ||
          !identical(imageViewController, reader.imageViewController)) {
        return null;
      }
      final ref = imageViewController.getImageReferenceByOffset(location);
      if (ref != null) {
        return ref;
      }
      var imageKey = imageViewController.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      final index = reader.images?.indexOf(imageKey);
      final file = imageKey.startsWith("file://")
          ? File(imageKey.substring(7))
          : null;
      return ReaderImageReference(
        imageKey: imageKey,
        sourceKey: reader.type.sourceKey,
        cid: reader.cid,
        eid: reader.eid,
        chapter: reader.chapter,
        page: (index != null && index != -1) ? index + 1 : null,
        file: file,
      );
    }
  }

  Future<int?> selectImage() async {
    final selection = await _selectImageReference();
    if (selection == null) return null;
    if (selection.page != null) {
      return selection.page! - 1;
    }
    final index = context.reader.images?.indexOf(selection.imageKey);
    return (index != null && index != -1) ? index : null;
  }

  /// Same as [selectImage], but return the image data with its index.
  /// Returns (imageIndex, imageData) or null if cancelled.
  Future<(int, Uint8List)?> selectImageToData() async {
    final selection = await _selectImageReference();
    if (selection == null) {
      return null;
    }
    final data = await _loadBytesFromReference(selection);
    if (data == null) {
      return null;
    }
    final int i = (selection.page != null)
        ? selection.page! - 1
        : ((context.reader.images?.indexOf(selection.imageKey) ?? -1) >= 0
              ? context.reader.images!.indexOf(selection.imageKey)
              : 0);
    return (i, data);
  }

  Future<Offset?> _showImageSelection() async {
    if (_selectionReader != null) return null;
    final reader = context.reader;
    _selectionReader = reader;
    reader.autoReading.pause(_imageSelectionPause, true);
    try {
      if (_isOpen) openOrClose();
      return await showGeneralDialog<Offset>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: true,
        barrierLabel: 'Cancel'.tl,
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => _SelectImageOverlayContent(
          onTap: (offset) => Navigator.of(context).pop(offset),
          onCancel: () => Navigator.of(context).pop(),
        ),
      );
    } finally {
      if (mounted) {
        _selectionReader = null;
        reader.autoReading.pause(_imageSelectionPause, false);
      }
    }
  }
}

class _BatteryWidget extends StatefulWidget {
  @override
  _BatteryWidgetState createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<_BatteryWidget> {
  late Battery _battery;
  late int _batteryLevel = 100;
  Timer? _timer;
  bool _hasBattery = false;
  BatteryState state = BatteryState.unknown;

  @override
  void initState() {
    super.initState();
    _battery = Battery();
    _checkBatteryAvailability();
  }

  void _checkBatteryAvailability() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      state = await _battery.batteryState;
      if (_batteryLevel > 0 && state != BatteryState.unknown) {
        setState(() {
          _hasBattery = true;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          _battery.batteryLevel.then((level) {
            if (_batteryLevel != level) {
              setState(() {
                _batteryLevel = level;
              });
            }
          });
        });
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBattery) {
      return const SizedBox.shrink(); //Empty Widget
    }
    return _batteryInfo(_batteryLevel);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (state == BatteryState.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 8),
        Icon(batteryIcon, size: 16, color: batteryColor),
        Text('$batteryLevel%'),
      ],
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  _ClockWidgetState createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late String _currentTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = _getCurrentTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final time = _getCurrentTime();
      if (_currentTime != time) {
        setState(() {
          _currentTime = time;
        });
      }
    });
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_currentTime);
}

class _SelectImageOverlayContent extends StatelessWidget {
  const _SelectImageOverlayContent({
    required this.onTap,
    required this.onCancel,
  });

  final ValueChanged<Offset> onTap;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => onTap(details.globalPosition),
      child: Material(
        color: Colors.black.withAlpha(50),
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: const Alignment(0, -0.8),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (context.width - 32).clamp(0.0, double.infinity),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        "Click to select an image".tl,
                        style: TextStyle(fontSize: 16, color: colors.onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: onCancel, child: Text('Cancel'.tl)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
