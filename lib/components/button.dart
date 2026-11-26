import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'consts.dart';
import 'menu.dart';

const actionButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(64, 36)),
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  ),
  textStyle: WidgetStatePropertyAll(
    TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
  ),
  shape: WidgetStatePropertyAll(StadiumBorder()),
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.padded,
);

class ButtonLoadingContent extends StatelessWidget {
  const ButtonLoadingContent({
    super.key,
    required this.isLoading,
    required this.child,
  });

  final bool isLoading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isLoading) return child;
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: 0,
          alwaysIncludeSemantics: true,
          child: IgnorePointer(child: child),
        ),
        SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DefaultTextStyle.of(context).style.color,
          ),
        ),
      ],
    );
  }
}

class HoverBox extends StatefulWidget {
  const HoverBox({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;

  final BorderRadius borderRadius;

  @override
  State<HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<HoverBox> {
  bool isHover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHover = true),
      onExit: (_) => setState(() => isHover = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isHover
              ? Theme.of(context).colorScheme.surfaceContainerLow
              : null,
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}

enum ButtonType { filled, outlined, text, normal }

class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.type,
    required this.child,
    this.isLoading = false,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    required this.onPressed,
  });

  const Button.filled({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.filled;

  const Button.outlined({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.outlined;

  const Button.text({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.text;

  const Button.normal({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height,
    this.padding,
    this.color,
    this.onPressedAt,
    this.isLoading = false,
  }) : type = ButtonType.normal;

  static Widget icon({
    Key? key,
    required Widget icon,
    required VoidCallback onPressed,
    double? size,
    Color? color,
    String? tooltip,
    bool isLoading = false,
    HitTestBehavior behavior = HitTestBehavior.deferToChild,
  }) {
    return _IconButton(
      key: key,
      icon: icon,
      onPressed: onPressed,
      size: size,
      color: color,
      tooltip: tooltip,
      behavior: behavior,
      isLoading: isLoading,
    );
  }

  final ButtonType type;

  final Widget child;

  final bool isLoading;

  final void Function() onPressed;

  final void Function(Offset location)? onPressedAt;

  final double? width;

  final double? height;

  final EdgeInsets? padding;

  final Color? color;

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  late bool isLoading;

  @override
  void initState() {
    super.initState();
    isLoading = widget.isLoading;
  }

  @override
  void didUpdateWidget(covariant Button oldWidget) {
    super.didUpdateWidget(oldWidget);
    isLoading = widget.isLoading;
  }

  void _handleTap() {
    widget.onPressed();
    final onPressedAt = widget.onPressedAt;
    if (onPressedAt != null) {
      final renderBox = context.findRenderObject() as RenderBox;
      onPressedAt(renderBox.localToGlobal(Offset.zero));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final backgroundColor = switch (widget.type) {
      ButtonType.filled => widget.color ?? colors.primary,
      ButtonType.normal => widget.color ?? colors.surfaceContainer,
      ButtonType.outlined || ButtonType.text => Colors.transparent,
    };
    final foregroundColor = switch (widget.type) {
      ButtonType.filled => colors.onPrimary,
      ButtonType.outlined || ButtonType.text => widget.color ?? colors.primary,
      ButtonType.normal => colors.onSurface,
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: widget.type == ButtonType.outlined
          ? BorderSide(color: widget.color ?? colors.outlineVariant)
          : BorderSide.none,
    );
    return Semantics(
      button: true,
      enabled: !isLoading,
      child: Material(
        type: MaterialType.button,
        color: backgroundColor,
        textStyle: theme.textTheme.labelLarge!.copyWith(color: foregroundColor),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        animationDuration: fastAnimationDuration,
        child: InkWell(
          customBorder: shape,
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: isLoading ? null : _handleTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 76, minHeight: 36),
            child: AnimatedSize(
              duration: fastAnimationDuration,
              child: SizedBox(
                width: widget.width,
                height: widget.height,
                child: Padding(
                  padding:
                      widget.padding ??
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    widthFactor: 1,
                    child: IconTheme(
                      data: IconThemeData(color: foregroundColor),
                      child: ButtonLoadingContent(
                        isLoading: isLoading,
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size,
    this.color,
    this.tooltip,
    this.isLoading = false,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget icon;
  final VoidCallback onPressed;
  final double? size;
  final String? tooltip;
  final Color? color;
  final HitTestBehavior behavior;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final iconSize = size ?? 24;
    final buttonIcon = isLoading
        ? const CircularProgressIndicator(
            strokeWidth: 1.5,
          ).paddingAll(2).fixWidth(iconSize).fixHeight(iconSize)
        : IconTheme(
            data: IconThemeData(
              size: iconSize,
              color: color ?? context.colorScheme.primary,
            ),
            child: icon,
          );
    final button = _IconButtonHitRegion(
      behavior: behavior,
      child: Semantics(
        button: true,
        enabled: !isLoading,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            customBorder: const CircleBorder(),
            highlightShape: BoxShape.circle,
            containedInkWell: true,
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: isLoading ? null : onPressed,
            child: Padding(padding: const EdgeInsets.all(6), child: buttonIcon),
          ),
        ),
      ),
    );
    final message = tooltip;
    return message != null && message.isNotEmpty
        ? Tooltip(message: message, child: button)
        : button;
  }
}

class _IconButtonHitRegion extends SingleChildRenderObjectWidget {
  const _IconButtonHitRegion({required this.behavior, required super.child});

  final HitTestBehavior behavior;

  @override
  _RenderIconButtonHitRegion createRenderObject(BuildContext context) =>
      _RenderIconButtonHitRegion(behavior);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderIconButtonHitRegion renderObject,
  ) {
    renderObject.behavior = behavior;
  }
}

class _RenderIconButtonHitRegion extends RenderProxyBox {
  _RenderIconButtonHitRegion(this.behavior);

  HitTestBehavior behavior;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (behavior == HitTestBehavior.opaque) {
      return super.hitTest(result, position: position);
    }
    // InkResponse's opaque tap target includes the corners outside the circle.
    final insideCircle = const CircleBorder()
        .getOuterPath(Offset.zero & size)
        .contains(position);
    if (!insideCircle && behavior == HitTestBehavior.deferToChild) return false;
    return super.hitTest(result, position: position) && insideCircle;
  }
}

class MenuButton extends StatefulWidget {
  const MenuButton({super.key, required this.entries});

  final List<MenuEntry> entries;

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_horiz),
      tooltip: 'more'.tl,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.padded),
      onPressed: () {
        final renderBox = context.findRenderObject() as RenderBox;
        final anchor = renderBox.localToGlobal(
          Offset(0, renderBox.size.height + 4),
        );
        showMenuX(context, anchor, widget.entries);
      },
    );
  }
}
