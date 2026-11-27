import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/clipboard_image.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';

class ReaderGestureDetector extends StatefulWidget {
  const ReaderGestureDetector({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderGestureDetector> createState() => ReaderGestureDetectorState();
}

class ReaderGestureDetectorState
    extends AutomaticGlobalState<ReaderGestureDetector>
    with SingleTickerProviderStateMixin
    implements GestureArenaMember {
  late TapGestureRecognizer _tapGestureRecognizer;
  late LongPressGestureRecognizer _longPressGestureRecognizer;

  static const _kDoubleTapMaxTime = Duration(milliseconds: 200);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  static const _kPullToCollectDistance = 100.0;

  late final AnimationController _pullReturnController;
  int? _primaryPointer;
  GestureArenaEntry? _pendingPullGesture;
  ReaderImageReference? _pullImage;
  Offset _pullDistance = Offset.zero;
  double _pullOffset = 0;
  bool _pullWasCollected = false;
  bool? _pullResult;

  int fingers = 0;
  final _pointerPause = Object();
  final _contextMenuPause = Object();
  bool _contextMenuOpen = false;

  late ReaderState reader;

  bool ignoreNextTag = false;

  void ignoreNextTap() {
    ignoreNextTag = true;
  }

  void clearIgnoreNextTap() {
    ignoreNextTag = false;
  }

  @override
  void initState() {
    _tapGestureRecognizer = TapGestureRecognizer()
      ..onTapUp = onTapUp
      ..onSecondaryTapUp = (details) {
        unawaited(_showContextMenu(details.globalPosition));
      };
    _longPressGestureRecognizer =
        LongPressGestureRecognizer(
            supportedDevices: const {PointerDeviceKind.touch},
          )
          ..onLongPressStart = (details) {
            if (_primaryPointer == null) return;
            _returnPull();
            unawaited(_showContextMenu(details.globalPosition));
          };
    super.initState();
    _pullReturnController = AnimationController(vsync: this, value: 1);
    context.readerScaffold.gestureDetectorState = this;
    reader = context.reader;
  }

  @override
  void didUpdateWidget(covariant ReaderGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child.key != widget.child.key ||
        (_pullImage != null && !_canPullToCollect)) {
      _releasePullGesture();
      _pullOffset = 0;
      _pullResult = null;
      _pullReturnController.value = 1;
    }
  }

  @override
  void dispose() {
    final menuOpen = _contextMenuOpen;
    final pointerDown = fingers > 0;
    if (menuOpen || pointerDown) {
      scheduleMicrotask(() {
        if (!reader.mounted) return;
        if (menuOpen) reader.autoReading.pause(_contextMenuPause, false);
        if (pointerDown) reader.autoReading.pause(_pointerPause, false);
      });
    }
    _releasePullGesture();
    _pullReturnController.dispose();
    _tapGestureRecognizer.dispose();
    _longPressGestureRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        fingers++;
        reader.autoReading.pause(_pointerPause, true);
        if (fingers > 1) {
          _primaryPointer = null;
          _returnPull();
        }
        if (event.position == Offset.zero) {
          _previousEvent = null;
          return;
        }
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        _tapGestureRecognizer.addPointer(event);
        if (fingers == 1 && event.buttons == kPrimaryButton) {
          _primaryPointer = event.pointer;
          _longPressGestureRecognizer.addPointer(event);
          _pullImage = _canPullToCollect
              ? reader.imageViewController?.getImageReferenceByOffset(
                  event.position,
                )
              : null;
          if (_pullImage != null) {
            _pendingPullGesture = GestureBinding.instance.gestureArena.add(
              event.pointer,
              this,
            );
          }
          _pullDistance = Offset.zero;
          _pullOffset = 0;
          _pullResult = null;
          _pullWasCollected =
              _pullImage != null && context.readerScaffold.isLiked(_pullImage);
          _pullReturnController.value = 0;
        }
      },
      onPointerMove: _updatePull,
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause(_pointerPause, false);
        final pullImage = _pullImage;
        bool? result;
        if (pullImage != null &&
            fingers == 0 &&
            _canPullToCollect &&
            _isPullReady) {
          result = context.readerScaffold.toggleImageFavorite(pullImage);
        }
        _returnPull(result: result);
        _primaryPointer = null;
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause(_pointerPause, false);
        _returnPull();
        _primaryPointer = null;
      },
      onPointerSignal: (event) {
        reader.autoReading.stop();
        if (event is PointerScrollEvent) {
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: AnimatedBuilder(
        animation: _pullReturnController,
        child: widget.child,
        builder: (context, child) {
          final returning = _pullReturnController.value;
          final completed = _pullResult != null;
          final movement = completed
              ? (returning * 350 / 200).clamp(0.0, 1.0)
              : returning;
          final offset =
              _pullOffset * (1 - Curves.easeOutCubic.transform(movement));
          final fade = completed
              ? const Interval(0.55, 1).transform(returning)
              : returning;
          final opacity = (_pullOffset / 80).clamp(0.0, 1.0) * (1 - fade);
          final ready = _pullImage != null && _isPullReady;
          final liked =
              _pullResult ?? (ready ? !_pullWasCollected : _pullWasCollected);
          final colors = Theme.of(context).colorScheme;
          return ColoredBox(
            color: colors.surface,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Transform.translate(offset: Offset(0, offset), child: child),
                  if (opacity > 0)
                    Positioned(
                      top: MediaQuery.paddingOf(context).top + 16,
                      right: MediaQuery.paddingOf(context).right + 16,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: opacity,
                          child: AnimatedScale(
                            scale: ready || completed ? 1.12 : 1,
                            duration: const Duration(milliseconds: 100),
                            child: Material(
                              color: ready || completed
                                  ? colors.primaryContainer
                                  : colors.surfaceContainerHigh,
                              elevation: 2,
                              shape: const CircleBorder(),
                              child: SizedBox.square(
                                dimension: 48,
                                child: Icon(
                                  liked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: ready || completed
                                      ? colors.onPrimaryContainer
                                      : colors.onSurfaceVariant,
                                  semanticLabel: completed
                                      ? (liked
                                            ? 'Successfully collected'.tl
                                            : 'Uncollected the image'.tl)
                                      : 'Collect the image'.tl,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _updatePull(PointerMoveEvent event) {
    if (event.pointer != _primaryPointer || _pullImage == null) return;
    if (!_canPullToCollect) {
      _returnPull();
      return;
    }

    _pullDistance += event.delta;
    final pending = _pendingPullGesture;
    if (pending != null) {
      final horizontal = _pullDistance.dx.abs();
      final vertical = _pullDistance.dy;
      final slop = computeHitSlop(
        event.kind,
        MediaQuery.maybeGestureSettingsOf(context),
      );
      if (vertical <= slop || vertical <= horizontal * 1.5) {
        if (horizontal > slop || vertical < -slop) _returnPull();
        return;
      }
      // Listener 先于滚动识别器处理本次移动，可在斜下拉时直接锁定方向。
      _pendingPullGesture = null;
      pending.resolve(GestureDisposition.accepted);
    }

    final distance = _pullDistance.dy.clamp(0.0, double.infinity);
    setState(() {
      _pullOffset = distance <= 80
          ? distance
          : (80 + (distance - 80) * 0.35).clamp(0.0, 160.0);
    });
  }

  @override
  void acceptGesture(int pointer) {
    // 即使提前赢得手势竞争，也要等到确认下拉方向后才移动页面。
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _primaryPointer) return;
    _pendingPullGesture = null;
    _pullImage = null;
  }

  bool get _isPullReady =>
      _pendingPullGesture == null &&
      _pullDistance.dy >= _kPullToCollectDistance;

  void _releasePullGesture() {
    final pending = _pendingPullGesture;
    _pendingPullGesture = null;
    _pullImage = null;
    pending?.resolve(GestureDisposition.rejected);
  }

  void _returnPull({bool? result}) {
    if (_pullImage == null) return;
    _releasePullGesture();
    _pullResult = result;
    if (_pullOffset == 0) return;
    _pullReturnController
      ..duration = Duration(milliseconds: result == null ? 200 : 350)
      ..forward(from: 0);
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.imageViewController == null) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage(
              source: ReadingNavigationSource.userForward,
            ) &&
            !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter(
            source: ReadingNavigationSource.userForward,
          );
        }
      } else {
        if (!context.reader.toPrevPage(
              source: ReadingNavigationSource.userBackward,
            ) &&
            !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(
            toLastPage: true,
            source: ReadingNavigationSource.userBackward,
          );
        }
      }
    }
  }

  TapUpDetails? _previousEvent;

  bool get _canPullToCollect {
    if (context.readerScaffold.isOpen ||
        reader.isLoading ||
        reader.isPageAnimating ||
        reader.isOnChapterCommentsPage) {
      return false;
    }
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft &&
        reader.mode != ReaderMode.continuousLeftToRight &&
        reader.mode != ReaderMode.continuousRightToLeft) {
      return false;
    }
    final controller = reader.imageViewController;
    if (controller is GalleryModeState) return controller.canPullToCollect;
    if (controller is ContinuousModeState) return controller.canPullToCollect;
    return controller != null;
  }

  bool get _enableDoubleTapToZoom => appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'enableDoubleTapToZoom',
  );

  void onTapUp(TapUpDetails event) {
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      _previousEvent = null;
      return;
    }
    final location = event.globalPosition;
    if (!_enableDoubleTapToZoom) {
      onTap(location);
      return;
    }
    final previousLocation = _previousEvent?.globalPosition;
    if (previousLocation != null) {
      if ((location - previousLocation).distanceSquared <
          _kDoubleTapMaxDistanceSquared) {
        onDoubleTap(location);
        _previousEvent = null;
        return;
      } else {
        onTap(previousLocation);
      }
    }
    _previousEvent = event;
    Future.delayed(_kDoubleTapMaxTime, () {
      if (_previousEvent == event) {
        onTap(location);
        _previousEvent = null;
      }
    });
  }

  void onTap(Offset location) {
    final controller = reader.imageViewController;
    if (controller == null) {
      return;
    }
    if (controller.handleOnTap(location)) {
      return;
    } else if (context.readerScaffold.isOpen) {
      context.readerScaffold.openOrClose();
    } else {
      // Don't open toolbar on chapter comments page
      if (reader.isOnChapterCommentsPage) {
        return;
      }
      if (appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'enableTapToTurnPages',
      )) {
        bool isLeft = false, isRight = false, isTop = false, isBottom = false;
        final width = context.width;
        final height = context.height;
        final x = location.dx;
        final y = location.dy;
        if (x < width * _kTapToTurnPagePercent) {
          isLeft = true;
        } else if (x > width * (1 - _kTapToTurnPagePercent)) {
          isRight = true;
        }
        if (y < height * _kTapToTurnPagePercent) {
          isTop = true;
        } else if (y > height * (1 - _kTapToTurnPagePercent)) {
          isBottom = true;
        }
        final isOneHandedMode =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'oneHandedMode',
            ) ==
            true;
        if (isOneHandedMode) {
          if (isLeft || isRight || isTop || isBottom) {
            context.reader.toNextPage(
              source: ReadingNavigationSource.userForward,
            );
            return;
          }
        } else {
          bool isCenter = false;
          var prev = () => context.reader.toPrevPage(
            source: ReadingNavigationSource.userBackward,
          );
          var next = () => context.reader.toNextPage(
            source: ReadingNavigationSource.userForward,
          );
          if (appdata.settings.getReaderSetting(
            reader.cid,
            reader.type.sourceKey,
            'reverseTapToTurnPages',
          )) {
            prev = () => context.reader.toNextPage(
              source: ReadingNavigationSource.userForward,
            );
            next = () => context.reader.toPrevPage(
              source: ReadingNavigationSource.userBackward,
            );
          }
          switch (context.reader.mode) {
            case ReaderMode.galleryLeftToRight:
            case ReaderMode.continuousLeftToRight:
              if (isLeft) {
                prev();
              } else if (isRight) {
                next();
              } else {
                isCenter = true;
              }
            case ReaderMode.galleryRightToLeft:
            case ReaderMode.continuousRightToLeft:
              if (isLeft) {
                next();
              } else if (isRight) {
                prev();
              } else {
                isCenter = true;
              }
            case ReaderMode.galleryTopToBottom:
            case ReaderMode.continuousTopToBottom:
            case ReaderMode.waterfallTopToBottom:
              if (isTop) {
                prev();
              } else if (isBottom) {
                next();
              } else {
                isCenter = true;
              }
          }
          if (!isCenter) {
            return;
          }
        }
      }
      context.readerScaffold.openOrClose();
    }
  }

  void onDoubleTap(Offset location) {
    context.reader.imageViewController?.handleDoubleTap(location);
  }

  ReaderImageReference? _pinImageReference(ReaderImageReference? ref) {
    if (ref == null) return null;
    return ReaderImageReference(
      imageKey: ref.imageKey,
      sourceKey: ref.sourceKey ?? reader.type.sourceKey,
      cid: ref.cid,
      eid: ref.eid,
      chapter: ref.chapter ?? reader.chapter,
      page: ref.page ?? reader.page,
      file: ref.file,
    );
  }

  Future<void> _showContextMenu(Offset location) async {
    if (_contextMenuOpen) return;
    final compact = App.isMobile && context.width < 600;
    final ref = reader.isLoading || reader.isOnChapterCommentsPage
        ? null
        : _pinImageReference(
            reader.imageViewController?.getImageReferenceByOffset(location),
          );
    if (compact && ref == null) return;
    _previousEvent = null;
    final entries = [
      if (!compact) ...[
        MenuEntry(
          icon: Icons.settings,
          text: "Settings".tl,
          onClick: () => context.readerScaffold.openSetting(),
        ),
        MenuEntry(
          icon: Icons.library_books,
          text: "Chapters".tl,
          onClick: () => context.readerScaffold.openChapterDrawer(),
        ),
        MenuEntry(
          icon: Icons.fullscreen,
          text: "Fullscreen".tl,
          onClick: () => context.reader.fullscreen(),
        ),
        MenuEntry(
          icon: Icons.exit_to_app,
          text: "Exit".tl,
          onClick: () => context.pop(),
        ),
      ],
      if (ref != null) ...[
        MenuEntry(
          icon: Icons.image_outlined,
          text: "View Original Image".tl,
          onClick: () => _viewOriginalImage(ref),
        ),
        if (App.isDesktop)
          MenuEntry(
            icon: Icons.copy,
            text: "Copy Image".tl,
            onClick: () => _copyImage(ref),
          ),
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Save Image".tl,
          onClick: () => _saveImage(ref),
        ),
      ],
    ];
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
    final anchor = overlay.globalToLocal(location);
    _contextMenuOpen = true;
    reader.autoReading.pause(_contextMenuPause, true);
    try {
      final selected = await showMenu<MenuEntry>(
        context: context,
        useRootNavigator: true,
        position: RelativeRect.fromSize(anchor & Size.zero, overlay.size),
        items: [
          for (final entry in entries)
            PopupMenuItem(
              value: entry,
              height: App.isMobile ? 42 : 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.icon, size: 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      entry.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
      if (mounted) selected?.onClick();
    } finally {
      if (mounted) {
        _contextMenuOpen = false;
        reader.autoReading.pause(_contextMenuPause, false);
      }
    }
  }

  void _viewOriginalImage(ReaderImageReference ref) {
    final future = loadReaderOriginalImageBytes(
      ref,
      fallbackSourceKey: ref.sourceKey ?? reader.type.sourceKey,
    );
    context.to<void>(
      () => _ReaderOriginalImagePage(
        future: future,
        onSave: (bytes) => _saveImage(ref, bytes: bytes),
      ),
    );
  }

  @override
  Object? get key => "reader_gesture";

  Future<Uint8List?> _loadImageBytesFromReference(
    ReaderImageReference ref,
  ) async {
    try {
      return await loadReaderOriginalImageBytes(
        ref,
        fallbackSourceKey: ref.sourceKey ?? reader.type.sourceKey,
      );
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
      return null;
    }
  }

  Future<void> _copyImage(ReaderImageReference ref) async {
    final image = await _loadImageBytesFromReference(ref);
    if (image == null) return;
    try {
      await writeImageToClipboard(image);
    } catch (e, stack) {
      Log.error("Reader", e, stack);
      if (mounted) {
        context.showMessage(message: "Failed to copy image".tl);
      }
      return;
    }
    if (mounted) context.showMessage(message: "Copied".tl);
  }

  Future<void> _saveImage(ReaderImageReference ref, {Uint8List? bytes}) async {
    final page = ref.page ?? reader.page;
    final chapter = ref.chapter ?? reader.chapter;
    final title = reader.widget.name;
    final image = bytes ?? await _loadImageBytesFromReference(ref);
    if (image == null || IO.isSelectingFiles) return;
    final filetype = detectFileType(image);
    final filename = buildReaderImageFileName(
      title,
      chapter,
      page,
      filetype.ext,
    );
    try {
      final saved = await saveFile(filename: filename, data: image);
      if (saved && mounted) context.showMessage(message: "Saved".tl);
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    }
  }
}

class _ReaderOriginalImagePage extends StatefulWidget {
  const _ReaderOriginalImagePage({required this.future, required this.onSave});

  final Future<Uint8List> future;
  final Future<void> Function(Uint8List bytes) onSave;

  @override
  State<_ReaderOriginalImagePage> createState() =>
      _ReaderOriginalImagePageState();
}

class _ReaderOriginalImagePageState extends State<_ReaderOriginalImagePage> {
  static const _appBarHeight = 52.0;
  bool _showAppBar = true;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final padding = context.padding;
    return FutureBuilder<Uint8List>(
      future: widget.future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        final barVisible = _showAppBar || bytes == null;
        final Widget body;
        if (snapshot.hasError) {
          body = NetworkError(
            message: snapshot.error.toString(),
            withAppbar: false,
          );
        } else if (bytes == null) {
          body = const Center(child: CircularProgressIndicator());
        } else {
          body = PhotoView(
            imageProvider: MemoryImage(bytes),
            filterQuality: FilterQuality.medium,
            backgroundDecoration: BoxDecoration(color: colors.surface),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
            onTapUp: (_, _, _) {
              setState(() => _showAppBar = !_showAppBar);
            },
            errorBuilder: (_, error, _, _) {
              if (!_showAppBar) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _showAppBar = true);
                });
              }
              return NetworkError(message: error.toString(), withAppbar: false);
            },
          );
        }

        return Scaffold(
          backgroundColor: colors.surface,
          body: Stack(
            children: [
              Positioned.fill(child: body),
              AnimatedPositioned(
                top: barVisible ? 0 : -(padding.top + _appBarHeight),
                left: 0,
                right: 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !barVisible,
                  child: _buildAppBar(colors, padding, bytes),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAppBar(
    ColorScheme colors,
    EdgeInsets padding,
    Uint8List? bytes,
  ) {
    return BlurEffect(
      child: Material(
        color: colors.surface.withValues(alpha: 0.78),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.outlineVariant, width: 0.5),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              top: padding.top,
              left: padding.left,
              right: padding.right,
            ),
            child: SizedBox(
              height: _appBarHeight,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back'.tl,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'View Original Image'.tl,
                      style: const TextStyle(fontSize: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.save_alt),
                    tooltip: 'Save Image'.tl,
                    onPressed: bytes == null
                        ? null
                        : () => widget.onSave(bytes),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
