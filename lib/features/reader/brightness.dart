import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/translations.dart';

const int readerBrightnessMin = 20;
const int readerBrightnessMax = 100;
const int defaultReaderBrightness = 50;

int normalizeReaderBrightness(Object? value) {
  final brightness = value is num ? value.round() : defaultReaderBrightness;
  return brightness.clamp(readerBrightnessMin, readerBrightnessMax);
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
  final ValueChanged<int> onBrightnessChanged;
  final ValueChanged<int>? onBrightnessChangeEnd;
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
                  trailing: Text('$normalizedBrightness%'),
                  subtitle: Row(
                    children: [
                      const Icon(Icons.brightness_low, size: 20),
                      Expanded(
                        child: Slider(
                          min: readerBrightnessMin.toDouble(),
                          max: readerBrightnessMax.toDouble(),
                          divisions:
                              (readerBrightnessMax - readerBrightnessMin) ~/ 5,
                          value: normalizedBrightness.toDouble(),
                          onChanged: (value) {
                            onBrightnessChanged(value.round());
                          },
                          onChangeEnd: (value) {
                            onBrightnessChangeEnd?.call(value.round());
                          },
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

  final bool enabled;
  final Object? brightness;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onBrightnessChanged;
  final ValueChanged<int> onBrightnessChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = normalizeReaderBrightness(brightness);
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
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
                            '${value.round()}%',
                        min: readerBrightnessMin.toDouble(),
                        max: readerBrightnessMax.toDouble(),
                        value: value.toDouble(),
                        divisions:
                            (readerBrightnessMax - readerBrightnessMin) ~/ 5,
                        onChanged: enabled
                            ? (value) => onBrightnessChanged(value.round())
                            : null,
                        onChangeEnd: enabled
                            ? (value) => onBrightnessChangeEnd(value.round())
                            : null,
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
                const SizedBox(height: 4),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
