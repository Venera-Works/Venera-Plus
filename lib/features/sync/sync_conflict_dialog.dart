import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_candidate_preview.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/foundation/translations.dart';

const _preferredSettingActorKey = 'syncPreferredSettingActor';

/// Safely formats a candidate value for preview in UI or tests, masking secrets.
String _formatProgressTime(num timestamp) {
  const maximumDateTimeMs = 8640000000000000;
  if (!timestamp.isFinite ||
      timestamp < -maximumDateTimeMs ||
      timestamp > maximumDateTimeMs ||
      timestamp != timestamp.toInt()) {
    return timestamp.toString();
  }
  try {
    final time = DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt(),
    ).toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  } on ArgumentError {
    return timestamp.toString();
  }
}

String formatCandidateSafePreview({
  required String domain,
  required String field,
  required Object? value,
  required bool isDeleted,
  String? recordKey,
}) {
  if (isDeleted) {
    return field == 'presence'
        ? 'Delete record'.tl
        : 'Delete field (other fields are retained)'.tl;
  }
  if (field == 'presence') {
    return 'Keep record'.tl;
  }
  if (value == null) {
    return 'null';
  }

  if (domain == 'history' && field == 'progress' && value is Map) {
    final parts = <String>[];
    final ep = value['ep'];
    final page = value['page'];
    if (ep != null && page != null) {
      parts.add(
        'Episode @ep, Page @page'.tlParams({
          'ep': ep.toString(),
          'page': page.toString(),
        }),
      );
    } else if (ep != null) {
      parts.add('Episode @ep'.tlParams({'ep': ep.toString()}));
    }
    final group = value['group'];
    if (group != null) {
      parts.add('Group @group'.tlParams({'group': group.toString()}));
    }
    final time = value['time'];
    if (time is num) {
      parts.add('Time @time'.tlParams({'time': _formatProgressTime(time)}));
    }
    if (parts.isNotEmpty) return parts.join(' · ');
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

/// Stages conflict choices for batch resolution.
Future<void> showSyncConflictDialog(
  BuildContext context, {
  List<MergeConflict>? conflicts,
  Future<Res<bool>> Function(List<MergeConflictResolution>)? onResolve,
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
    this.localRecords,
  });

  /// Explicit conflicts list for an isolated dialog or test.
  final List<MergeConflict>? conflicts;

  /// Custom batch resolver callback for test verification.
  final Future<Res<bool>> Function(List<MergeConflictResolution>)? onResolve;

  /// Optional DataSync instance.
  final DataSync? sync;

  /// Local snapshot override for isolated widget tests.
  final SyncRecords? localRecords;

  @override
  State<SyncConflictDialog> createState() => _SyncConflictDialogState();
}

class _SyncConflictDialogState extends State<SyncConflictDialog> {
  late final DataSync _sync = widget.sync ?? DataSync();
  List<MergeConflict>? _localConflicts;
  final TextEditingController _searchController = TextEditingController();
  final Map<
    (String, String),
    ({
      String candidateId,
      Set<String> candidateIds,
      String candidateFingerprint,
    })
  >
  _selectedCandidates = {};
  String _searchQuery = '';
  String? _groupFilter;
  String? _bulkActor;
  String? _lastBulkSelectedActor;
  final Set<(String, String)> _lastBulkSelectedKeys = {};
  bool _onlyUnselected = false;
  bool _rememberSettingDevice = false;
  bool _isSubmitting = false;
  bool _isClearingPreference = false;

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
  void didUpdateWidget(covariant SyncConflictDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conflicts == widget.conflicts) return;
    if (oldWidget.conflicts == null) _sync.removeListener(_onSyncStateChanged);
    if (widget.conflicts == null) _sync.addListener(_onSyncStateChanged);
    _localConflicts = widget.conflicts == null
        ? null
        : List.of(widget.conflicts!);
    _retainValidSelections(_activeConflicts);
  }

  @override
  void dispose() {
    if (widget.conflicts == null) {
      _sync.removeListener(_onSyncStateChanged);
    }
    _searchController.dispose();
    super.dispose();
  }

  void _onSyncStateChanged() {
    if (!mounted) return;
    _retainValidSelections(_activeConflicts);
    setState(() {});
  }

  List<MergeConflict> get _activeConflicts =>
      _localConflicts ?? _sync.conflicts;

  SyncRecords get _localCurrentRecords =>
      widget.localRecords ?? _sync.localObservedRecords;

  String? get _savedPreferredSettingActor {
    final actor = appdata.implicitData[_preferredSettingActorKey];
    return actor is String && actor.isNotEmpty ? actor : null;
  }

  String _deviceName(String actor) {
    final name = _sync.deviceNames[actor]?.trim();
    return name == null || name.isEmpty ? actor : name;
  }

  String _domainOf(MergeConflict conflict) {
    try {
      return syncRecordDomain(conflict.recordKey);
    } catch (_) {
      return 'unknown';
    }
  }

  bool _sameCandidateIds(Set<String> selected, MergeConflict conflict) =>
      selected.length == conflict.candidates.length &&
      conflict.candidates.every((candidate) => selected.contains(candidate.id));

  bool _selectionIsCurrent(MergeConflict conflict) {
    final selected = _selectedCandidates[(conflict.recordKey, conflict.field)];
    return selected != null &&
        _sameCandidateIds(selected.candidateIds, conflict) &&
        selected.candidateFingerprint == conflict.candidateFingerprint &&
        conflict.candidates.any(
          (candidate) => candidate.id == selected.candidateId,
        );
  }

  void _retainValidSelections(List<MergeConflict> conflicts) {
    final active = {
      for (final conflict in conflicts)
        (conflict.recordKey, conflict.field): conflict,
    };
    _selectedCandidates.removeWhere((key, selected) {
      final conflict = active[key];
      return conflict == null ||
          !_sameCandidateIds(selected.candidateIds, conflict) ||
          conflict.candidateFingerprint != selected.candidateFingerprint ||
          !conflict.candidates.any(
            (candidate) => candidate.id == selected.candidateId,
          );
    });
  }

  List<MergeConflict> _selectedConflicts(List<MergeConflict> conflicts) => [
    for (final conflict in conflicts)
      if (_selectionIsCurrent(conflict)) conflict,
  ];
  List<MergeConflict> _visibleConflicts(List<MergeConflict> conflicts) {
    final domains = conflicts.map(_domainOf).toSet();
    final group = domains.contains(_groupFilter) ? _groupFilter : null;
    final query = _searchQuery.trim().toLowerCase();
    final visible = <MergeConflict>[];
    for (final conflict in conflicts) {
      if (group != null && _domainOf(conflict) != group) continue;
      if (_onlyUnselected && _selectionIsCurrent(conflict)) continue;
      if (query.isNotEmpty && !_matchesSearch(conflict, query)) continue;
      visible.add(conflict);
    }
    return visible;
  }

  MergeCandidate? _chosenCandidate(MergeConflict conflict) {
    final selection = _selectedCandidates[(conflict.recordKey, conflict.field)];
    if (selection == null) return null;
    for (final candidate in conflict.candidates) {
      if (candidate.id == selection.candidateId) return candidate;
    }
    return null;
  }

  bool _isOrdinarySettingCandidate(
    MergeConflict conflict,
    MergeCandidate candidate,
  ) =>
      _domainOf(conflict) == 'setting' &&
      conflict.field != 'presence' &&
      !candidate.isDeleted &&
      !syncCandidatePreviewIsProtected(
        domain: 'setting',
        field: conflict.field,
        recordKey: conflict.recordKey,
      );

  bool get _canRememberSelectedDevice {
    final actor = _lastBulkSelectedActor;
    if (actor == null) return false;
    for (final conflict in _activeConflicts) {
      if (!_lastBulkSelectedKeys.contains((
        conflict.recordKey,
        conflict.field,
      ))) {
        continue;
      }
      if (!_selectionIsCurrent(conflict)) continue;
      final candidate = _chosenCandidate(conflict);
      if (candidate != null &&
          candidate.actor == actor &&
          _isOrdinarySettingCandidate(conflict, candidate)) {
        return true;
      }
    }
    return false;
  }

  void _rememberCandidate(MergeConflict conflict, MergeCandidate candidate) {
    _selectedCandidates[(conflict.recordKey, conflict.field)] = (
      candidateId: candidate.id,
      candidateIds: Set.unmodifiable(
        conflict.candidates.map((item) => item.id),
      ),
      candidateFingerprint: conflict.candidateFingerprint,
    );
  }

  void _selectCandidate(MergeConflict conflict, MergeCandidate candidate) {
    if (_isSubmitting) return;
    setState(() => _rememberCandidate(conflict, candidate));
  }

  MergeCandidate? _newestCandidate(Iterable<MergeCandidate> candidates) {
    MergeCandidate? selected;
    for (final candidate in candidates) {
      if (selected == null ||
          candidate.counter > selected.counter ||
          (candidate.counter == selected.counter &&
              candidate.actor.compareTo(selected.actor) > 0)) {
        selected = candidate;
      }
    }
    return selected;
  }

  void _selectFromDevice(String actor) {
    if (_isSubmitting) return;
    final visible = _visibleConflicts(_activeConflicts);
    setState(() {
      _lastBulkSelectedKeys.clear();
      for (final conflict in visible) {
        final candidate = _newestCandidate(
          conflict.candidates.where(
            (item) => item.actor == actor && item.id != 'accumulated_total',
          ),
        );
        if (candidate == null) continue;
        _rememberCandidate(conflict, candidate);
        _lastBulkSelectedKeys.add((conflict.recordKey, conflict.field));
      }
      if (_lastBulkSelectedActor != actor) _rememberSettingDevice = false;
      _bulkActor = actor;
      _lastBulkSelectedActor = actor;
    });
  }

  MergeCandidate? _localCandidate(MergeConflict conflict, SyncRecords records) {
    final exists = records.containsKey(conflict.recordKey);
    final record = records[conflict.recordKey];
    return _newestCandidate(
      conflict.candidates.where((candidate) {
        if (conflict.field == 'presence') {
          return candidate.isDeleted == !exists;
        }
        final hasField = record?.containsKey(conflict.field) ?? false;
        if (candidate.isDeleted) return !hasField;
        return hasField &&
            syncValuesEqual(candidate.value, record![conflict.field]);
      }),
    );
  }

  void _selectLocalValues() {
    if (_isSubmitting) return;
    final records = _localCurrentRecords;
    setState(() {
      for (final conflict in _visibleConflicts(_activeConflicts)) {
        final candidate = _localCandidate(conflict, records);
        if (candidate != null) _rememberCandidate(conflict, candidate);
      }
    });
  }

  Future<void> _persistPreferredSettingActor(String actor) async {
    const key = _preferredSettingActorKey;
    final hadPrevious = appdata.implicitData.containsKey(key);
    final previous = appdata.implicitData[key];
    appdata.implicitData[key] = actor;
    try {
      await appdata.writeImplicitData();
    } catch (_) {
      if (hadPrevious) {
        appdata.implicitData[key] = previous;
      } else {
        appdata.implicitData.remove(key);
      }
      if (mounted) {
        context.showMessage(message: 'Could not save preferred device'.tl);
      }
    }
  }

  Future<void> _clearPreferredSettingActor() async {
    if (_isSubmitting || _isClearingPreference) return;
    const key = _preferredSettingActorKey;
    final hadPrevious = appdata.implicitData.containsKey(key);
    final previous = appdata.implicitData.remove(key);
    setState(() => _isClearingPreference = true);
    try {
      await appdata.writeImplicitData();
    } catch (_) {
      if (hadPrevious) appdata.implicitData[key] = previous;
      if (mounted) {
        context.showMessage(message: 'Could not clear preferred device'.tl);
      }
    } finally {
      if (mounted) setState(() => _isClearingPreference = false);
    }
  }

  Future<void> _submitSelections() async {
    if (_isSubmitting) return;
    final conflicts = _activeConflicts;
    _retainValidSelections(conflicts);
    final selected = _selectedConflicts(conflicts);
    if (selected.isEmpty) {
      setState(() {});
      return;
    }
    final resolutions = List<MergeConflictResolution>.unmodifiable([
      for (final conflict in selected)
        MergeConflictResolution(
          recordKey: conflict.recordKey,
          field: conflict.field,
          candidateId: _chosenCandidate(conflict)!.id,
          expectedCandidateIds:
              _selectedCandidates[(conflict.recordKey, conflict.field)]!
                  .candidateIds,
          expectedCandidateFingerprint:
              _selectedCandidates[(conflict.recordKey, conflict.field)]!
                  .candidateFingerprint,
        ),
    ]);
    String? actorToRemember;
    if (_rememberSettingDevice && _lastBulkSelectedActor != null) {
      for (final conflict in selected) {
        final candidate = _chosenCandidate(conflict);
        if (candidate != null &&
            candidate.actor == _lastBulkSelectedActor &&
            _isOrdinarySettingCandidate(conflict, candidate)) {
          actorToRemember = _lastBulkSelectedActor;
          break;
        }
      }
    }
    setState(() => _isSubmitting = true);
    try {
      final res = widget.onResolve != null
          ? await widget.onResolve!(resolutions)
          : await _sync.resolveConflicts(resolutions);
      if (!mounted) return;
      if (res.error) {
        context.showMessage(
          message: '${"Resolve failed".tl}: ${res.errorMessage ?? ""}',
        );
      } else if (res.dataOrNull != true) {
        context.showMessage(message: 'Resolve failed'.tl);
      } else {
        final resolved = {
          for (final resolution in resolutions)
            (resolution.recordKey, resolution.field),
        };
        setState(() {
          _selectedCandidates.removeWhere((key, _) => resolved.contains(key));
          _localConflicts?.removeWhere(
            (conflict) =>
                resolved.contains((conflict.recordKey, conflict.field)),
          );
        });
        if (actorToRemember != null) {
          await _persistPreferredSettingActor(actorToRemember);
        }
      }
    } catch (error) {
      if (mounted) {
        context.showMessage(message: '${"Resolve failed".tl}: $error');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

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

  String _identityLabel(MergeConflict conflict) {
    try {
      return _formatIdentity(
        syncRecordDomain(conflict.recordKey),
        syncRecordIdentity(conflict.recordKey),
      );
    } catch (_) {
      try {
        final decoded = jsonDecode(conflict.recordKey);
        if (decoded is List && decoded.isNotEmpty) {
          return _formatIdentity(decoded.first.toString(), decoded.sublist(1));
        }
      } catch (_) {}
      return '';
    }
  }

  bool _matchesSearch(MergeConflict conflict, String query) {
    final domain = _domainOf(conflict);
    final parts = <String>[
      _formatDomain(domain),
      _identityLabel(conflict),
      _formatFieldName(conflict.field),
      for (final candidate in conflict.candidates) ...[
        _deviceName(candidate.actor),
        _formatCandidateValue(
          domain: domain,
          field: conflict.field,
          value: candidate.value,
          isDeleted: candidate.isDeleted,
          recordKey: conflict.recordKey,
        ),
      ],
    ];
    return parts.join(' ').toLowerCase().contains(query);
  }

  Widget _buildConflictTools(List<String> groupDomains, List<String> actors) {
    final validGroup = groupDomains.contains(_groupFilter)
        ? _groupFilter
        : null;
    final validActor = actors.contains(_bulkActor) ? _bulkActor : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('sync-conflict-search'),
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search conflicts'.tl,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
          const SizedBox(height: 8),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Group'.tl,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                key: const ValueKey('sync-conflict-group-filter'),
                isExpanded: true,
                value: validGroup,
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All groups'.tl),
                  ),
                  for (final domain in groupDomains)
                    DropdownMenuItem<String?>(
                      key: ValueKey(('sync-conflict-group', domain)),
                      value: domain,
                      child: Text(_formatDomain(domain)),
                    ),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (domain) => setState(() => _groupFilter = domain),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                key: const ValueKey('sync-conflict-only-unselected'),
                selected: _onlyUnselected,
                label: Text('Only unselected'.tl),
                onSelected: _isSubmitting
                    ? null
                    : (value) => setState(() => _onlyUnselected = value),
              ),
            ],
          ),
          if (actors.isNotEmpty) ...[
            const SizedBox(height: 8),
            InputDecorator(
              decoration: InputDecoration(
                labelText: 'Batch select from device'.tl,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('sync-conflict-device-selector'),
                  isExpanded: true,
                  value: validActor,
                  hint: Text('Choose device'.tl),
                  items: [
                    for (final actor in actors)
                      DropdownMenuItem<String>(
                        key: ValueKey(('sync-conflict-device', actor)),
                        value: actor,
                        child: Text(
                          _deviceName(actor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _isSubmitting
                      ? null
                      : (actor) => setState(() {
                          _bulkActor = actor;
                          if (actor != _lastBulkSelectedActor) {
                            _lastBulkSelectedActor = null;
                            _lastBulkSelectedKeys.clear();
                            _rememberSettingDevice = false;
                          }
                        }),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('sync-conflict-select-local'),
                onPressed: _isSubmitting ? null : _selectLocalValues,
                icon: const Icon(Icons.phone_android),
                label: Text('Select local current values'.tl),
              ),
              if (validActor != null)
                OutlinedButton.icon(
                  key: const ValueKey('sync-conflict-select-device'),
                  onPressed: _isSubmitting
                      ? null
                      : () => _selectFromDevice(validActor),
                  icon: const Icon(Icons.devices),
                  label: Text('Select from device'.tl),
                ),
            ],
          ),
          if (_canRememberSelectedDevice)
            CheckboxListTile(
              key: const ValueKey('sync-conflict-remember-device'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _rememberSettingDevice,
              onChanged: _isSubmitting
                  ? null
                  : (value) =>
                        setState(() => _rememberSettingDevice = value == true),
              title: Text(
                'Remember this device for ordinary settings after successful resolution'
                    .tl,
              ),
            ),
          if (_savedPreferredSettingActor != null)
            _buildSavedPreferenceAction(),
        ],
      ),
    );
  }

  Widget _buildSavedPreferenceAction() {
    final actor = _savedPreferredSettingActor;
    if (actor == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('sync-conflict-clear-preference'),
        onPressed: _isSubmitting || _isClearingPreference
            ? null
            : _clearPreferredSettingActor,
        icon: const Icon(Icons.delete_outline),
        label: Text(
          'Clear remembered device preference (@device)'.tlParams({
            'device': _deviceName(actor),
          }),
        ),
      ),
    );
  }

  Widget _buildGroupHeader(String domain, int count, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        '@group · @count conflicts'.tlParams({
          'group': _formatDomain(domain),
          'count': count,
        }),
        style: theme.textTheme.titleSmall,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = _activeConflicts;
    final theme = Theme.of(context);
    final selected = _selectedConflicts(conflicts).length;
    final recordCount = conflicts
        .map((conflict) => conflict.recordKey)
        .toSet()
        .length;
    final fieldConflictCount = conflicts
        .where((conflict) => conflict.field != 'presence')
        .length;
    final visibleConflicts = _visibleConflicts(conflicts);
    final groups = <String, List<MergeConflict>>{};
    final groupDomains = conflicts.map(_domainOf).toSet().toList()
      ..sort((a, b) => _formatDomain(a).compareTo(_formatDomain(b)));
    for (final conflict in visibleConflicts) {
      final domain = _domainOf(conflict);
      groups.putIfAbsent(domain, () => []).add(conflict);
    }
    final actors =
        visibleConflicts
            .expand((conflict) => conflict.candidates)
            .where((candidate) => candidate.id != 'accumulated_total')
            .map((candidate) => candidate.actor)
            .toSet()
            .toList()
          ..sort((a, b) {
            final nameOrder = _deviceName(
              a,
            ).toLowerCase().compareTo(_deviceName(b).toLowerCase());
            return nameOrder != 0 ? nameOrder : a.compareTo(b);
          });
    final orderedGroups = groups.entries.toList()
      ..sort((a, b) => _formatDomain(a.key).compareTo(_formatDomain(b.key)));
    final visibleConflictCount = groups.values.fold<int>(
      0,
      (total, group) => total + group.length,
    );
    final canSubmit = selected > 0;

    return PopScope(
      canPop: !_isSubmitting,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
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
                                  onPressed: _isSubmitting
                                      ? null
                                      : () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              conflicts.isEmpty
                                  ? 'All conflicts resolved.'.tl
                                  : '@records records · @fields field conflicts · @selected selected'
                                        .tlParams({
                                          'records': recordCount,
                                          'fields': fieldConflictCount,
                                          'selected': selected,
                                        }),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.textTheme.bodySmall?.color,
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      if (conflicts.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildConflictTools(groupDomains, actors),
                        )
                      else if (_savedPreferredSettingActor != null)
                        SliverToBoxAdapter(
                          child: _buildSavedPreferenceAction(),
                        ),
                      if (conflicts.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
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
                        )
                      else if (visibleConflictCount == 0)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text('No conflicts match these filters'.tl),
                          ),
                        )
                      else
                        for (final group in orderedGroups) ...[
                          SliverToBoxAdapter(
                            child: _buildGroupHeader(
                              group.key,
                              group.value.length,
                              theme,
                            ),
                          ),
                          SliverList.separated(
                            itemCount: group.value.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) =>
                                _buildConflictCard(group.value[index], theme),
                          ),
                        ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (conflicts.isEmpty)
                  FilledButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text('Done'.tl),
                  )
                else
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        key: const ValueKey('sync-conflict-close'),
                        onPressed: _isSubmitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text('Close'.tl),
                      ),
                      FilledButton(
                        key: const ValueKey('sync-conflict-resolve-selected'),
                        onPressed: _isSubmitting || !canSubmit
                            ? null
                            : _submitSelections,
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text('Resolve Selected'.tl),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConflictCard(MergeConflict conflict, ThemeData theme) {
    final domain = _domainOf(conflict);
    final domainLabel = _formatDomain(domain);
    final identityLabel = _identityLabel(conflict);
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
              final isSelected =
                  _selectionIsCurrent(conflict) &&
                  _selectedCandidates[(conflict.recordKey, conflict.field)]
                          ?.candidateId ==
                      cand.id;

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
                    color: isSelected
                        ? theme.colorScheme.primary
                        : cand.isDeleted
                        ? theme.colorScheme.error.withValues(alpha: 0.3)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : cand.isDeleted
                              ? Icons.delete_outline
                              : Icons.check_circle_outline,
                          size: 20,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : cand.isDeleted
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
                                        '${"Device".tl}: ${_deviceName(cand.actor)}',
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
                        onPressed: () => _selectCandidate(conflict, cand),
                        child: Text(isSelected ? 'Selected'.tl : 'Choose'.tl),
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
