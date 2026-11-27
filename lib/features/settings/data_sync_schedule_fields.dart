import 'package:flutter/material.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/translations.dart';

class DataSyncScheduleFields extends StatelessWidget {
  const DataSyncScheduleFields({
    super.key,
    required this.mode,
    required this.minutes,
    required this.onModeChanged,
    required this.onIntervalChanged,
  });

  final DataSyncMode mode;
  final int minutes;
  final ValueChanged<DataSyncMode> onModeChanged;
  final ValueChanged<int> onIntervalChanged;

  Widget _dropdown<T>(
    BuildContext context, {
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T> onChanged,
  }) => Stack(
    fit: StackFit.passthrough,
    clipBehavior: Clip.none,
    children: [
      Positioned.fill(
        child: InputDecorator(
          expands: true,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const SizedBox.shrink(),
        ),
      ),
      ButtonTheme(
        alignedDropdown: true,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(12),
            dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            menuMaxHeight: 320,
            padding: const EdgeInsetsDirectional.fromSTEB(0, 6, 8, 6),
            value: value,
            items: items,
            onChanged: (selected) {
              if (selected != null) onChanged(selected);
            },
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dropdown<DataSyncMode>(
          context,
          label: 'Sync Timing'.tl,
          value: mode,
          items: [
            DropdownMenuItem(
              value: DataSyncMode.manual,
              child: Text('Manual'.tl),
            ),
            DropdownMenuItem(
              value: DataSyncMode.realtime,
              child: Text('Real-time'.tl),
            ),
            DropdownMenuItem(
              value: DataSyncMode.scheduled,
              child: Text('Scheduled'.tl),
            ),
          ],
          onChanged: onModeChanged,
        ),
        if (mode == DataSyncMode.scheduled) ...[
          const SizedBox(height: 12),
          _dropdown<int>(
            context,
            label: 'Sync interval'.tl,
            value: minutes,
            items: [
              for (final interval in DataSync.intervalOptions)
                DropdownMenuItem(
                  value: interval,
                  child: Text(
                    '@minutes min'.tlParams({'minutes': '$interval'}),
                  ),
                ),
            ],
            onChanged: onIntervalChanged,
          ),
        ],
      ],
    );
  }
}
