import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/context.dart';

import 'consts.dart';
import 'effects.dart';
import 'gesture.dart';

const _maxFlyoutWidth = 360.0;

class FlyoutController {
  Function? _show;

  void show() {
    if (_show == null) {
      throw "FlyoutController is not attached to a Flyout";
    }
    _show!();
  }
}

class Flyout extends StatefulWidget {
  const Flyout({
    super.key,
    required this.flyoutBuilder,
    required this.child,
    this.enableTap = false,
    this.enableDoubleTap = false,
    this.enableLongPress = false,
    this.enableSecondaryTap = false,
    this.withInkWell = false,
    this.borderRadius = 0,
    this.controller,
    this.navigator,
  });

  final WidgetBuilder flyoutBuilder;

  final Widget child;

  final bool enableTap;

  final bool enableDoubleTap;

  final bool enableLongPress;

  final bool enableSecondaryTap;

  final bool withInkWell;

  final double borderRadius;

  final NavigatorState? navigator;

  final FlyoutController? controller;

  @override
  State<Flyout> createState() => FlyoutState();

  static FlyoutState of(BuildContext context) {
    return context.findAncestorStateOfType<FlyoutState>()!;
  }
}

class FlyoutState extends State<Flyout> {
  @override
  void initState() {
    if (widget.controller != null) {
      widget.controller?._show = show;
    }
    super.initState();
  }

  @override
  void didChangeDependencies() {
    if (widget.controller != null) {
      widget.controller?._show = show;
    }
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.withInkWell) {
      return ClickInkWell(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        onTap: widget.enableTap ? show : null,
        onDoubleTap: widget.enableDoubleTap ? show : null,
        onLongPress: widget.enableLongPress ? show : null,
        child: widget.child,
      );
    }
    return GestureDetector(
      onTap: widget.enableTap ? show : null,
      onDoubleTap: widget.enableDoubleTap ? show : null,
      onLongPress: widget.enableLongPress ? show : null,
      onSecondaryTap: widget.enableSecondaryTap ? show : null,
      child: widget.child,
    );
  }

  void show() {
    final renderBox = context.findRenderObject() as RenderBox;
    final navigator =
        widget.navigator ?? Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
    final anchor = overlay.globalToLocal(
      renderBox.localToGlobal(renderBox.size.bottomLeft(Offset.zero)),
    );
    navigator.push(
      PageRouteBuilder(
        fullscreenDialog: true,
        barrierDismissible: true,
        opaque: false,
        transitionDuration: fastAnimationDuration,
        reverseTransitionDuration: fastAnimationDuration,
        pageBuilder: (context, animation, secondaryAnimation) {
          final insets =
              MediaQuery.paddingOf(context) +
              const EdgeInsets.all(12) +
              EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom);

          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: navigator.pop,
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    return ColoredBox(
                      color: Colors.black.withValues(
                        alpha: 0.3 * animation.value,
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: insets,
                child: CustomSingleChildLayout(
                  delegate: _FlyoutLayout(anchor - insets.topLeft),
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.05),
                      end: Offset.zero,
                    ).animate(animation),
                    child: widget.flyoutBuilder(context),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FlyoutLayout extends SingleChildLayoutDelegate {
  const _FlyoutLayout(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: math.min(_maxFlyoutWidth, constraints.maxWidth),
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(
      anchor.dx.clamp(0.0, size.width - childSize.width),
      anchor.dy.clamp(0.0, size.height - childSize.height),
    );
  }

  @override
  bool shouldRelayout(_FlyoutLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class FlyoutContent extends StatelessWidget {
  const FlyoutContent({
    super.key,
    required this.title,
    required this.actions,
    this.content,
  });

  final String title;

  final Widget? content;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    const borderRadius = BorderRadius.all(Radius.circular(12));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 4),
            blurStyle: BlurStyle.outer,
          ),
        ],
      ),
      child: BlurEffect(
        borderRadius: borderRadius,
        blur: 10,
        child: Material(
          color: colors.surfaceContainerHigh.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: borderRadius,
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxFlyoutWidth),
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  ?content,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      overflowSpacing: 8,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
