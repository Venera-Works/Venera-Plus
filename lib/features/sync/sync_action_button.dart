import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/features/sync/sync_conflict_dialog.dart';
import 'package:venera_plus/foundation/translations.dart';

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
      if (!_sync.hasConflict) {
        final result = await _sync.syncNow();
        if (!mounted) return;
        if (!_sync.hasConflict) {
          context.showMessage(
            message: result.error
                ? '${"Sync failed".tl}: ${result.errorMessage?.tl ?? ""}'
                : 'Sync completed'.tl,
          );
          return;
        }
      }
      if (!mounted) return;
      await showSyncConflictDialog(context);
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
          tooltip: tooltip,
          onPressed: _handlePressed,
        );
      },
    );
  }
}
