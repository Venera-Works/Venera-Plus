import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';

import 'effects.dart';
import 'gesture.dart';

void showMenuX(
  BuildContext context,
  Offset location,
  List<MenuEntry> entries, {
  bool centerHorizontally = false,
}) {
  if (entries.isEmpty) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  navigator.push(
    _MenuRoute(entries, overlay.globalToLocal(location), centerHorizontally),
  );
}

class _MenuRoute<T> extends PopupRoute<T> {
  final List<MenuEntry> entries;
  final Offset location;
  final bool centerHorizontally;

  _MenuRoute(this.entries, this.location, this.centerHorizontally);

  static const _menuPadding = 6.0;
  static const _entryPadding = 12.0;
  static const _iconWidth = 28.0;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "menu";

  double get entryHeight => App.isMobile ? 42 : 36;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final safeTop = math.max(padding.top, App.isDesktop ? 36.0 : 0.0);
    final safeBottom = padding.bottom + MediaQuery.viewInsetsOf(context).bottom;
    final bounds = Rect.fromLTRB(
      padding.left + 8,
      safeTop + 8,
      size.width - padding.right - 8,
      size.height - safeBottom - 8,
    );
    if (bounds.isEmpty) return const SizedBox.shrink();

    final colors = context.colorScheme;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(fontSize: 14);
    final hasAnyIcon = entries.any((entry) => entry.icon != null);
    final textPainter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var textWidth = 0.0;
    for (final entry in entries) {
      textPainter.text = TextSpan(text: entry.text, style: textStyle);
      textPainter.layout();
      textWidth = math.max(textWidth, textPainter.width);
    }
    textPainter.dispose();

    final maxWidth = math.min(220.0, math.min(size.width * 0.58, bounds.width));
    final minWidth = math.min(132.0, maxWidth);
    final contentWidth =
        textWidth.ceilToDouble() +
        (_menuPadding + _entryPadding) * 2 +
        (hasAnyIcon ? _iconWidth : 0);
    final menuWidth = contentWidth.clamp(minWidth, maxWidth);
    final maxMenuHeight = math.min(
      bounds.height,
      math.max(entryHeight + _menuPadding * 2, bounds.height * 0.72),
    );
    final menuHeight = math.min(
      entryHeight * entries.length + _menuPadding * 2,
      maxMenuHeight,
    );
    final anchorLeft = centerHorizontally
        ? location.dx - menuWidth / 2
        : location.dx;
    const borderRadius = BorderRadius.all(Radius.circular(12));

    return Stack(
      children: [
        Positioned(
          left: anchorLeft.clamp(
            bounds.left,
            bounds.left + (bounds.width - menuWidth),
          ),
          top: location.dy.clamp(
            bounds.top,
            bounds.top + (bounds.height - menuHeight),
          ),
          width: menuWidth,
          child: ScaleTransition(
            scale: animation.drive(
              Tween(
                begin: 0.96,
                end: 1.0,
              ).chain(CurveTween(curve: Curves.ease)),
            ),
            alignment: centerHorizontally
                ? Alignment.topCenter
                : Alignment.topLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.18),
                    blurRadius: 14,
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
                    constraints: BoxConstraints(maxHeight: maxMenuHeight),
                    child: SingleChildScrollView(
                      primary: false,
                      padding: const EdgeInsets.all(_menuPadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in entries)
                            _buildEntry(context, entry, hasAnyIcon, textStyle),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEntry(
    BuildContext context,
    MenuEntry entry,
    bool hasAnyIcon,
    TextStyle textStyle,
  ) {
    return ClickInkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.of(context).pop();
        entry.onClick();
      },
      child: SizedBox(
        height: entryHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _entryPadding),
          child: Row(
            children: [
              if (entry.icon != null) ...[
                Icon(entry.icon, size: 18, color: entry.color),
                const SizedBox(width: 10),
              ] else if (hasAnyIcon)
                const SizedBox(width: _iconWidth),
              Expanded(
                child: Tooltip(
                  message: entry.text,
                  child: Text(
                    entry.text,
                    style: textStyle.copyWith(color: entry.color),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.ease)),
      child: child,
    );
  }
}

class MenuEntry {
  final String text;
  final IconData? icon;
  final Color? color;
  final void Function() onClick;

  MenuEntry({required this.text, this.icon, this.color, required this.onClick});
}
