import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:venera_plus/network/webdav.dart';

String _syncActionTimestamp(int timestamp) {
  if (timestamp <= 0) return 'Not synced yet'.tl;
  final value = DateTime.fromMillisecondsSinceEpoch(timestamp);
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
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
    if (_sync.isSyncing) _rotationController.repeat();
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncStatusChanged);
    _rotationController.dispose();
    super.dispose();
  }

  void _onSyncStatusChanged() {
    if (!mounted) return;
    if (_sync.isSyncing) {
      if (!_rotationController.isAnimating) _rotationController.repeat();
    } else if (_rotationController.isAnimating) {
      _rotationController
        ..stop()
        ..reset();
    }
  }

  String? _syncTarget() {
    final rawLocation = appdata.settings['syncRemoteLocation'];
    if (rawLocation is Map) {
      final location = RemoteLocation.fromJson(rawLocation);
      if (location.accountId.isNotEmpty) {
        final account = RemoteStorageAccounts.instance.account(
          location.accountId,
        );
        return '${account?.name ?? 'Account unavailable'.tl} · ${location.directory}';
      }
    }
    final config = appdata.settings['webdav'];
    if (config is! List || config.isEmpty || config.first is! String) {
      return null;
    }
    final uri = Uri.tryParse(
      normalizeWebDavEndpointUrl(config.first as String),
    );
    if (uri == null || uri.host.isEmpty) return null;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
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
    final action = await showDialog<_SyncAction>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: 'Sync Data'.tl,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Choose a sync action'.tl),
        ),
        actions: [
          TextButton(
            style: actionButtonStyle,
            onPressed: () =>
                Navigator.of(dialogContext).pop(_SyncAction.download),
            child: Text('Download'.tl),
          ),
          TextButton(
            style: actionButtonStyle,
            onPressed: () =>
                Navigator.of(dialogContext).pop(_SyncAction.upload),
            child: Text('Upload'.tl),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action == _SyncAction.download) {
      final target = _syncTarget();
      var confirmed = false;
      await showConfirmDialog(
        context: context,
        title: 'Restore from Cloud'.tl,
        content: [
          if (target != null)
            'Sync target: @target'.tlParams({'target': target}),
          'Restoring the cloud snapshot will overwrite local app data, including reading history and local favorites.'
              .tl,
        ].join('\n\n'),
        btnColor: context.colorScheme.error,
        onConfirm: () => confirmed = true,
      );
      if (!confirmed || !mounted) return;
    }
    final result = switch (action) {
      _SyncAction.upload => await _sync.uploadData(),
      _SyncAction.download => await _sync.downloadData(),
    };
    if (!mounted || !result.error) return;
    context.showMessage(message: result.errorMessage?.tl ?? 'Sync failed'.tl);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) {
        final status = _sync.statusSnapshot;
        final icon = RotationTransition(
          turns: _rotationController,
          child: Icon(
            status.lastError == null ? Icons.sync : Icons.sync_problem_outlined,
            color: status.lastError == null
                ? null
                : Theme.of(context).colorScheme.error,
          ),
        );
        final tooltip = status.isSyncing
            ? 'Syncing data...'.tl
            : status.lastError?.tl ??
                  '${'Last synced'.tl}: ${_syncActionTimestamp(status.lastSyncTime)}';
        return IconButton(
          key: const Key('data-sync-action'),
          icon: icon,
          tooltip: tooltip,
          onPressed: _handlePressed,
        );
      },
    );
  }
}

enum _SyncAction { upload, download }
