import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/foundation/translations.dart';

Future<String> _readReplacementContent(File file) async {
  const limit = 16 * 1024 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, limit + 1)) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Source replacement exceeds the text limit');
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: false);
}

String syncSourceIssueReasonText(String reason) {
  switch (reason) {
    case 'emptyScript':
      return 'Empty script file'.tl;
    case 'syntaxError':
      return 'Script syntax error'.tl;
    case 'missingEntryClass':
      return 'Missing entry class'.tl;
    case 'unsupportedHostApi':
      return 'Unsupported host API'.tl;
    case 'timeout':
      return 'Evaluation timeout'.tl;
    case 'memoryLimit':
      return 'Memory limit exceeded'.tl;
    case 'invalidKey':
      return 'Invalid comic source key'.tl;
    case 'evaluationError':
      return 'Script evaluation error'.tl;
    case 'runtimeFailure':
      return 'Runtime failure'.tl;
    case 'invalidSession':
      return 'Invalid session data'.tl;
    case 'readFailure':
      return 'File read failure'.tl;
    case 'identityMismatch':
      return 'Identity mismatch'.tl;
    case 'quarantineFailure':
    case 'quarantineFailed':
      return 'Failed to preserve the original source file'.tl;
    case 'metadataCorrupted':
      return 'Source metadata is corrupted'.tl;
    case 'journalCorrupted':
      return 'Source recovery journal is corrupted'.tl;
    case 'concurrentModification':
      return 'Source file changed during repair'.tl;
    case 'writeFailure':
      return 'Failed to write repaired source file'.tl;
    case 'runtimeReloadDeferred':
      return 'Runtime reload is deferred until source dependencies are available'
          .tl;
    case 'runtimeReloadFailed':
      return 'Source file was saved but runtime reload failed'.tl;
    case 'repairPending':
      return 'Source repair is pending'.tl;
    default:
      return 'Unknown source issue'.tl;
  }
}

Future<void> showSyncSourceIssuesDialog(
  BuildContext context, {
  required List<SyncSourceIssue> issues,
  required VoidCallback onRetry,
  required Future<Res<bool>> Function(
    SyncSourceIssue issue,
    String replacementContent,
  )
  onRepair,
  VoidCallback? onManageSources,
  String? description,
}) async {
  final currentIssues = List<SyncSourceIssue>.from(issues);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('Sync Source Issues'.tl)),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description ??
                        'Some synchronization data is unavailable. Other data can sync independently.'
                            .tl,
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (currentIssues.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Unavailable sync data has no repairable source file issue. Retry or manage comic sources.'
                            .tl,
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: currentIssues.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final issue = currentIssues[index];
                          final hasBackup = issue.backupPath != null;
                          final hasArchive = issue.archiveName != null;

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      issue.recovered
                                          ? Icons.check_circle_outline
                                          : Icons.error_outline,
                                      color: issue.recovered
                                          ? Colors.green
                                          : Theme.of(
                                              dialogContext,
                                            ).colorScheme.error,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        issue.filename,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    if (issue.recovered)
                                      Chip(
                                        label: Text('Recovered'.tl),
                                        visualDensity: VisualDensity.compact,
                                      )
                                    else if (hasBackup)
                                      Chip(
                                        label: Text('Backup available'.tl),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  syncSourceIssueReasonText(issue.reason),
                                  style: Theme.of(
                                    dialogContext,
                                  ).textTheme.bodySmall,
                                ),
                                if (hasArchive)
                                  Text(
                                    '${"Archive".tl}: ${issue.archiveName}',
                                    style: Theme.of(dialogContext)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            dialogContext,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                if (hasBackup)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${"Backup".tl}: ${p.basename(issue.backupPath!)}',
                                          style: Theme.of(dialogContext)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  dialogContext,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy, size: 16),
                                        tooltip: 'Copy path'.tl,
                                        onPressed: () {
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: issue.backupPath!,
                                            ),
                                          );
                                          context.showMessage(
                                            message:
                                                'Path copied to clipboard'.tl,
                                          );
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.download_outlined,
                                          size: 16,
                                        ),
                                        tooltip: 'Export Original Backup'.tl,
                                        onPressed: () async {
                                          try {
                                            final backup = File(
                                              issue.backupPath!,
                                            );
                                            if (!await backup.exists()) {
                                              if (!context.mounted) return;
                                              context.showMessage(
                                                message:
                                                    'Original backup is unavailable.'
                                                        .tl,
                                              );
                                              return;
                                            }
                                            final saved = await saveFile(
                                              file: backup,
                                              filename: p.basename(backup.path),
                                            );
                                            if (!context.mounted) return;
                                            if (saved) {
                                              context.showMessage(
                                                message:
                                                    'Original backup exported for forensic reference.'
                                                        .tl,
                                              );
                                            }
                                          } catch (_) {
                                            if (!context.mounted) return;
                                            context.showMessage(
                                              message:
                                                  'Original backup export failed.'
                                                      .tl,
                                            );
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                if (!issue.recovered) ...[
                                  if (issue.reason == 'journalCorrupted')
                                    Text(
                                      'The recovery journal is incomplete. Export the original files and backups, restore a complete journal matching the current quarantine, then retry. Do not delete the journal or reinstall sources to bypass recovery.'
                                          .tl,
                                    ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      const SizedBox(width: 8),
                                      TextButton.icon(
                                        icon: const Icon(
                                          Icons.file_upload_outlined,
                                          size: 16,
                                        ),
                                        label: Text('Replace with File'.tl),
                                        onPressed:
                                            issue.reason == 'journalCorrupted'
                                            ? null
                                            : () async {
                                                try {
                                                  final isSession = issue
                                                      .filename
                                                      .endsWith('.data');
                                                  final isMetadata =
                                                      issue.filename ==
                                                      SourceFileMetadata
                                                          .sidecarFileName;
                                                  final isJournal = issue
                                                      .filename
                                                      .endsWith('journal.json');
                                                  final selected =
                                                      await selectFile(
                                                        ext:
                                                            isSession ||
                                                                isMetadata ||
                                                                isJournal
                                                            ? [
                                                                'json',
                                                                'data',
                                                                'bak',
                                                              ]
                                                            : ['js', 'bak'],
                                                      );
                                                  if (selected == null) return;
                                                  if (!context.mounted) return;
                                                  final content =
                                                      await _readReplacementContent(
                                                        File(selected.path),
                                                      );
                                                  if (!context.mounted) return;
                                                  final res = await onRepair(
                                                    issue,
                                                    content,
                                                  );
                                                  if (!context.mounted) return;
                                                  if (res.success) {
                                                    setDialogState(() {
                                                      currentIssues.remove(
                                                        issue,
                                                      );
                                                    });
                                                    context.showMessage(
                                                      message:
                                                          'Source file repaired successfully.'
                                                              .tl,
                                                    );
                                                  } else {
                                                    context.showMessage(
                                                      message:
                                                          res
                                                              .errorMessage
                                                              ?.tl ??
                                                          'Source repair could not be completed. The original bytes remain available for export.'
                                                              .tl,
                                                    );
                                                  }
                                                } catch (_) {
                                                  if (!context.mounted) return;
                                                  context.showMessage(
                                                    message:
                                                        'Selected file could not be read or repaired. No successful repair was reported.'
                                                            .tl,
                                                  );
                                                }
                                              },
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  if (onManageSources != null) {
                    onManageSources();
                  } else {
                    context.to(() => const ComicSourcePage());
                  }
                },
                child: Text('Manage Comic Sources'.tl),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  onRetry();
                },
                child: Text('Retry Sync'.tl),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('Close'.tl),
              ),
            ],
          );
        },
      );
    },
  );
}
