import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'consts.dart';
import 'gesture.dart';

class Select extends StatelessWidget {
  const Select({
    super.key,
    required this.current,
    required this.values,
    this.onTap,
    this.minWidth,
    this.selectedIndex,
  });

  final String? current;

  final List<String> values;

  final void Function(int index)? onTap;

  final double? minWidth;

  /// 已知实际索引时，可用它区分同名选项。
  final int? selectedIndex;

  static const _maxMenuWidth = 280.0;

  Future<void> _showOptions(BuildContext context) async {
    final renderBox = context.findRenderObject() as RenderBox;
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final screenSize = overlay.size;
    final offset = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = (offset & size).translate(0, size.height + 2);
    final maxWidth = math.max(
      0.0,
      math.min(_maxMenuWidth, screenSize.width - 32),
    );
    final currentLabel = current;
    final currentIndex =
        selectedIndex ??
        (currentLabel == null ? null : values.indexOf(currentLabel));
    final colors = context.colorScheme;

    final value = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      elevation: 3,
      color: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        minWidth: math.min(maxWidth, math.max(size.width, 136.0)),
        maxWidth: maxWidth,
        maxHeight: math.min(360.0, screenSize.height * 0.6),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & screenSize),
      initialValue: currentIndex,
      items: [
        for (var index = 0; index < values.length; index++)
          PopupMenuItem<int>(
            height: App.isMobile ? 46 : 40,
            value: index,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    values[index],
                    style: index == currentIndex
                        ? TextStyle(color: colors.primary)
                        : null,
                  ),
                ),
                if (index == currentIndex) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 18, color: colors.primary),
                ],
              ],
            ),
          ),
      ],
    );
    if (value != null && context.mounted) onTap?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    const borderRadius = BorderRadius.all(Radius.circular(8));
    final minimumWidth = minWidth ?? 0.0;
    final maxWidth = math.max(
      minimumWidth,
      math.min(_maxMenuWidth, context.width / 2),
    );
    return Container(
      constraints: BoxConstraints(minWidth: minimumWidth, maxWidth: maxWidth),
      decoration: BoxDecoration(
        border: Border.all(color: context.colorScheme.outlineVariant),
        borderRadius: borderRadius,
      ),
      child: ClickInkWell(
        borderRadius: borderRadius,
        onTap: values.isEmpty ? null : () => _showOptions(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                current ?? ' ',
                style: ts.s14,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_drop_down, color: context.colorScheme.primary),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
      ),
    );
  }
}

class FilterChipFixedWidth extends StatefulWidget {
  const FilterChipFixedWidth({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final Widget label;

  final bool selected;

  final void Function(bool) onSelected;

  @override
  State<FilterChipFixedWidth> createState() => _FilterChipFixedWidthState();
}

class _FilterChipFixedWidthState extends State<FilterChipFixedWidth> {
  bool get selected => widget.selected;

  double? labelWidth;

  double? labelHeight;

  var key = GlobalKey();

  @override
  void initState() {
    Future.microtask(measureSize);
    super.initState();
  }

  void measureSize() {
    final RenderBox renderBox =
        key.currentContext!.findRenderObject() as RenderBox;
    labelWidth = renderBox.size.width;
    labelHeight = renderBox.size.height;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      textStyle: Theme.of(context).textTheme.labelLarge,
      child: ClickInkWell(
        onTap: () => widget.onSelected(true),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: AnimatedContainer(
          duration: fastAnimationDuration,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: labelWidth == null ? firstBuild() : buildContent(),
        ),
      ),
    );
  }

  Widget firstBuild() {
    return Center(
      child: SizedBox(key: key, child: widget.label),
    );
  }

  Widget buildContent() {
    const iconSize = 18.0;
    const gap = 4.0;
    return SizedBox(
      width: iconSize + labelWidth! + gap,
      height: math.max(iconSize, labelHeight!),
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: fastAnimationDuration,
            left: selected ? (iconSize + gap) : (iconSize + gap) / 2,
            child: widget.label,
          ),
          if (selected)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: labelWidth! + gap,
              child: const AnimatedCheckIcon(size: iconSize).toCenter(),
            ),
        ],
      ),
    );
  }
}

class AnimatedCheckWidget extends AnimatedWidget {
  const AnimatedCheckWidget({
    super.key,
    required Animation<double> animation,
    this.size,
  }) : super(listenable: animation);

  final double? size;

  @override
  Widget build(BuildContext context) {
    var iconSize = size ?? IconTheme.of(context).size ?? 25;
    final animation = listenable as Animation<double>;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: animation.value,
          child: ClipRRect(
            child: Icon(
              Icons.check,
              size: iconSize,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class AnimatedCheckIcon extends StatefulWidget {
  const AnimatedCheckIcon({this.size, super.key});

  final double? size;

  @override
  State<AnimatedCheckIcon> createState() => _AnimatedCheckIconState();
}

class _AnimatedCheckIconState extends State<AnimatedCheckIcon>
    with SingleTickerProviderStateMixin {
  late Animation<double> animation;
  late AnimationController controller;

  @override
  void initState() {
    controller = AnimationController(
      vsync: this,
      duration: fastAnimationDuration,
    );
    animation = Tween<double>(begin: 0, end: 1).animate(controller)
      ..addListener(() {
        setState(() {});
      });
    controller.forward();
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedCheckWidget(animation: animation, size: widget.size);
  }
}

class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.text,
    required this.isSelected,
    required this.onTap,
  });

  final String text;

  final bool isSelected;

  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: fastAnimationDuration,
      decoration: BoxDecoration(
        color: isSelected
            ? context.colorScheme.secondaryContainer
            : context.colorScheme.surface,
        border: isSelected
            ? Border.all(color: context.colorScheme.secondaryContainer)
            : Border.all(color: context.colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.transparent,
        child: ClickInkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(text),
          ),
        ),
      ),
    );
  }
}
