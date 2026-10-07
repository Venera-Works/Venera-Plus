import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_candidate_preview.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/foundation/translations.dart';

/// Safely formats a candidate value for preview in UI or tests, masking secrets.
String formatCandidateSafePreview({
  required String domain,
  required String field,
  required Object? value,
  required bool isDeleted,
  String? recordKey,
}) {
  if (isDeleted) {
    return 'Delete record'.tl;
  }
  if (field == 'presence') {
    return 'Keep record'.tl;
  }
  if (value == null) {
    return 'null';
  }

  if (domain == 'history' && field == 'progress') {
    if (value is Map) {
      final ep = value['ep'];
      final page = value['page'];
      if (ep != null && page != null) {
        return 'Episode @ep, Page @page'.tlParams({
          'ep': ep.toString(),
          'page': page.toString(),
        });
      } else if (ep != null) {
        return 'Episode @ep'.tlParams({'ep': ep.toString()});
      }
    }
  }

  if (domain == 'cookies') {
    if (value is List) {
      return 'Cookie session (@count cookies)'.tlParams({
        'count': value.length,
      });
    }
    return 'Cookie session data'.tl;
  }

  if (domain == 'sourceSession') {
    return 'Comic source session data'.tl;
  }

  if (domain == 'source') {
    if (value is Map) {
      final scriptMap = value['script'] is Map
          ? (value['script'] as Map)
          : value;
      final filename = scriptMap['filename']?.toString() ?? '';
      final version = scriptMap['version']?.toString() ?? '';
      final name = scriptMap['name']?.toString() ?? '';
      final parts = <String>[];
      if (name.isNotEmpty) parts.add(name);
      if (filename.isNotEmpty) parts.add(filename);
      if (version.isNotEmpty) parts.add('v$version');
      if (parts.isNotEmpty) {
        return 'Source script: @info'.tlParams({'info': parts.join(' - ')});
      }
    }
    return 'Comic source script'.tl;
  }

  if (syncCandidatePreviewIsProtected(
    domain: domain,
    field: field,
    recordKey: recordKey,
  )) {
    return '***protected setting value***'.tl;
  }

  if (value is num || value is bool) {
    return value.toString();
  }
  if (value is String) {
    if (value.length > 80) {
      return '${value.substring(0, 77)}...';
    }
    return value;
  }
  if (value is List) {
    return 'List (@count items)'.tlParams({'count': value.length});
  }
  if (value is Map) {
    return 'Map (@count keys)'.tlParams({'count': value.length});
  }
  return value.toString();
}

/// Shows the dialog to resolve sync conflicts item by item.
Future<void> showSyncConflictDialog(
  BuildContext context, {
  List<MergeConflict>? conflicts,
  Future<Res<bool>> Function({
    required String recordKey,
    required String field,
    required String candidateId,
  })?
  onResolve,
  DataSync? sync,
}) async {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => SyncConflictDialog(
      conflicts: conflicts,
      onResolve: onResolve,
      sync: sync,
    ),
  );
}

class SyncConflictDialog extends StatefulWidget {
  const SyncConflictDialog({
    super.key,
    this.conflicts,
    this.onResolve,
    this.sync,
  });

  /// Explicit conflicts list for an isolated dialog or test.
  final List<MergeConflict>? conflicts;

  /// Custom resolver callback for test verification.
  final Future<Res<bool>> Function({
    required String recordKey,
    required String field,
    required String candidateId,
  })?
  onResolve;

  /// Optional DataSync instance.
  final DataSync? sync;

  @override
  State<SyncConflictDialog> createState() => _SyncConflictDialogState();
}

class _SyncConflictDialogState extends State<SyncConflictDialog> {
  late final DataSync _sync = widget.sync ?? DataSync();
  List<MergeConflict>? _localConflicts;
  String? _resolvingCandidateId;
  String? _resolvingRecordKey;
  String? _resolvingField;

  @override
  void initState() {
    super.initState();
    if (widget.conflicts != null) {
      _localConflicts = List.of(widget.conflicts!);
    } else {
      _sync.addListener(_onSyncStateChanged);
    }
  }

  @override
  void dispose() {
    if (widget.conflicts == null) {
      _sync.removeListener(_onSyncStateChanged);
    }
    super.dispose();
  }

  void _onSyncStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  List<MergeConflict> get _activeConflicts =>
      _localConflicts ?? _sync.conflicts;

  String _formatDomain(String domain) {
    switch (domain) {
      case 'favorite':
        return 'Favorites'.tl;
      case 'folder':
        return 'Favorite Folders'.tl;
      case 'favoriteRole':
        return 'Folder Role'.tl;
      case 'history':
        return 'Reading History'.tl;
      case 'historyChapter':
        return 'Read Chapter'.tl;
      case 'imageFavorite':
        return 'Image Favorites'.tl;
      case 'setting':
        return 'Settings'.tl;
      case 'search':
        return 'Search History'.tl;
      case 'cookies':
        return 'Cookies'.tl;
      case 'source':
        return 'Comic Source'.tl;
      case 'sourceSession':
        return 'Comic Source Session'.tl;
      default:
        return domain;
    }
  }

  String _formatIdentity(String domain, List<Object?> identity) {
    if (identity.isEmpty) return '';
    switch (domain) {
      case 'folder':
        return identity.first?.toString() ?? '';
      case 'favorite':
        if (identity.length >= 2) {
          return '${identity[1]} (${identity[0]})';
        }
        return identity.join(' / ');
      case 'history':
        if (identity.length >= 2) {
          return '${identity[0]} [${identity[1]}]';
        }
        return identity.first?.toString() ?? '';
      case 'historyChapter':
        if (identity.length >= 3) {
          return '${identity[0]} - ${"Chapter @ep".tlParams({'ep': identity[2].toString()})}';
        }
        return identity.join(' / ');
      case 'imageFavorite':
        return identity.join(' / ');
      case 'setting':
        return identity.join('.');
      case 'cookies':
      case 'source':
      case 'sourceSession':
      case 'search':
        return identity.first?.toString() ?? '';
      default:
        return identity.join(' / ');
    }
  }

  String _formatFieldName(String field) {
    switch (field) {
      case 'presence':
        return 'Record existence'.tl;
      case 'progress':
        return 'Reading Progress'.tl;
      case 'value':
        return 'Value'.tl;
      case 'title':
        return 'Title'.tl;
      case 'name':
        return 'Name'.tl;
      case 'author':
        return 'Author'.tl;
      case 'order':
        return 'Display Order'.tl;
      case 'readDurationMs':
        return 'Read Duration'.tl;
      default:
        return field;
    }
  }

  String _formatCandidateValue({
    required String domain,
    required String field,
    required Object? value,
    required bool isDeleted,
    String? recordKey,
  }) {
    return formatCandidateSafePreview(
      domain: domain,
      field: field,
      value: value,
      isDeleted: isDeleted,
      recordKey: recordKey,
    );
  }

  Future<void> _resolveCandidate(
    MergeConflict conflict,
    MergeCandidate candidate,
  ) async {
    setState(() {
      _resolvingCandidateId = candidate.id;
      _resolvingRecordKey = conflict.recordKey;
      _resolvingField = conflict.field;
    });

    try {
      final res = widget.onResolve != null
          ? await widget.onResolve!(
              recordKey: conflict.recordKey,
              field: conflict.field,
              candidateId: candidate.id,
            )
          : await _sync.resolveConflict(
              recordKey: conflict.recordKey,
              field: conflict.field,
              candidateId: candidate.id,
            );

      if (!mounted) return;
      if (res.error) {
        context.showMessage(
          message:
              '${"Resolve failed".tl}: ${res.errorMessage?.tl ?? res.errorMessage ?? ""}',
        );
      } else {
        if (_localConflicts != null) {
          setState(() {
            _localConflicts!.removeWhere(
              (c) =>
                  c.recordKey == conflict.recordKey &&
                  c.field == conflict.field,
            );
          });
        }
        context.showMessage(message: 'Conflict resolved'.tl);
      }
    } finally {
      if (mounted) {
        setState(() {
          _resolvingCandidateId = null;
          _resolvingRecordKey = null;
          _resolvingField = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = _activeConflicts;
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    conflicts.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.sync_problem,
                    color: conflicts.isEmpty
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Resolve Sync Conflicts'.tl,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                conflicts.isEmpty
                    ? 'All conflicts resolved.'.tl
                    : 'Found @count conflict(s). Choose a candidate for each item to resolve.'
                          .tlParams({'count': conflicts.length}),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 16),
              if (conflicts.isEmpty) ...[
                const Spacer(),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'All conflicts resolved'.tl,
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Button.filled(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Done'.tl),
                ),
              ] else ...[
                Expanded(
                  child: ListView.separated(
                    itemCount: conflicts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final conflict = conflicts[index];
                      return _buildConflictCard(conflict, theme);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Button.outlined(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('Close'.tl),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConflictCard(MergeConflict conflict, ThemeData theme) {
    String domain = 'unknown';
    List<Object?> identity = [];
    try {
      domain = syncRecordDomain(conflict.recordKey);
      identity = syncRecordIdentity(conflict.recordKey);
    } catch (_) {
      try {
        final decoded = jsonDecode(conflict.recordKey);
        if (decoded is List && decoded.isNotEmpty) {
          domain = decoded.first.toString();
          identity = decoded.sublist(1);
        }
      } catch (_) {}
    }

    final domainLabel = _formatDomain(domain);
    final identityLabel = _formatIdentity(domain, identity);
    final fieldLabel = _formatFieldName(conflict.field);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    domainLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  identityLabel.isNotEmpty ? identityLabel : conflict.recordKey,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${"Field".tl}: $fieldLabel',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            ...conflict.candidates.map((cand) {
              final isResolvingThis =
                  _resolvingCandidateId == cand.id &&
                  _resolvingRecordKey == conflict.recordKey &&
                  _resolvingField == conflict.field;
              final isResolvingAny = _resolvingCandidateId != null;

              final valueLabel = _formatCandidateValue(
                domain: domain,
                field: conflict.field,
                value: cand.value,
                isDeleted: cand.isDeleted,
                recordKey: conflict.recordKey,
              );

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: cand.isDeleted
                        ? theme.colorScheme.error.withValues(alpha: 0.3)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          cand.isDeleted
                              ? Icons.delete_outline
                              : Icons.check_circle_outline,
                          size: 20,
                          color: cand.isDeleted
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: cand.actor,
                                      child: Text(
                                        '${"Device".tl}: ${cand.actor}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '#${cand.counter}',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                cand.isDeleted || conflict.field == 'presence'
                                    ? valueLabel
                                    : '${"Retain".tl}: $valueLabel',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cand.isDeleted
                                      ? theme.colorScheme.error
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Button.outlined(
                        key: ValueKey((
                          conflict.recordKey,
                          conflict.field,
                          cand.id,
                        )),
                        isLoading: isResolvingThis,
                        onPressed: () {
                          if (!isResolvingAny) {
                            _resolveCandidate(conflict, cand);
                          }
                        },
                        child: Text('Choose'.tl),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
