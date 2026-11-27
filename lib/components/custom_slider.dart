import 'package:flutter/material.dart';

class CustomSlider extends StatefulWidget {
  const CustomSlider({
    required this.min,
    required this.max,
    required this.value,
    required this.divisions,
    required this.onChanged,
    required this.focusNode,
    this.reversed = false,
    super.key,
  });

  final double min;
  final double max;
  final double value;
  final int divisions;
  final void Function(double) onChanged;
  final FocusNode? focusNode;
  final bool reversed;

  @override
  State<CustomSlider> createState() => _CustomSliderState();
}

class _CustomSliderState extends State<CustomSlider> {
  static const _height = 48.0;
  static const _trackHeight = 6.0;
  static const _tickSize = 3.0;
  static const _haloSize = 40.0;

  bool _tapPending = false;
  double? _dragValue;

  @override
  void didUpdateWidget(CustomSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.divisions != widget.divisions ||
        oldWidget.reversed != widget.reversed) {
      _tapPending = false;
      _dragValue = null;
    }
  }

  void _setTapPending(bool pending) {
    if (_tapPending != pending) setState(() => _tapPending = pending);
  }

  void _seek(double dx, double width, {required bool dragging}) {
    final position = (dx / width).clamp(0.0, 1.0);
    final progress = widget.reversed ? 1 - position : position;
    final fraction = widget.divisions > 0
        ? (progress * widget.divisions).round() / widget.divisions
        : progress;
    final value = widget.min + (widget.max - widget.min) * fraction;
    if (dragging) {
      if (_dragValue == value) return;
      setState(() => _dragValue = value);
    }
    widget.onChanged(value);
  }

  void _endDrag() {
    if (_dragValue != null) setState(() => _dragValue = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final range = widget.max - widget.min;
          final enabled = range > 0 && width > 0;
          final value = _dragValue ?? widget.value;
          final progress = enabled
              ? ((value - widget.min) / range).clamp(0.0, 1.0)
              : 0.0;
          final activeWidth = width * progress;
          final thumbX = widget.reversed ? width - activeWidth : activeWidth;
          final gap = widget.divisions > 0 ? width / widget.divisions : 0.0;
          final pressed = _tapPending || _dragValue != null;

          return MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled ? (_) => _setTapPending(true) : null,
              onTapUp: enabled
                  ? (details) {
                      _setTapPending(false);
                      _seek(details.localPosition.dx, width, dragging: false);
                    }
                  : null,
              onTapCancel: enabled ? () => _setTapPending(false) : null,
              onHorizontalDragStart: enabled
                  ? (details) =>
                        _seek(details.localPosition.dx, width, dragging: true)
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) =>
                        _seek(details.localPosition.dx, width, dragging: true)
                  : null,
              onHorizontalDragEnd: enabled ? (_) => _endDrag() : null,
              onHorizontalDragCancel: enabled ? _endDrag : null,
              child: SizedBox(
                height: _height,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: enabled
                              ? colors.surfaceContainerHighest
                              : colors.onSurface.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(_trackHeight / 2),
                        ),
                        child: const SizedBox(
                          width: double.infinity,
                          height: _trackHeight,
                        ),
                      ),
                    ),
                    if (activeWidth > 0)
                      Positioned(
                        top: (_height - _trackHeight) / 2,
                        left: widget.reversed ? null : 0,
                        right: widget.reversed ? 0 : null,
                        width: activeWidth,
                        height: _trackHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(
                              _trackHeight / 2,
                            ),
                          ),
                        ),
                      ),
                    if (enabled && gap > 10)
                      for (var index = 1; index < widget.divisions; index++)
                        Positioned(
                          top: (_height - _tickSize) / 2,
                          left: index * gap - _tickSize / 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color:
                                  (widget.reversed
                                      ? index * gap >= thumbX
                                      : index * gap <= thumbX)
                                  ? colors.onPrimary.withValues(alpha: 0.32)
                                  : colors.onSurfaceVariant.withValues(
                                      alpha: 0.28,
                                    ),
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: _tickSize),
                          ),
                        ),
                    if (enabled)
                      Positioned(
                        top: (_height - _haloSize) / 2,
                        left: thumbX - _haloSize / 2,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: _haloSize,
                          height: _haloSize,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(
                              alpha: pressed ? 0.16 : 0,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: colors.shadow.withValues(alpha: 0.2),
                                  blurRadius: 5,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const SizedBox.square(dimension: 22),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
