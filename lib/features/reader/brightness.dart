import 'package:flutter/material.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/foundation/translations.dart';

const int readerBrightnessMin = 20;
const int readerBrightnessMax = 100;
const int defaultReaderBrightness = 50;

double normalizeReaderBrightness(Object? value) {
  final brightness = value is num ? value : defaultReaderBrightness;
  return brightness.clamp(readerBrightnessMin, readerBrightnessMax).toDouble();
}

double readerBrightnessOverlayOpacity({
  required bool enabled,
  required Object? brightness,
}) {
  if (!enabled) {
    return 0;
  }
  return 1 - normalizeReaderBrightness(brightness) / readerBrightnessMax;
}

class ReaderBrightnessOverlay extends StatelessWidget {
  const ReaderBrightnessOverlay({
    super.key,
    required this.enabled,
    required this.brightness,
  });

  final bool enabled;
  final Object? brightness;

  @override
  Widget build(BuildContext context) {
    final opacity = readerBrightnessOverlayOpacity(
      enabled: enabled,
      brightness: brightness,
    );
    if (opacity == 0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: SizedBox.expand(
        child: ColoredBox(color: Colors.black.withValues(alpha: opacity)),
      ),
    );
  }
}

class ReaderBrightnessControl extends StatelessWidget {
  const ReaderBrightnessControl({
    super.key,
    required this.enabled,
    required this.brightness,
    required this.onEnabledChanged,
    required this.onBrightnessChanged,
    this.onBrightnessChangeEnd,
    this.compact = false,
  });

  final bool enabled;
  final Object? brightness;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<double>? onBrightnessChangeEnd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final normalizedBrightness = normalizeReaderBrightness(brightness);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          contentPadding: compact ? EdgeInsets.zero : null,
          title: Text('Night dimming'.tl),
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: enabled
              ? ListTile(
                  contentPadding: compact ? EdgeInsets.zero : null,
                  title: Text('Reader brightness'.tl),
                  subtitle: Row(
                    children: [
                      const Icon(Icons.brightness_low, size: 20),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            showValueIndicator: ShowValueIndicator.onDrag,
                          ),
                          child: Slider(
                            min: readerBrightnessMin.toDouble(),
                            max: readerBrightnessMax.toDouble(),
                            value: normalizedBrightness,
                            label:
                                '${normalizedBrightness.toStringAsFixed(1)}%',
                            onChanged: onBrightnessChanged,
                            onChangeEnd: onBrightnessChangeEnd,
                          ),
                        ),
                      ),
                      const Icon(Icons.brightness_high, size: 20),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class ReaderBrightnessBar extends StatelessWidget {
  const ReaderBrightnessBar({
    super.key,
    required this.enabled,
    required this.brightness,
    required this.onEnabledChanged,
    required this.onBrightnessChanged,
    required this.onBrightnessChangeEnd,
  });

  static const _bottomPadding = 4.0;

  // 为滑轨保留 96 个逻辑像素，并留出开关的触控高度。
  static const minHeight = 96.0 + kMinInteractiveDimension + _bottomPadding;

  final bool enabled;
  final Object? brightness;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<double> onBrightnessChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = normalizeReaderBrightness(brightness);
    final borderRadius = BorderRadius.circular(16);
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 48,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: 8,
              right: 8,
              child: BlurEffect(
                borderRadius: borderRadius,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh.withValues(alpha: 0.88),
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: colors.outlineVariant,
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            Column(
              children: [
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                          disabledThumbRadius: 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 18,
                        ),
                        disabledActiveTrackColor: colors.onSurface.withValues(
                          alpha: 0.25,
                        ),
                        disabledInactiveTrackColor: colors.onSurface.withValues(
                          alpha: 0.12,
                        ),
                        disabledThumbColor: colors.onSurface.withValues(
                          alpha: 0.38,
                        ),
                      ),
                      child: Slider(
                        semanticFormatterCallback: (value) =>
                            '${value.toStringAsFixed(1)}%',
                        min: readerBrightnessMin.toDouble(),
                        max: readerBrightnessMax.toDouble(),
                        value: value,
                        onChanged: enabled ? onBrightnessChanged : null,
                        onChangeEnd: enabled ? onBrightnessChangeEnd : null,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Night dimming'.tl,
                  iconSize: 20,
                  isSelected: enabled,
                  color: enabled
                      ? colors.primary
                      : colors.onSurface.withValues(alpha: 0.38),
                  icon: const Icon(Icons.brightness_6),
                  selectedIcon: const Icon(Icons.brightness_4),
                  onPressed: () => onEnabledChanged(!enabled),
                ),
                const SizedBox(height: _bottomPadding),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
