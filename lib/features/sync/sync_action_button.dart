import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/features/sync/sync_conflict_dialog.dart';
import 'package:venera_plus/features/sync/merge_store_error.dart';
import 'package:venera_plus/foundation/translations.dart';

String _syncActionTimestamp(int timestamp) {
  if (timestamp <= 0) return 'Not synced yet'.tl;
  final value = DateTime.fromMillisecondsSinceEpoch(timestamp);
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

String _syncActionTriggerLabel(String? trigger) {
  final label = switch (trigger) {
    'Manual sync' => 'Manual sync',
    'Local changes' => 'Local changes',
    'Scheduled sync' => 'Scheduled sync',
    'Startup check' => 'Startup check',
    'Resume check' => 'Resume check',
    'Remote check' => 'Remote check',
    'Retry' => 'Retry',
    _ => null,
  };
  if (label != null) return label.tl;
  if (trigger == null || trigger.isEmpty) return 'Not synced yet'.tl;
  return 'Other sync trigger: @trigger'.tlParams({'trigger': trigger});
}

String _syncReviewLabel(DataSyncStatusSnapshot status) {
  if (status.unmappableProgressRecordKeys.isNotEmpty) {
    return 'Review sync items'.tl;
  }
  if (status.conflictCount > 0 && status.pendingProgressCount > 0) {
    return 'Review conflicts and pending progress'.tl;
  }
  if (status.pendingProgressCount > 0) return 'View pending progress'.tl;
  return 'Resolve conflicts'.tl;
}

bool _hasSyncReviewItems(DataSyncStatusSnapshot status) =>
    status.conflictCount > 0 || status.pendingProgressCount > 0;

String _syncActionStatusSummary(DataSyncStatusSnapshot status) {
  final counts = status.changedRecordCounts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final countSummary = counts.isEmpty
      ? 'No captured record changes'.tl
      : counts.map((entry) => '${entry.key}: ${entry.value}').join(', ');
  return [
    if (status.lastError != null) mergeStoreErrorSummary(status.lastError)!.tl,
    'Last trigger: @trigger'.tlParams({
      'trigger': _syncActionTriggerLabel(status.lastTrigger),
    }),
    'Last successful sync: @time'.tlParams({
      'time': _syncActionTimestamp(status.lastSuccessTime),
    }),
    'Pending publication records: @count'.tlParams({
      'count': status.pendingChangeCount,
    }),
    'Manual conflicts requiring review: @count'.tlParams({
      'count': status.conflictCount,
    }),
    'Reading positions waiting for directory: @count'.tlParams({
      'count': status.pendingProgressCount,
    }),
    'Within manual review: @count reading positions need chapter selection'
        .tlParams({'count': status.unmappableProgressCount}),
    'Reading positions automatically reconciled: @count'.tlParams({
      'count': status.automaticallyResolvedProgressCount,
    }),
    'Changed records: @counts'.tlParams({'counts': countSummary}),
    'Last sync duration: @duration ms'.tlParams({
      'duration': status.lastSyncDurationMs,
    }),
    'Uploaded: @bytes bytes in @objects objects'.tlParams({
      'bytes': status.uploadedBytes,
      'objects': status.uploadedObjects,
    }),
    'Downloaded: @bytes bytes in @objects objects'.tlParams({
      'bytes': status.downloadedBytes,
      'objects': status.downloadedObjects,
    }),
  ].join('\n');
}

class SyncActionButton extends StatefulWidget {
  const SyncActionButton({super.key, required this.onConfigure});

  final Future<void> Function() onConfigure;

  @override
  State<SyncActionButton> createState() => _SyncActionButtonState();
}

class _SyncActionButtonState extends State<SyncActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final DataSync _sync;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _sync = DataSync();
    _sync.addListener(_onSyncStatusChanged);
    if (_sync.statusSnapshot.isSyncing) {
      _rotationController.repeat();
    }
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncStatusChanged);
    _rotationController.dispose();
    super.dispose();
  }

  void _onSyncStatusChanged() {
    if (!mounted) return;
    final isSyncing = _sync.isSyncing;
    if (isSyncing) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else {
      if (_rotationController.isAnimating) {
        _rotationController.stop();
        _rotationController.reset();
      }
    }
  }

  Future<void> _showStatusDetails(DataSyncStatusSnapshot status) =>
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('data-sync-status-details'),
          title: Text('Sync status'.tl),
          content: SingleChildScrollView(
            child: Text(_syncActionStatusSummary(status)),
          ),
          actions: [
            if (_hasSyncReviewItems(status))
              TextButton(
                key: const Key('data-sync-status-review-conflicts'),
                onPressed: () => showSyncConflictDialog(context),
                child: Text(_syncReviewLabel(status)),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Close'.tl),
            ),
          ],
        ),
      );

  Future<void> _handlePressed() async {
    if (_sync.isSyncing) {
      context.showMessage(message: 'Sync is currently in progress'.tl);
      return;
    }
    if (!_sync.hasConfiguration) {
      await widget.onConfigure();
      return;
    }
    if (!_sync.beginInteraction()) return;
    try {
      final result = await _sync.syncNow();
      if (!mounted) return;
      if (result.error) {
        final error = mergeStoreErrorSummary(result.errorMessage)?.tl;
        context.showMessage(
          message: error == null || error.isEmpty
              ? 'Sync failed'.tl
              : '${'Sync failed'.tl}: $error',
        );
        return;
      }
      context.showMessage(message: _sync.statusSnapshot.completionSummary);
    } finally {
      _sync.endInteraction();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) {
        final status = _sync.statusSnapshot;

        final IconData iconData;
        final String tooltip;
        Color? iconColor;

        if (status.isSyncing) {
          iconData = Icons.sync;
          tooltip = 'Syncing data...'.tl;
        } else if (!status.isConfigured) {
          iconData = Icons.cloud_off_outlined;
          tooltip = 'WebDAV is not configured. Please configure it first.'.tl;
        } else if (status.lastError != null) {
          iconData = Icons.sync_problem_outlined;
          tooltip = mergeStoreErrorSummary(status.lastError)!.tl;
          iconColor = Theme.of(context).colorScheme.error;
        } else if (status.hasConflict) {
          iconData = Icons.sync_problem;
          tooltip = 'Manual conflicts requiring review: @count'.tlParams({
            'count': status.conflictCount,
          });
          iconColor = Theme.of(context).colorScheme.error;
        } else if (status.isPartial) {
          iconData = Icons.sync_problem_outlined;
          tooltip = status.sourceIssues.isNotEmpty
              ? 'Sync completed with source issues (@count). Tap for details.'
                    .tlParams({'count': status.sourceIssues.length})
              : 'Sync completed with source issues. Tap to manage sources.'.tl;
          iconColor = Theme.of(context).colorScheme.tertiary;
        } else {
          iconData = Icons.sync;
          tooltip = 'Sync Data'.tl;
        }

        Widget iconWidget = Icon(iconData, color: iconColor);

        if (status.isSyncing) {
          iconWidget = RotationTransition(
            turns: _rotationController,
            child: iconWidget,
          );
        }

        return IconButton(
          key: const Key('data-sync-action'),
          icon: iconWidget,
          tooltip: '$tooltip\n${_syncActionStatusSummary(status)}',
          onPressed: _handlePressed,
          onLongPress: () => _showStatusDetails(status),
        );
      },
    );
  }
}
