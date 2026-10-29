import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:venera_plus/foundation/translations.dart';

class ReaderGestureDetector extends StatefulWidget {
  const ReaderGestureDetector({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderGestureDetector> createState() => ReaderGestureDetectorState();
}

class ReaderGestureDetectorState
    extends AutomaticGlobalState<ReaderGestureDetector>
    with SingleTickerProviderStateMixin {
  late TapGestureRecognizer _tapGestureRecognizer;

  static const _kDoubleTapMaxTime = Duration(milliseconds: 200);

  static const _kLongPressMinTime = Duration(milliseconds: 250);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  static const _kPullToCollectDistance = 100.0;

  late final AnimationController _pullReturnController;
  ReaderImageReference? _pullImage;
  Offset _pullDistance = Offset.zero;
  double _pullOffset = 0;
  bool _pullWasCollected = false;
  bool? _pullResult;

  int fingers = 0;

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
        onSecondaryTapUp(details.globalPosition);
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
      _pullImage = null;
      _pullOffset = 0;
      _pullResult = null;
      _pullReturnController.value = 1;
    }
  }

  @override
  void dispose() {
    _pullReturnController.dispose();
    _tapGestureRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.position == Offset.zero) {
          _previousEvent = null;
          return;
        }
        fingers++;
        reader.autoReading.pause('pointer', true);
        if (fingers > 1) {
          _returnPull();
        }
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        _lastTapPointer = event.pointer;
        _lastTapMoveDistance = Offset.zero;
        _tapGestureRecognizer.addPointer(event);
        if (fingers == 1) {
          _pullImage = _canPullToCollect
              ? reader.imageViewController?.getImageReferenceByOffset(
                  event.position,
                )
              : null;
          _pullDistance = Offset.zero;
          _pullOffset = 0;
          _pullResult = null;
          _pullWasCollected =
              _pullImage != null && context.readerScaffold.isLiked(_pullImage);
          _pullReturnController.value = 0;
        }
        Future.delayed(_kLongPressMinTime, () {
          if (mounted && _lastTapPointer == event.pointer && fingers == 1) {
            if (_lastTapMoveDistance!.distanceSquared < 20.0 * 20.0) {
              onLongPressedDown(event.position);
              _longPressInProgress = true;
              _returnPull();
            }
          }
        });
      },
      onPointerMove: (event) {
        if (event.pointer == _lastTapPointer) {
          _lastTapMoveDistance = event.delta + _lastTapMoveDistance!;
        }
        if (fingers == 1 &&
            event.pointer == _lastTapPointer &&
            _pullImage != null) {
          _pullDistance += event.delta;
          if (!_canPullToCollect ||
              (_pullDistance.dx.abs() > 24 &&
                  _pullDistance.dx.abs() > _pullDistance.dy.abs()) ||
              (_pullOffset == 0 && _pullDistance.dy < -24)) {
            _returnPull();
          } else if (_pullOffset > 0 ||
              (_pullDistance.dy > kTouchSlop &&
                  _pullDistance.dy > _pullDistance.dx.abs() * 1.5)) {
            final distance = _pullDistance.dy.clamp(0.0, double.infinity);
            setState(() {
              _pullOffset = distance <= 80
                  ? distance
                  : (80 + (distance - 80) * 0.35).clamp(0.0, 160.0);
            });
          }
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause('pointer', false);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        final pullImage = _pullImage;
        bool? result;
        if (pullImage != null &&
            fingers == 0 &&
            !_longPressInProgress &&
            _canPullToCollect &&
            _isPullReady) {
          result = context.readerScaffold.toggleImageFavorite(pullImage);
        }
        _returnPull(result: result);
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause('pointer', false);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        _returnPull();
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
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

  bool get _isPullReady =>
      _pullDistance.dy >= _kPullToCollectDistance &&
      _pullDistance.dy > _pullDistance.dx.abs() * 1.5;

  void _returnPull({bool? result}) {
    if (_pullImage == null) return;
    _pullImage = null;
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

  int? _lastTapPointer;

  Offset? _lastTapMoveDistance;

  bool _longPressInProgress = false;

  bool get _canPullToCollect {
    if (context.readerScaffold.isOpen ||
        reader.isLoading ||
        reader.isPageAnimating ||
        reader.isOnChapterCommentsPage ||
        _longPressInProgress) {
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
    if (_longPressInProgress) {
      _longPressInProgress = false;
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

  void onSecondaryTapUp(Offset location) {
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.settings,
        text: "Settings".tl,
        onClick: () {
          context.readerScaffold.openSetting();
        },
      ),
      MenuEntry(
        icon: Icons.menu,
        text: "Chapters".tl,
        onClick: () {
          context.readerScaffold.openChapterDrawer();
        },
      ),
      MenuEntry(
        icon: Icons.fullscreen,
        text: "Fullscreen".tl,
        onClick: () {
          context.reader.fullscreen();
        },
      ),
      MenuEntry(
        icon: Icons.exit_to_app,
        text: "Exit".tl,
        onClick: () {
          context.pop();
        },
      ),
      if (App.isDesktop && !reader.isLoading)
        MenuEntry(
          icon: Icons.copy,
          text: "Copy Image".tl,
          onClick: () => copyImage(location),
        ),
      if (!reader.isLoading)
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Save Image".tl,
          onClick: () => saveImage(location),
        ),
    ]);
  }

  String? _longPressAction;

  void onLongPressedUp(Offset location) {
    if (_longPressAction == 'zoom') {
      reader.imageViewController?.handleLongPressUp(location);
    }
    _longPressAction = null;
  }

  void onLongPressedDown(Offset location) {
    _longPressAction =
        (reader.readerSetting('longPressAction') as String?) ??
        (reader.readerSetting('enableLongPressToZoom') == true
            ? 'zoom'
            : 'none');
    switch (_longPressAction) {
      case 'zoom':
        reader.imageViewController?.handleLongPressDown(location);
      case 'autoReading':
        reader.autoReading.toggle();
      default:
        break;
    }
  }

  @override
  Object? get key => "reader_gesture";

  Future<Uint8List?> _loadImageBytesFromReference(
    ReaderImageReference ref,
  ) async {
    try {
      return await loadReaderOriginalImageBytes(
        ref,
        fallbackSourceKey: reader.type.sourceKey,
      );
    } catch (e) {
      context.showMessage(message: e.toString());
      return null;
    }
  }

  void copyImage(Offset location) async {
    var controller = reader.imageViewController;
    if (controller == null) return;
    final ref = controller.getImageReferenceByOffset(location);
    if (ref == null) {
      context.showMessage(message: "No Image".tl);
      return;
    }
    var image = await _loadImageBytesFromReference(ref);
    if (image != null) {
      writeImageToClipboard(image);
    }
  }

  void saveImage(Offset location) async {
    var controller = reader.imageViewController;
    if (controller == null) return;
    final ref = controller.getImageReferenceByOffset(location);
    if (ref == null) {
      context.showMessage(message: "No Image".tl);
      return;
    }
    var image = await _loadImageBytesFromReference(ref);
    if (image != null) {
      var filetype = detectFileType(image);
      var page = ref.page ?? reader.page;
      var chapter = ref.chapter ?? reader.chapter;
      final filename = buildReaderImageFileName(
        reader.widget.name,
        chapter,
        page,
        filetype.ext,
      );
      saveFile(filename: filename, data: image);
    }
  }
}
