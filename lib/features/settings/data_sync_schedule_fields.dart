import 'package:flutter/material.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/translations.dart';

class DataSyncScheduleFields extends StatelessWidget {
  const DataSyncScheduleFields({
    super.key,
    required this.direction,
    required this.timing,
    required this.minutes,
    required this.onDirectionChanged,
    required this.onTimingChanged,
    required this.onIntervalChanged,
  });

  final SyncDirection direction;
  final SyncTiming timing;
  final int minutes;
  final ValueChanged<SyncDirection> onDirectionChanged;
  final ValueChanged<SyncTiming> onTimingChanged;
  final ValueChanged<int> onIntervalChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Sync Direction'.tl,
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SyncDirection>(
              isExpanded: true,
              value: direction,
              items: [
                DropdownMenuItem(
                  value: SyncDirection.bidirectional,
                  child: Text('Bidirectional'.tl),
                ),
                DropdownMenuItem(
                  value: SyncDirection.uploadOnly,
                  child: Text('Upload only'.tl),
                ),
                DropdownMenuItem(
                  value: SyncDirection.downloadOnly,
                  child: Text('Download only'.tl),
                ),
              ],
              onChanged: (value) {
                if (value != null) onDirectionChanged(value);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Sync Timing'.tl,
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SyncTiming>(
              isExpanded: true,
              value: timing,
              items: [
                DropdownMenuItem(
                  value: SyncTiming.manual,
                  child: Text('Manual'.tl),
                ),
                DropdownMenuItem(
                  value: SyncTiming.realtime,
                  child: Text('Real-time'.tl),
                ),
                DropdownMenuItem(
                  value: SyncTiming.scheduled,
                  child: Text('Scheduled'.tl),
                ),
              ],
              onChanged: (value) {
                if (value != null) onTimingChanged(value);
              },
            ),
          ),
        ),
        if (timing == SyncTiming.scheduled) ...[
          const SizedBox(height: 16),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Sync interval'.tl,
              border: const OutlineInputBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isExpanded: true,
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
                onChanged: (value) {
                  if (value != null) onIntervalChanged(value);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Syncs at the selected interval while the app is running, following the selected direction. Overdue syncs run when the app reopens. Conflicts require an explicit snapshot choice.'
                .tl,
          ),
        ],
      ],
    );
  }
}
