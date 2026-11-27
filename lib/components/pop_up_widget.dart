import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

class PopUpWidget<T> extends PopupRoute<T> {
  PopUpWidget(this.widget);

  final Widget widget;

  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "exit";

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final showPopUp = mediaQuery.size.width > 500;
    final centeredMargin = showPopUp ? mediaQuery.size.height * 0.05 : 0.0;
    final insets = EdgeInsets.fromLTRB(
      mediaQuery.padding.left,
      showPopUp ? math.max(centeredMargin, mediaQuery.padding.top) : 0,
      mediaQuery.padding.right,
      math.max(
        centeredMargin,
        mediaQuery.padding.bottom + mediaQuery.viewInsets.bottom,
      ),
    );
    final colors = context.colorScheme;
    const borderRadius = BorderRadius.all(Radius.circular(12));
    Widget body = Container(
      decoration: showPopUp
          ? BoxDecoration(
              color: colors.surface,
              borderRadius: borderRadius,
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: 0.2),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            )
          : null,
      foregroundDecoration: showPopUp
          ? BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: colors.outlineVariant),
            )
          : null,
      clipBehavior: showPopUp ? Clip.antiAlias : Clip.none,
      width: showPopUp ? 500 : double.infinity,
      height: double.infinity,
      child: ClipRect(
        child: Navigator(
          onGenerateRoute: (settings) =>
              MaterialPageRoute(builder: (context) => widget),
        ),
      ),
    );
    if (App.isIOS) {
      body = IOSBackGestureDetector(
        enabledCallback: () => true,
        gestureWidth: 20.0,
        onStartPopGesture: () =>
            IOSBackGestureController(controller!, navigator!),
        child: body,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!showPopUp) IgnorePointer(child: ColoredBox(color: colors.surface)),
        Padding(
          padding: insets,
          child: MediaQuery(
            data: mediaQuery
                .removePadding(
                  removeTop: showPopUp,
                  removeBottom: true,
                  removeLeft: true,
                  removeRight: true,
                )
                .removeViewInsets(removeBottom: true),
            child: Align(
              alignment: Alignment.topCenter,
              child: PopupIndicatorWidget(child: body),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 350);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(
        Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.ease)),
      ),
      child: child,
    );
  }
}

class PopupIndicatorWidget extends InheritedWidget {
  const PopupIndicatorWidget({super.key, required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static PopupIndicatorWidget? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PopupIndicatorWidget>();
  }
}

Future<T> showPopUpWidget<T>(BuildContext context, Widget widget) async {
  return await Navigator.of(
    context,
    rootNavigator: true,
  ).push(PopUpWidget(widget));
}

class PopUpWidgetScaffold extends StatefulWidget {
  const PopUpWidgetScaffold({
    required this.title,
    required this.body,
    this.tailing,
    super.key,
  });

  final Widget body;
  final List<Widget>? tailing;
  final String title;

  @override
  State<PopUpWidgetScaffold> createState() => _PopUpWidgetScaffoldState();
}

class _PopUpWidgetScaffoldState extends State<PopUpWidgetScaffold> {
  bool top = true;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Material(
      child: Column(
        children: [
          Container(
            height: 56 + context.padding.top,
            padding: EdgeInsets.only(top: context.padding.top),
            width: double.infinity,
            decoration: BoxDecoration(
              color: top
                  ? null
                  : Theme.of(context).colorScheme.surfaceTint.withAlpha(20),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Tooltip(
                  message: "Back".tl,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () =>
                        context.canPop() ? context.pop() : App.pop(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.tailing != null) ...widget.tailing!,
                const SizedBox(width: 8),
              ],
            ),
          ),
          NotificationListener<ScrollNotification>(
            onNotification: (notifications) {
              if (notifications.metrics.axisDirection != AxisDirection.down) {
                return false;
              }
              if (notifications.metrics.pixels ==
                      notifications.metrics.minScrollExtent &&
                  !top) {
                setState(() {
                  top = true;
                });
              } else if (notifications.metrics.pixels !=
                      notifications.metrics.minScrollExtent &&
                  top) {
                setState(() {
                  top = false;
                });
              }
              return false;
            },
            child: MediaQuery(
              data: mediaQuery
                  .removePadding(removeTop: true, removeBottom: true)
                  .removeViewInsets(removeBottom: true),
              child: Expanded(child: widget.body),
            ),
          ),
          SizedBox(
            height: mediaQuery.padding.bottom + mediaQuery.viewInsets.bottom,
          ),
        ],
      ),
    );
  }
}
