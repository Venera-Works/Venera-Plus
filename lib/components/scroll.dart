import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'consts.dart';

/// Scopes one root smooth scroll view to NestedScrollView's inner controller.
/// The root view isolates its sliver descendants from this scope.
class NestedScrollScope extends InheritedWidget {
  const NestedScrollScope({
    super.key,
    required this.controller,
    required this.isActive,
    required super.child,
  });

  const NestedScrollScope._isolated({required super.child})
    : controller = null,
      isActive = false;

  final ScrollController? controller;
  final bool isActive;

  static NestedScrollScope? maybeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<NestedScrollScope>();
    return scope?.controller == null ? null : scope;
  }

  static Widget isolate(Widget child) =>
      NestedScrollScope._isolated(child: child);

  @override
  bool updateShouldNotify(NestedScrollScope oldWidget) =>
      oldWidget.controller != controller || oldWidget.isActive != isActive;
}

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({
    super.key,
    required this.slivers,
    this.controller,
    this.physics,
  });

  final ScrollController? controller;

  final List<Widget> slivers;

  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final nestedScope = NestedScrollScope.maybeOf(context);
    return SmoothScrollProvider(
      controller: controller,
      nestedController: nestedScope?.controller,
      nestedScrollActive: nestedScope?.isActive ?? false,
      builder: (context, controller, providedPhysics) {
        final scrollView = CustomScrollView(
          controller: controller,
          physics: physics == null
              ? providedPhysics
              : providedPhysics.applyTo(physics),
          slivers: [
            ...slivers,
            SliverPadding(
              padding: EdgeInsets.only(bottom: context.padding.bottom),
            ),
          ],
        );
        return nestedScope == null
            ? scrollView
            : NestedScrollScope.isolate(scrollView);
      },
    );
  }
}

/// Mirrors the root list's single position, but joins NestedScrollView only
/// while its category is active.
class _NestedScrollControllerBridge extends ScrollController {
  _NestedScrollControllerBridge({
    required ScrollController localController,
    required ScrollController nestedController,
    required bool isActive,
  }) : _localController = localController,
       _nestedController = nestedController,
       _isActive = isActive;

  final ScrollController _localController;
  final ScrollController _nestedController;

  bool _isActive;

  bool get isActive => _isActive;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _nestedController.createScrollPosition(physics, context, oldPosition);

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    _localController.attach(position);
    if (_isActive) {
      _nestedController.attach(position);
    }
  }

  @override
  void detach(ScrollPosition position) {
    if (_isActive) {
      _nestedController.detach(position);
    }
    _localController.detach(position);
    super.detach(position);
  }

  void setActive(bool isActive) {
    if (_isActive == isActive) return;
    _isActive = isActive;
    for (final position in positions) {
      if (isActive) {
        _nestedController.attach(position);
      } else {
        position.beginActivity(
          IdleScrollActivity(position as ScrollActivityDelegate),
        );
        _nestedController.detach(position);
      }
    }
  }

  @override
  void dispose() {
    setActive(false);
    while (positions.isNotEmpty) {
      detach(positions.first);
    }
    super.dispose();
  }
}

class AppRefreshIndicator extends StatefulWidget {
  const AppRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;

  final Widget child;

  @override
  State<AppRefreshIndicator> createState() => _AppRefreshIndicatorState();
}

class _AppRefreshIndicatorState extends State<AppRefreshIndicator> {
  static const _wheelPullDistance = 56.0;
  static const _mouseDragDistance = 72.0;
  static const _wheelIdleTimeout = Duration(milliseconds: 400);

  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  ScrollMetrics? _metrics;
  Future<void>? _activeRefresh;
  Timer? _wheelIdleTimer;
  double _pendingPullDistance = 0;
  bool _pullLatched = false;
  _MouseRefreshDrag? _mouseDrag;
  int _scrollNotificationRevision = 0;
  int _lastScrollNotificationDepth = 0;

  bool get _isAtTop {
    final metrics = _metrics;
    if (metrics == null ||
        axisDirectionToAxis(metrics.axisDirection) != Axis.vertical) {
      return false;
    }
    return switch (metrics.axisDirection) {
      AxisDirection.down => metrics.pixels <= metrics.minScrollExtent + 0.5,
      AxisDirection.up => metrics.pixels >= metrics.maxScrollExtent - 0.5,
      _ => false,
    };
  }

  Future<void> _handleRefresh() {
    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) return activeRefresh;

    final operation = Future<void>.sync(widget.onRefresh);
    _activeRefresh = operation;
    unawaited(
      operation.then<void>(
        (_) => _clearActiveRefresh(operation),
        onError: (Object _, StackTrace _) => _clearActiveRefresh(operation),
      ),
    );
    return operation;
  }

  void _clearActiveRefresh(Future<void> operation) {
    if (identical(_activeRefresh, operation)) {
      _activeRefresh = null;
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _scrollNotificationRevision++;
    _lastScrollNotificationDepth = notification.depth;
    if (notification.depth == 0) {
      _metrics = notification.metrics;
      _resetPullWhenAwayFromTop();
    }
    return false;
  }

  bool _handleMetricsNotification(ScrollMetricsNotification notification) {
    if (notification.depth == 0) {
      _metrics = notification.metrics;
      _resetPullWhenAwayFromTop();
    }
    return false;
  }

  void _resetPullWhenAwayFromTop() {
    if (!_isAtTop && !_pullLatched) {
      _pendingPullDistance = 0;
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (HardwareKeyboard.instance.isShiftPressed ||
        delta.dy == 0 ||
        delta.dx.abs() >= delta.dy.abs()) {
      return;
    }

    if (!_isAtTop) {
      _pendingPullDistance = 0;
      _pullLatched = false;
      return;
    }

    final notificationRevision = _scrollNotificationRevision;
    var resolvedHere = false;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      resolvedHere = true;
      _handleWheelDelta(delta.dy);
    });

    // Scrollables below this listener normally register first with the
    // resolver. Their scroll notifications distinguish nested scrolling from
    // an unconsumed pull at the outer list's leading edge.
    scheduleMicrotask(() {
      if (!mounted ||
          resolvedHere ||
          (_scrollNotificationRevision > notificationRevision &&
              _lastScrollNotificationDepth > 0)) {
        return;
      }
      _handleWheelDelta(delta.dy);
    });
  }

  void _handleWheelDelta(double deltaY) {
    if (!_isAtTop) {
      _pendingPullDistance = 0;
      _pullLatched = false;
    } else if (deltaY > 0) {
      _pendingPullDistance = 0;
      _pullLatched = false;
    } else if (_activeRefresh != null) {
      // Don't retrigger after this continuous wheel burst completes.
      _pullLatched = true;
    } else {
      _accumulatePull(-deltaY);
    }
    _scheduleWheelIdleReset();
  }

  void _scheduleWheelIdleReset() {
    _wheelIdleTimer?.cancel();
    _wheelIdleTimer = Timer(_wheelIdleTimeout, () {
      _wheelIdleTimer = null;
      _pendingPullDistance = 0;
      _pullLatched = false;
    });
  }

  void _cancelWheelIdleReset() {
    _wheelIdleTimer?.cancel();
    _wheelIdleTimer = null;
  }

  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final delta = event.panDelta;
    if (delta.dy == 0 || delta.dx.abs() >= delta.dy.abs()) return;

    final notificationRevision = _scrollNotificationRevision;
    scheduleMicrotask(() {
      if (!mounted ||
          (_scrollNotificationRevision > notificationRevision &&
              _lastScrollNotificationDepth > 0)) {
        return;
      }
      if (!_isAtTop) {
        _pendingPullDistance = 0;
        _pullLatched = false;
      } else if (delta.dy > 0) {
        if (_activeRefresh != null) {
          _pullLatched = true;
        } else {
          _accumulatePull(delta.dy);
        }
      } else {
        _pendingPullDistance = 0;
        _pullLatched = false;
      }
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    _cancelWheelIdleReset();
    _pendingPullDistance = 0;
    _pullLatched = false;
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) != 0 &&
        _isAtTop) {
      _mouseDrag = _MouseRefreshDrag(
        pointer: event.pointer,
        position: event.position,
        notificationRevision: _scrollNotificationRevision,
      );
    } else {
      _mouseDrag = null;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final drag = _mouseDrag;
    if (drag == null || drag.pointer != event.pointer || _pullLatched) return;
    if (_scrollNotificationRevision > drag.notificationRevision &&
        _lastScrollNotificationDepth > 0) {
      _mouseDrag = null;
      return;
    }

    final movement = event.position - drag.position;
    if (movement.dy < _mouseDragDistance ||
        movement.dx.abs() >= movement.dy.abs() ||
        !_isAtTop) {
      return;
    }

    _pullLatched = true;
    if (_activeRefresh != null) return;
    _showRefresh();
  }

  void _accumulatePull(double distance) {
    if (_pullLatched) return;
    _pendingPullDistance += distance;
    if (_pendingPullDistance < _wheelPullDistance) return;

    _pendingPullDistance = 0;
    _pullLatched = true;
    _showRefresh();
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_mouseDrag?.pointer == event.pointer) {
      _mouseDrag = null;
      _pendingPullDistance = 0;
      _pullLatched = false;
      _cancelWheelIdleReset();
    }
  }

  void _handlePanZoomStart(PointerPanZoomStartEvent event) {
    _cancelWheelIdleReset();
    _pendingPullDistance = 0;
    _pullLatched = false;
    _mouseDrag = null;
  }

  void _handlePanZoomEnd(PointerPanZoomEndEvent event) {
    _pendingPullDistance = 0;
    _pullLatched = false;
    _cancelWheelIdleReset();
  }

  void _showRefresh() {
    final future = _refreshIndicatorKey.currentState?.show(atTop: true);
    if (future != null) {
      unawaited(
        future.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'AppRefreshIndicator',
                context: ErrorDescription(
                  'while refreshing from desktop scroll input',
                ),
              ),
            );
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _cancelWheelIdleReset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _handlePointerSignal,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      onPointerPanZoomStart: _handlePanZoomStart,
      onPointerPanZoomUpdate: _handlePointerPanZoomUpdate,
      onPointerPanZoomEnd: _handlePanZoomEnd,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleMetricsNotification,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: RefreshIndicator(
            key: _refreshIndicatorKey,
            onRefresh: _handleRefresh,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _MouseRefreshDrag {
  const _MouseRefreshDrag({
    required this.pointer,
    required this.position,
    required this.notificationRevision,
  });

  final int pointer;
  final Offset position;
  final int notificationRevision;
}

class SmoothScrollProvider extends StatefulWidget {
  const SmoothScrollProvider({
    super.key,
    this.controller,
    this.nestedController,
    this.nestedScrollActive = false,
    required this.builder,
  });

  final ScrollController? controller;
  final ScrollController? nestedController;
  final bool nestedScrollActive;

  final Widget Function(BuildContext, ScrollController, ScrollPhysics) builder;

  static bool get isMouseScroll => _SmoothScrollProviderState._isMouseScroll;

  @override
  State<SmoothScrollProvider> createState() => _SmoothScrollProviderState();
}

class _SmoothScrollProviderState extends State<SmoothScrollProvider> {
  late final ScrollController _controller;
  _NestedScrollControllerBridge? _nestedController;

  ScrollController get _scrollController => _nestedController ?? _controller;

  double? _futurePosition;

  static bool _isMouseScroll = App.isDesktop;

  late int id;

  static int _id = 0;

  var activeChildren = <int>{};

  ScrollState? parent;

  @override
  void initState() {
    _controller = widget.controller ?? ScrollController();
    _nestedController = _createNestedController();
    super.initState();
    id = _id;
    _id++;
  }

  _NestedScrollControllerBridge? _createNestedController() {
    final nestedController = widget.nestedController;
    if (nestedController == null) return null;
    return _NestedScrollControllerBridge(
      localController: _controller,
      nestedController: nestedController,
      isActive: widget.nestedScrollActive,
    );
  }

  @override
  void didUpdateWidget(covariant SmoothScrollProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nestedController != widget.nestedController) {
      _nestedController?.setActive(false);
      _nestedController = _createNestedController();
    } else if (oldWidget.nestedScrollActive != widget.nestedScrollActive) {
      _nestedController?.setActive(widget.nestedScrollActive);
    }
  }

  @override
  void didChangeDependencies() {
    parent = ScrollState.maybeOf(context);
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    parent?.onChildInactive(id);
    _nestedController?.dispose();
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrollController = _scrollController;
    if (App.isMacOS) {
      return widget.builder(
        context,
        scrollController,
        const BouncingScrollPhysics(),
      );
    }
    var child = Listener(
      onPointerDown: (event) {
        _futurePosition = null;
        if (_isMouseScroll) {
          setState(() {
            _isMouseScroll = false;
          });
        }
      },
      onPointerSignal: (pointerSignal) {
        if (activeChildren.isNotEmpty) {
          return;
        }
        if (pointerSignal is PointerScrollEvent) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            return;
          }
          if (pointerSignal.kind == PointerDeviceKind.mouse &&
              !_isMouseScroll) {
            setState(() {
              _isMouseScroll = true;
            });
          }
          if (!_isMouseScroll) return;
          final nestedController = _nestedController;
          if (nestedController != null) {
            if (!nestedController.isActive || !nestedController.hasClients) {
              return;
            }
            _futurePosition = null;
            GestureBinding.instance.pointerSignalResolver.register(
              pointerSignal,
              (_) {
                if (nestedController.isActive && nestedController.hasClients) {
                  nestedController.position.pointerScroll(
                    pointerSignal.scrollDelta.dy,
                  );
                }
              },
            );
            return;
          }
          var currentLocation = _controller.position.pixels;
          var old = _futurePosition;
          _futurePosition ??= currentLocation;
          double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
          _futurePosition = _futurePosition! + pointerSignal.scrollDelta.dy * k;
          var beforeOffset = (_futurePosition! - currentLocation).abs();
          _futurePosition = _futurePosition!.clamp(
            _controller.position.minScrollExtent,
            _controller.position.maxScrollExtent,
          );
          var afterOffset = (_futurePosition! - currentLocation).abs();
          if (_futurePosition == old) return;
          var target = _futurePosition!;
          var duration = fastAnimationDuration;
          if (afterOffset < beforeOffset) {
            duration = duration * (afterOffset / beforeOffset);
            if (duration < Duration(milliseconds: 10)) {
              duration = Duration(milliseconds: 10);
            }
          }
          _controller
              .animateTo(
                _futurePosition!,
                duration: duration,
                curve: Curves.linear,
              )
              .then((_) {
                var current = _controller.position.pixels;
                if (current == target && current == _futurePosition) {
                  _futurePosition = null;
                }
              });
        }
      },
      child: ScrollState._(
        controller: _controller,
        onChildActive: (id) {
          activeChildren.add(id);
        },
        onChildInactive: (id) {
          activeChildren.remove(id);
        },
        child: widget.builder(
          context,
          scrollController,
          _isMouseScroll
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(),
        ),
      ),
    );

    if (parent != null) {
      return MouseRegion(
        onEnter: (_) {
          parent!.onChildActive(id);
        },
        onExit: (_) {
          parent!.onChildInactive(id);
        },
        child: child,
      );
    }

    return child;
  }
}

class ScrollState extends InheritedWidget {
  const ScrollState._({
    required this.controller,
    required super.child,
    required this.onChildActive,
    required this.onChildInactive,
  });

  final ScrollController controller;

  final void Function(int id) onChildActive;

  final void Function(int id) onChildInactive;

  static ScrollState of(BuildContext context) {
    final ScrollState? provider = context
        .dependOnInheritedWidgetOfExactType<ScrollState>();
    return provider!;
  }

  static ScrollState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScrollState>();
  }

  @override
  bool updateShouldNotify(ScrollState oldWidget) {
    return oldWidget.controller != controller;
  }
}

class AppScrollBar extends StatefulWidget {
  const AppScrollBar({
    super.key,
    required this.controller,
    required this.child,
    this.topPadding = 0,
  });

  final ScrollController controller;

  final Widget child;

  final double topPadding;

  @override
  State<AppScrollBar> createState() => _AppScrollBarState();
}

class _AppScrollBarState extends State<AppScrollBar> {
  late final ScrollController _scrollController;

  double minExtent = 0;
  double maxExtent = 0;
  double position = 0;

  double viewHeight = 0;

  final _scrollIndicatorSize = App.isDesktop ? 36.0 : 54.0;

  late final VerticalDragGestureRecognizer _dragGestureRecognizer;

  bool _isVisible = false;
  Timer? _hideTimer;
  static const _hideDuration = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _scrollController = widget.controller;
    _scrollController.addListener(onChanged);
    Future.microtask(onChanged);
    _dragGestureRecognizer = VerticalDragGestureRecognizer()
      ..onUpdate = onUpdate
      ..onStart = (_) {
        _showScrollbar();
      }
      ..onEnd = (_) {
        _scheduleHide();
      };
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _scrollController.removeListener(onChanged);
    _dragGestureRecognizer.dispose();
    super.dispose();
  }

  void _showScrollbar() {
    if (!_isVisible && mounted) {
      setState(() {
        _isVisible = true;
      });
    }
    _hideTimer?.cancel();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDuration, () {
      if (mounted && _isVisible) {
        setState(() {
          _isVisible = false;
        });
      }
    });
  }

  void onUpdate(DragUpdateDetails details) {
    if (maxExtent - minExtent <= 0 ||
        viewHeight == 0 ||
        details.primaryDelta == null) {
      return;
    }
    var offset = details.primaryDelta!;
    var positionOffset =
        offset / (viewHeight - _scrollIndicatorSize) * (maxExtent - minExtent);
    _scrollController.jumpTo(
      (position + positionOffset).clamp(minExtent, maxExtent),
    );
  }

  void onChanged() {
    if (_scrollController.positions.isEmpty) return;
    var position = _scrollController.position;

    bool hasChanged = false;
    if (position.minScrollExtent != minExtent ||
        position.maxScrollExtent != maxExtent ||
        position.pixels != this.position) {
      hasChanged = true;
      minExtent = position.minScrollExtent;
      maxExtent = position.maxScrollExtent;
      this.position = position.pixels;
    }

    if (hasChanged) {
      _showScrollbar();
      _scheduleHide();
    }

    if (hasChanged && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constrains) {
        var scrollHeight = (maxExtent - minExtent);
        var height = constrains.maxHeight - widget.topPadding;
        viewHeight = height;
        var top = scrollHeight == 0
            ? 0.0
            : (position - minExtent) /
                  scrollHeight *
                  (height - _scrollIndicatorSize);
        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            Positioned(
              top: top + widget.topPadding,
              right: 0,
              child: AnimatedOpacity(
                opacity: _isVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => _showScrollbar(),
                  onExit: (_) => _scheduleHide(),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      _dragGestureRecognizer.addPointer(event);
                    },
                    child: SizedBox(
                      width: _scrollIndicatorSize / 2,
                      height: _scrollIndicatorSize,
                      child: CustomPaint(
                        painter: _ScrollIndicatorPainter(
                          backgroundColor: context.colorScheme.surface,
                          shadowColor: context.colorScheme.shadow,
                        ),
                        child: Column(
                          children: [
                            const Spacer(),
                            Icon(Icons.arrow_drop_up, size: 18),
                            Icon(Icons.arrow_drop_down, size: 18),
                            const Spacer(),
                          ],
                        ).paddingLeft(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ScrollIndicatorPainter extends CustomPainter {
  final Color backgroundColor;

  final Color shadowColor;

  const _ScrollIndicatorPainter({
    required this.backgroundColor,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawShadow(path, shadowColor, 2, true);
    var backgroundPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawPath(path, backgroundPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ScrollIndicatorPainter ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.shadowColor != shadowColor;
  }
}
