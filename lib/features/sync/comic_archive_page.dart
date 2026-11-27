import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/sync/comic_backup.dart';
import 'comic_archive_transfer_dialog.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class ComicArchivePage extends StatefulWidget {
  const ComicArchivePage({super.key});

  @override
  State<ComicArchivePage> createState() => _ComicArchivePageState();
}

class _ComicArchivePageState extends State<ComicArchivePage> {
  List<BackupFile> files = [];
  final selected = <BackupFile>{};
  bool isLoading = true;
  bool isWorking = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      isLoading = true;
      error = null;
      selected.clear();
    });
    final result = await ComicBackupManager.listBackups();
    if (!mounted) return;
    setState(() {
      isLoading = false;
      if (result.error) {
        error = result.errorMessage;
      } else {
        files = result.data;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Comic Archive".tl),
        actions: [
          IconButton(
            tooltip: "Refresh".tl,
            onPressed: isLoading || isWorking ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: buildBody()),
          if (selected.isNotEmpty) buildActions(),
        ],
      ),
    );
  }

  Widget buildBody() {
    if (isLoading) {
      return const ListLoadingIndicator().toCenter();
    }
    if (error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: refresh, child: Text("Retry".tl)),
        ],
      ).paddingHorizontal(16);
    }
    if (files.isEmpty) {
      return Center(child: Text("No archive files".tl));
    }
    return ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        return CheckboxListTile(
          value: selected.contains(file),
          onChanged: isWorking
              ? null
              : (value) {
                  setState(() {
                    if (value == true) {
                      selected.add(file);
                    } else {
                      selected.remove(file);
                    }
                  });
                },
          title: Text(file.name),
          subtitle: Text(
            '${bytesToReadableString(file.size)} · ${_formatTime(file.modified)}',
          ),
        );
      },
    );
  }

  Widget buildActions() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isWorking ? null : restoreSelected,
                icon: const Icon(Icons.download),
                label: Text("Download and Import".tl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isWorking ? null : deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: Text("Delete".tl),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> restoreSelected() async {
    final targets = selected.toList();
    if (targets.isEmpty) return;
    final result = await showComicArchiveTransferDialog(
      context,
      title: "Download and Import".tl,
      batch: ComicBackupManager.createRestoreBatch(targets),
    );
    if (!mounted) return;
    setState(() {
      selected.clear();
    });
    context.showMessage(
      message: 'Success: @a, Failed: @b'.tlParams({
        'a': result.success,
        'b': result.failed,
      }),
    );
  }

  Future<void> deleteSelected() async {
    final targets = selected.toList();
    if (targets.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: "Delete".tl,
        content: Text(
          "Delete selected archive files?".tl,
        ).paddingHorizontal(16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colorScheme.error,
              foregroundColor: context.colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => isWorking = true);
    var cancelled = false;
    var deleted = 0;
    var failed = 0;
    var currentTitle = '';
    final controller = showLoadingDialog(
      context,
      message: 'Delete'.tl,
      withProgress: true,
      barrierDismissible: false,
      closeOnCancel: false,
      onCancel: () => cancelled = true,
      progressDetails: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("${deleted + failed} / ${targets.length}"),
          const SizedBox(height: 8),
          Text(currentTitle, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
    try {
      for (final file in targets) {
        if (cancelled) break;
        currentTitle = file.name;
        controller.setProgress((deleted + failed) / targets.length);
        try {
          final result = await ComicBackupManager.deleteBackup(file);
          if (result.error) {
            failed++;
          } else {
            deleted++;
          }
        } catch (error, stack) {
          failed++;
          Log.error('Delete archive file', error, stack);
        }
      }
    } finally {
      controller.close();
      if (mounted) setState(() => isWorking = false);
    }
    if (!mounted) return;
    context.showMessage(
      message: 'Deleted: @a, Failed: @b, Not started: @c'.tlParams({
        'a': deleted,
        'b': failed,
        'c': targets.length - deleted - failed,
      }),
    );
    await refresh();
  }

  static String _formatTime(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}
