import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/features/sync/sync_conflict_dialog.dart';
import 'package:venera_plus/features/sync/sync_source_issues_dialog.dart';
import 'package:venera_plus/features/sync/merge_store_error.dart';
import 'package:venera_plus/foundation/translations.dart';

enum _SyncConflictAction { resolve, sync }

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
    'Sync Conflict (@count pending)'.tlParams({'count': status.conflictCount}),
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

  Future<_SyncConflictAction?> _showConflictSyncActions(
    DataSyncStatusSnapshot status,
  ) => showDialog<_SyncConflictAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        'Sync Conflict (@count pending)'.tlParams({
          'count': status.conflictCount,
        }),
      ),
      content: SingleChildScrollView(
        child: Text(_syncActionStatusSummary(status)),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_SyncConflictAction.resolve),
          child: Text('Resolve conflicts'.tl),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_SyncConflictAction.sync),
          child: Text('Sync now'.tl),
        ),
      ],
    ),
  );

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
      final currentSnapshot = _sync.statusSnapshot;
      if (currentSnapshot.hasConflict) {
        final action = await _showConflictSyncActions(currentSnapshot);
        if (!mounted || action == null) return;
        if (action == _SyncConflictAction.resolve) {
          await showSyncConflictDialog(context);
          return;
        }
      }
      if (currentSnapshot.isPartial) {
        if (!mounted) return;
        await showSyncSourceIssuesDialog(
          context,
          issues: currentSnapshot.sourceIssues,
          onRepair: (issue, content) => _sync.repairSourceIssue(
            issue: issue,
            replacementContent: content,
          ),
          onRetry: () => unawaited(_sync.syncNow()),
          description:
              'Some synchronization data is unavailable. Other data can sync independently.'
                  .tl,
        );
        return;
      }
      final result = await _sync.syncNow();
      if (!mounted) return;
      if (_sync.hasConflict) {
        await showSyncConflictDialog(context);
        return;
      }
      final snapshot = _sync.statusSnapshot;
      if (snapshot.isPartial && result.success) {
        context.showMessage(message: 'Sync completed partially'.tl);
        if (mounted) {
          await showSyncSourceIssuesDialog(
            context,
            issues: snapshot.sourceIssues,
            onRepair: (issue, content) => _sync.repairSourceIssue(
              issue: issue,
              replacementContent: content,
            ),
            onRetry: () => unawaited(_sync.syncNow()),
            description:
                'Sync completed partially. Unaffected data was synchronized successfully.'
                    .tl,
          );
        }
      } else {
        context.showMessage(
          message: result.error
              ? '${"Sync failed".tl}: ${mergeStoreErrorSummary(result.errorMessage)?.tl ?? ""}'
              : 'Sync completed'.tl,
        );
      }
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
        } else if (status.hasConflict) {
          iconData = Icons.sync_problem;
          tooltip = status.conflictCount > 0
              ? 'Sync Conflict (@count pending)'.tlParams({
                  'count': status.conflictCount,
                })
              : 'Sync Conflict'.tl;
          iconColor = Theme.of(context).colorScheme.error;
        } else if (status.lastError != null) {
          iconData = Icons.sync_problem_outlined;
          tooltip = mergeStoreErrorSummary(status.lastError)!.tl;
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
