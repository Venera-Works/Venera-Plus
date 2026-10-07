import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/sync/app_data_transfer.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/network/cookie_jar.dart';

/// Exception thrown when a path containment or traversal violation occurs.
class SyncPathSecurityException implements Exception {
  final String message;
  const SyncPathSecurityException(this.message);
  @override
  String toString() => 'SyncPathSecurityException: $message';
}

/// Sync adapter for preferences, search history, cookies, and comic sources.
///
/// Implements lossless record-level export, apply, and legacy migration for
/// domains: `setting`, `search`, `cookies`, `source`, and `sourceSession`.
class SyncPreferencesAdapter {
  SyncPreferencesAdapter({
    Appdata? appdataInstance,
    CookieJarSql? cookieJarInstance,
    String? dataPath,
  }) : _appdata = appdataInstance ?? appdata,
       _cookieJar = cookieJarInstance,
       _customDataPath = dataPath;

  final Appdata _appdata;
  final CookieJarSql? _cookieJar;
  final String? _customDataPath;

  bool _reloadSourcesPending = false;
  final Set<String> _reloadSessionsPending = {};

  /// Settings outside this device's policy are invisible, not deletions.
  bool shouldObserveRecord(String recordKey) {
    if (syncRecordDomain(recordKey) != 'setting') return true;
    final identity = syncRecordIdentity(recordKey);
    return identity.isNotEmpty &&
        identity.first is String &&
        _appdata.isSettingSyncAllowed(identity.first as String);
  }

  SyncRecords projectRecordsForLocalPolicy(SyncRecords records) {
    final ancestors = <String>{};
    for (final key in records.keys) {
      if (syncRecordDomain(key) != 'setting') continue;
      final path = syncRecordIdentity(key);
      for (int length = 1; length < path.length; length++) {
        ancestors.add(syncRecordKey('setting', path.sublist(0, length)));
      }
    }
    return {
      for (final entry in records.entries)
        if (shouldObserveRecord(entry.key) &&
            !(ancestors.contains(entry.key) &&
                entry.value['value'] is Map &&
                (entry.value['value'] as Map).isEmpty))
          entry.key: entry.value,
    };
  }

  String get _dataPath => _customDataPath ?? App.dataPath;

  /// Global callback for runtime notification after settings are imported.
  static FutureOr<void> Function()? onSettingsImported;

  /// Registers a runtime hook called when settings have been applied.
  static void registerSettingsImportedCallback(
    FutureOr<void> Function()? callback,
  ) {
    onSettingsImported = callback;
  }

  /// Triggers runtime reload notification.
  static Future<void> notifySettingsImported() async {
    final custom = onSettingsImported;
    if (custom != null) {
      await Future.sync(custom);
    } else {
      await notifyAppDataSettingsChanged();
    }
  }

  CookieJarSql _resolveCookieJar() {
    if (_cookieJar != null) return _cookieJar;
    final dbPath = p.join(_dataPath, 'cookie.db');
    final shared = SingleInstanceCookieJar.instance;
    if (shared != null && p.equals(shared.path, dbPath)) return shared;
    return CookieJarSql(dbPath);
  }

  void _closeOwnedCookieJar(CookieJarSql jar) {
    if (!identical(jar, _cookieJar) &&
        !identical(jar, SingleInstanceCookieJar.instance)) {
      jar.dispose();
    }
  }

  // ===========================================================================
  // Validation Helpers
  // ===========================================================================

  static void _validateRecordKey(String key) {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(key)) {
      throw FormatException('Invalid comic source identity: $key');
    }
  }

  static void _validateFileName(String filename) {
    if (!filename.endsWith('.js')) {
      throw const FormatException('Source scripts must use a .js filename');
    }
    if (filename.isEmpty ||
        p.basename(filename) != filename ||
        filename.contains('..') ||
        filename.contains('/') ||
        filename.contains(r'\') ||
        filename.contains('\u0000')) {
      throw FormatException(
        'Invalid filename with path traversal characters: $filename',
      );
    }
  }

  static void _assertPathContained(Directory parent, File target) {
    final parentCanon = p.canonicalize(parent.path);
    final targetCanon = p.canonicalize(target.path);
    if (!p.isWithin(parentCanon, targetCanon)) {
      throw SyncPathSecurityException(
        'Target path $targetCanon is outside allowed directory $parentCanon',
      );
    }
  }

  static String _physicalSourceName(String key) =>
      'sync_${sha256.convert(utf8.encode(key))}.js';

  Future<Map<String, Map<String, Object?>>> _readSourceNames(
    Directory sourceDir,
  ) async {
    final file = File(p.join(sourceDir.path, '.sync_source_names.json'));
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Source filename metadata must be an object');
    }
    final names = <String, Map<String, Object?>>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (entry.key is! String ||
          value is! Map ||
          value['filename'] is! String ||
          value['revisions'] is! Map) {
        throw const FormatException('Invalid source filename metadata');
      }
      _validateRecordKey(entry.key as String);
      _validateFileName(value['filename'] as String);
      final revisions = <String, String>{};
      for (final revision in (value['revisions'] as Map).entries) {
        if (revision.key is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision.key as String) ||
            revision.value is! String) {
          throw const FormatException('Invalid source filename revision');
        }
        _validateFileName(revision.value as String);
        revisions[revision.key as String] = revision.value as String;
      }
      names[entry.key as String] = {
        'filename': value['filename'],
        'revisions': revisions,
      };
    }
    return names;
  }

  static String _logicalSourceName(
    String key,
    String physicalName,
    String content,
    Map<String, Map<String, Object?>> names,
  ) {
    if (physicalName != _physicalSourceName(key)) return physicalName;
    final metadata = names[key];
    if (metadata == null) {
      throw FormatException('Missing logical filename for source "$key"');
    }
    final revision = sha256.convert(utf8.encode(content)).toString();
    return (metadata['revisions'] as Map)[revision] as String? ??
        metadata['filename'] as String;
  }

  // ===========================================================================
  // Export
  // ===========================================================================

  /// Exports current local preferences and file-backed assets into [SyncRecords].
  ///
  /// Any read error fails the entire capture to avoid emitting false deletions.
  Future<SyncRecords> exportSyncRecords() async {
    final records = <String, Map<String, Object?>>{};

    // 1. Settings domain (flattened to per-leaf records)
    final settingsMap = _appdata.exportSyncSettings();
    for (final entry in settingsMap.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is Map) {
        _flattenMapLeaves([key], value, records);
      } else {
        records[syncRecordKey('setting', [key])] = {
          'value': canonicalizeSyncValue(value),
        };
      }
    }

    // 2. Search domain (each keyword is an independent record with order)
    records.addAll(_appdata.exportSearchHistoryRecords());

    // 3. Cookies domain (per normalized domain, atomic sorted list)
    // Any error here MUST propagate so capture fails rather than creating tombstones.
    final jar = _resolveCookieJar();
    try {
      final grouped = jar.exportAllCookiesGroupedByDomain();
      for (final entry in grouped.entries) {
        records[syncRecordKey('cookies', [entry.key])] = {
          'cookies': entry.value,
        };
      }
    } finally {
      _closeOwnedCookieJar(jar);
    }

    // 4. Source & SourceSession domains (from comic_source directory)
    for (final source in ComicSource.all()) {
      await source.waitForDataWrites();
    }
    final comicSourceDir = Directory(p.join(_dataPath, 'comic_source'));
    final sourceNames = await _readSourceNames(comicSourceDir);
    if (await comicSourceDir.exists()) {
      await for (final entity in comicSourceDir.list()) {
        if (entity is! File) continue;
        final filename = p.basename(entity.path);
        if (filename.startsWith('.')) continue;

        if (filename.endsWith('.js')) {
          final content = await entity.readAsString();
          final key = await ComicSourceParser.probeKey(content, entity.path);
          if (key == null || key.isEmpty) {
            throw FormatException(
              'Failed to resolve stable comic source key for script $filename; '
              'capture aborted to prevent false deletion.',
            );
          }
          _validateRecordKey(key);
          final recordKey = syncRecordKey('source', [key]);
          if (records.containsKey(recordKey)) {
            throw FormatException(
              'Multiple scripts use source identity "$key"',
            );
          }
          records[syncRecordKey('source', [key])] = {
            'script': {
              'filename': _logicalSourceName(
                key,
                filename,
                content,
                sourceNames,
              ),
              'content': content,
            },
          };
        } else if (filename.endsWith('.data')) {
          final key = filename.substring(0, filename.length - 5);
          _validateRecordKey(key);
          final raw = await entity.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw FormatException(
              'Failed to parse comic source session for $filename: must be JSON object.',
            );
          }
          records[syncRecordKey('sourceSession', [key])] = {
            'data': Map<String, Object?>.from(decoded),
          };
        }
      }
    }

    return records;
  }

  void _flattenMapLeaves(List<String> path, Map map, SyncRecords output) {
    if (map.isEmpty) {
      output[syncRecordKey('setting', path)] = {'value': <String, Object?>{}};
      return;
    }
    for (final entry in map.entries) {
      final nextKey = entry.key.toString();
      final subPath = [...path, nextKey];
      final val = entry.value;
      if (val is Map) {
        _flattenMapLeaves(subPath, val, output);
      } else {
        output[syncRecordKey('setting', subPath)] = {
          'value': canonicalizeSyncValue(val),
        };
      }
    }
  }

  // ===========================================================================
  // Apply
  // ===========================================================================

  /// Applies materialized records for owned domains.
  ///
  /// Flow:
  /// 1. Asynchronously stage all file writes in a temporary directory.
  /// 2. Invoke [beforeCommit].
  /// 3. Enter a short synchronous section to replace files/SQL/settings.
  /// 4. Await durable Appdata persistence. The caller completes its journal
  ///    before invoking [finishApply] for runtime reload notifications.
  Future<void> applySyncRecords(
    SyncRecords records, {
    void Function()? beforeCommit,
  }) async {
    final stageDir = Directory(
      p.join(
        _dataPath,
        'comic_source',
        '.sync_stage_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await stageDir.create(recursive: true);

    final updatedSessionKeys = <String>{};

    try {
      // -----------------------------------------------------------------------
      // Phase 1: Asynchronous Staging
      // -----------------------------------------------------------------------

      // Parse incoming records by domain
      final incomingSettings = <List<String>, Object?>{};
      final incomingSearch = <String, num>{};
      final incomingCookies = <String, List<Map<String, Object?>>>{};
      final incomingSources = <String, ({String filename, String content})>{};
      final incomingSessions = <String, Map<String, Object?>>{};

      for (final entry in records.entries) {
        final domain = syncRecordDomain(entry.key);
        final identity = syncRecordIdentity(entry.key);
        if (const {
              'search',
              'cookies',
              'source',
              'sourceSession',
            }.contains(domain) &&
            (identity.length != 1 || identity.single is! String)) {
          throw FormatException('Invalid identity for $domain record');
        }

        switch (domain) {
          case 'setting':
            if (identity.isEmpty || identity.any((part) => part is! String)) {
              throw const FormatException(
                'Setting identity must be a string path',
              );
            }
            final rootKey = identity.first as String;
            if (_appdata.isSettingSyncAllowed(rootKey)) {
              if (!entry.value.containsKey('value')) {
                throw FormatException(
                  'Setting "$rootKey" is missing its value',
                );
              }
              incomingSettings[identity.cast<String>()] = entry.value['value'];
            }
            break;

          case 'search':
            if (identity.isNotEmpty) {
              final keyword = identity.first.toString();
              final rawOrder = entry.value['order'];
              if (rawOrder != null && rawOrder is! num) {
                throw FormatException(
                  'Invalid search order for $keyword: must be a number',
                );
              }
              final order = rawOrder is num ? rawOrder : incomingSearch.length;
              incomingSearch[keyword] = order;
            }
            break;

          case 'cookies':
            if (identity.isNotEmpty) {
              final normalizedDomain = identity.single as String;
              final rawCookies = entry.value['cookies'];
              if (rawCookies is! List) {
                throw FormatException(
                  'Invalid cookies record for domain "$normalizedDomain": cookies must be a List',
                );
              }
              final rows = <Map<String, Object?>>[];
              for (final item in rawCookies) {
                if (item is! Map) {
                  throw FormatException(
                    'Invalid cookie row for domain "$normalizedDomain": item must be a Map',
                  );
                }
                rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
              }
              incomingCookies[normalizedDomain] =
                  CookieJarSql.validateDomainCookies(normalizedDomain, rows);
            }
            break;

          case 'source':
            if (identity.isNotEmpty) {
              final key = identity.first.toString();
              _validateRecordKey(key);
              final rawScript = entry.value['script'];
              if (rawScript is! Map) {
                throw FormatException(
                  'Invalid source script record for "$key": script must be an object {filename, content}',
                );
              }
              final filename = rawScript['filename'];
              final content = rawScript['content'];
              if (filename is! String || content is! String) {
                throw FormatException(
                  'Source script record for "$key" must contain both filename and content',
                );
              }
              _validateFileName(filename);
              final probedKey = await ComicSourceParser.probeKey(
                content,
                filename,
              );
              if (probedKey != key) {
                throw FormatException(
                  'Source script identity does not match "$key"',
                );
              }
              incomingSources[key] = (filename: filename, content: content);
            }
            break;

          case 'sourceSession':
            if (identity.isNotEmpty) {
              final key = identity.first.toString();
              _validateRecordKey(key);
              final rawData = entry.value['data'];
              if (rawData is! Map) {
                throw FormatException(
                  'Invalid source session record for "$key": data must be a Map',
                );
              }
              incomingSessions[key] = Map<String, Object?>.from(rawData);
            }
            break;
        }
      }

      // Reconstruct root settings from leaf records
      final reconstructedSettings = _reconstructSettingsFromLeaves(
        incomingSettings,
      );
      for (final entry in reconstructedSettings.entries) {
        _appdata.validateSyncSetting(entry.key, entry.value);
      }
      for (final source in ComicSource.all()) {
        await source.waitForDataWrites();
      }

      // Reconstruct sorted search history
      final sortedKeywords = incomingSearch.entries.toList()
        ..sort((a, b) {
          final order = a.value.compareTo(b.value);
          return order == 0 ? a.key.compareTo(b.key) : order;
        });
      final newSearchHistory = sortedKeywords.map((e) => e.key).toList();

      // Read current local sources to detect changes and deletions
      final targetSourceDir = Directory(p.join(_dataPath, 'comic_source'));
      await targetSourceDir.create(recursive: true);

      final currentSourceFiles = <String, File>{}; // key -> File
      final currentSessionFiles = <String, File>{}; // key -> File
      final sourceNames = await _readSourceNames(targetSourceDir);
      final currentSourceContents = <String, String>{};

      await for (final entity in targetSourceDir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.sync_stage')) continue;

        if (name.endsWith('.js')) {
          final content = await entity.readAsString();
          final key = await ComicSourceParser.probeKey(content, entity.path);
          if (key != null && key.isNotEmpty) {
            _validateRecordKey(key);
            if (currentSourceFiles.containsKey(key)) {
              throw FormatException(
                'Multiple local scripts use source identity "$key"',
              );
            }
            currentSourceFiles[key] = entity;
            currentSourceContents[key] = content;
          } else {
            throw FormatException(
              'Cannot resolve source key for local file $name during sync apply; aborted to prevent data loss',
            );
          }
        } else if (name.endsWith('.data')) {
          final key = name.substring(0, name.length - 5);
          _validateRecordKey(key);
          currentSessionFiles[key] = entity;
        }
      }

      // Stage new or updated source scripts
      final stagedSourceMoves = <File, File>{}; // stagedFile -> targetFile
      for (final entry in incomingSources.entries) {
        // Stable physical script names never use session (.data) targets.
        final key = entry.key;
        final data = entry.value;
        _validateRecordKey(key);
        _validateFileName(data.filename);

        final targetFile = File(
          p.join(targetSourceDir.path, _physicalSourceName(key)),
        );
        _assertPathContained(targetSourceDir, targetFile);

        var needsWrite = true;
        if (await targetFile.exists()) {
          final existingContent = await targetFile.readAsString();
          if (existingContent == data.content) {
            needsWrite = false;
          }
        }

        if (needsWrite) {
          final staged = File(p.join(stageDir.path, _physicalSourceName(key)));
          await staged.writeAsString(data.content, flush: true);
          stagedSourceMoves[staged] = targetFile;
        }
      }
      final sourceNamesTarget = File(
        p.join(targetSourceDir.path, '.sync_source_names.json'),
      );
      final sourceNamesStaged = File(
        p.join(stageDir.path, '.sync_source_names.json'),
      );
      final nextSourceNames = <String, Map<String, Object?>>{
        for (final key in currentSourceFiles.keys)
          if (sourceNames.containsKey(key)) key: sourceNames[key]!,
      };
      for (final entry in incomingSources.entries) {
        final key = entry.key;
        final revisions = <String, String>{};
        final previousContent = currentSourceContents[key];
        if (previousContent != null) {
          revisions[sha256
              .convert(utf8.encode(previousContent))
              .toString()] = _logicalSourceName(
            key,
            p.basename(currentSourceFiles[key]!.path),
            previousContent,
            sourceNames,
          );
        }
        revisions[sha256.convert(utf8.encode(entry.value.content)).toString()] =
            entry.value.filename;
        nextSourceNames[key] = {
          'filename': entry.value.filename,
          'revisions': revisions,
        };
      }
      await sourceNamesStaged.writeAsString(
        jsonEncode(nextSourceNames),
        flush: true,
      );

      // Stage new or updated source sessions
      final stagedSessionMoves = <File, File>{}; // stagedFile -> targetFile
      for (final entry in incomingSessions.entries) {
        final key = entry.key;
        final sessionData = entry.value;
        _validateRecordKey(key);

        final targetFile = File(p.join(targetSourceDir.path, '$key.data'));
        _assertPathContained(targetSourceDir, targetFile);
        final encoded = jsonEncode(sessionData);

        var needsWrite = true;
        if (await targetFile.exists()) {
          final existing = await targetFile.readAsString();
          if (syncValuesEqual(jsonDecode(existing), sessionData)) {
            needsWrite = false;
          }
        }

        if (needsWrite) {
          final staged = File(p.join(stageDir.path, '$key.data'));
          await staged.writeAsString(encoded, flush: true);
          stagedSessionMoves[staged] = targetFile;
          updatedSessionKeys.add(key);
        }
      }

      // Identify source files to delete (omitted from incoming records)
      final filesToDelete = <File>[];
      final incomingPhysicalNames = incomingSources.keys
          .map(_physicalSourceName)
          .toSet();
      for (final entry in currentSourceFiles.entries) {
        if ((!incomingSources.containsKey(entry.key) ||
                p.basename(entry.value.path) !=
                    _physicalSourceName(entry.key)) &&
            !incomingPhysicalNames.contains(p.basename(entry.value.path))) {
          _assertPathContained(targetSourceDir, entry.value);
          filesToDelete.add(entry.value);
        }
      }
      for (final entry in currentSessionFiles.entries) {
        if (!incomingSessions.containsKey(entry.key)) {
          _assertPathContained(targetSourceDir, entry.value);
          filesToDelete.add(entry.value);
          updatedSessionKeys.add(entry.key);
        }
      }

      // -----------------------------------------------------------------------
      // Phase 2: Before Commit Callback
      // -----------------------------------------------------------------------
      beforeCommit?.call();

      // -----------------------------------------------------------------------
      // Phase 3: Short Commit Section (Strictly Synchronous, NO Awaits)
      // -----------------------------------------------------------------------
      _executeSynchronousCommit(
        stagedSourceMoves: stagedSourceMoves,
        stagedSessionMoves: stagedSessionMoves,
        filesToDelete: filesToDelete,
        incomingCookies: incomingCookies,
        reconstructedSettings: reconstructedSettings,
        searchHistory: newSearchHistory,
        searchOrders: incomingSearch,
        sourceNamesStaged: sourceNamesStaged,
        sourceNamesTarget: sourceNamesTarget,
      );
      await _appdata.saveData(false);
      _reloadSourcesPending = true;
      _reloadSessionsPending.addAll(updatedSessionKeys);
    } finally {
      if (await stageDir.exists()) {
        await stageDir.delete(recursive: true);
      }
    }
  }

  /// Runs only after the caller has completed its durable apply journal.
  /// Session reloads use revision checks; source replacements share live data.
  Future<void> finishApply() async {
    await _reloadRuntimeSafely(
      scriptsChanged: _reloadSourcesPending,
      updatedSessionKeys: _reloadSessionsPending,
    );
    _reloadSourcesPending = false;
    _reloadSessionsPending.clear();
  }

  /// Reconstructs root settings map from per-leaf records.
  Map<String, dynamic> _reconstructSettingsFromLeaves(
    Map<List<String>, Object?> leaves,
  ) {
    final result = <String, dynamic>{};
    final ordered = leaves.entries.toList()
      ..sort((a, b) => a.key.length.compareTo(b.key.length));
    for (final entry in ordered) {
      final path = entry.key;
      Map<String, dynamic> cursor = result;
      for (int i = 0; i < path.length - 1; i++) {
        final child = cursor.putIfAbsent(path[i], () => <String, dynamic>{});
        if (child is! Map<String, dynamic>) {
          throw const FormatException(
            'A primitive setting cannot contain child leaves',
          );
        }
        cursor = child;
      }
      cursor[path.last] = canonicalizeSyncValue(entry.value);
    }
    return result;
  }

  /// Synchronous commit section: atomic file swaps, SQLite transaction, in-memory settings.
  ///
  /// Any exception propagates without swallowing so the parent apply journal can recover.
  void _executeSynchronousCommit({
    required Map<File, File> stagedSourceMoves,
    required Map<File, File> stagedSessionMoves,
    required List<File> filesToDelete,
    required Map<String, List<Map<String, Object?>>> incomingCookies,
    required Map<String, dynamic> reconstructedSettings,
    required List<String> searchHistory,
    required Map<String, num> searchOrders,
    required File sourceNamesStaged,
    required File sourceNamesTarget,
  }) {
    // Publish both old/new logical names before scripts move. A partial apply
    // still exports the name belonging to the exact script content on disk.
    sourceNamesStaged.renameSync(sourceNamesTarget.path);
    // 1. Synchronously swap staged script and session files
    for (final move in stagedSourceMoves.entries) {
      final staged = move.key;
      final target = move.value;
      staged.renameSync(target.path);
    }

    for (final move in stagedSessionMoves.entries) {
      final staged = move.key;
      final target = move.value;
      staged.renameSync(target.path);
    }

    for (final file in filesToDelete) {
      if (file.existsSync()) {
        file.deleteSync();
      }
    }

    // One transaction replaces the whole cookie view, including omitted domains.
    final jar = _resolveCookieJar();
    try {
      jar.applyAllDomainCookies(incomingCookies);
    } finally {
      _closeOwnedCookieJar(jar);
    }

    // 3. Synchronously apply settings via Appdata's public APIs (no _data access)
    // Remove allowed settings that were omitted from incoming materialized view
    final currentAllowedKeys = _appdata.syncAllowedSettingKeys;
    for (final key in currentAllowedKeys) {
      if (!reconstructedSettings.containsKey(key)) {
        _appdata.removeSyncSetting(key);
      }
    }

    // Apply reconstructed settings via safe public API
    for (final entry in reconstructedSettings.entries) {
      _appdata.applySyncSetting(entry.key, entry.value);
    }

    // Apply search history
    _appdata.setFullSearchHistory(searchHistory, orders: searchOrders);
  }

  /// Safe runtime reload that will not clobber user edits made while waiting.
  Future<void> _reloadRuntimeSafely({
    required bool scriptsChanged,
    required Set<String> updatedSessionKeys,
  }) async {
    for (final key in updatedSessionKeys) {
      final active = ComicSourceManager().find(key);
      if (active != null) await active.loadData();
    }
    if (scriptsChanged) {
      await ComicSourceManager().reload();
    }
    await notifySettingsImported();
  }

  // ===========================================================================
  // Legacy Migration Reader
  // ===========================================================================

  /// Reads records from an extracted legacy directory without mutating live state.
  ///
  /// Reuses shared safety filtering, key probing, and domain normalization.
  Future<SyncRecords> readLegacyRecords(Directory extracted) async {
    final records = <String, Map<String, Object?>>{};

    // 1. Read appdata.json or syncdata.json
    final appdataFile = File(p.join(extracted.path, 'appdata.json'));
    final syncdataFile = File(p.join(extracted.path, 'syncdata.json'));
    final targetFile = appdataFile.existsSync()
        ? appdataFile
        : (syncdataFile.existsSync() ? syncdataFile : null);

    if (targetFile != null) {
      final content = await targetFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const FormatException('Legacy appdata root must be an object');
      }
      final rawSettings = decoded['settings'];
      if (decoded.containsKey('settings') && rawSettings is! Map) {
        throw const FormatException('Legacy settings must be an object');
      }
      if (rawSettings is Map) {
        final disabled = _appdata.getDisabledSyncFields(forExport: true);
        for (final entry in rawSettings.entries) {
          if (entry.key is! String) {
            throw const FormatException('Legacy setting keys must be strings');
          }
          final key = entry.key as String;
          if (disabled.contains(key)) continue;
          final val = key == 'initialPage'
              ? normalizeStartupPage(entry.value)
              : entry.value;
          _appdata.validateSyncSetting(key, val);
          if (val is Map) {
            _flattenMapLeaves([key], val, records);
          } else {
            records[syncRecordKey('setting', [key])] = {
              'value': canonicalizeSyncValue(val),
            };
          }
        }
      }
      final keywords = <String>[];
      for (final field in ['searchHistory', 'overflowSearchHistory']) {
        final rawKeywords = decoded[field];
        if (decoded.containsKey(field) &&
            (rawKeywords is! List ||
                rawKeywords.any((item) => item is! String))) {
          throw FormatException('Legacy $field must be a list of strings');
        }
        if (rawKeywords is List) {
          keywords.addAll(rawKeywords.cast<String>());
        }
      }
      final orders = Appdata.decodeSearchHistoryOrder(decoded, keywords).orders;
      for (final keyword in keywords) {
        records[syncRecordKey('search', [keyword])] = {
          'order': orders[keyword],
        };
      }
    }

    // 2. Read isolated cookie.db
    final cookieDbFile = File(p.join(extracted.path, 'cookie.db'));
    if (cookieDbFile.existsSync()) {
      Database? isolatedDb;
      try {
        isolatedDb = sqlite3.open(cookieDbFile.path);
        final rows = isolatedDb.select('''
          SELECT name, value, domain, path, expires, secure, httpOnly
          FROM cookies;
        ''');
        final grouped = <String, List<Map<String, Object?>>>{};
        for (final row in rows) {
          final domain = row['domain'] as String;
          final normalized = normalizeCookieDomain(domain);
          final item = <String, Object?>{
            'name': row['name'] as String,
            'value': row['value'] as String,
            'domain': domain,
            'path': row['path'] as String? ?? '/',
            'expires': row['expires'] as int?,
            'secure': (row['secure'] == 1),
            'httpOnly': (row['httpOnly'] == 1),
          };
          grouped.putIfAbsent(normalized, () => []).add(item);
        }

        for (final entry in grouped.entries) {
          entry.value.sort((a, b) {
            final c1 = (a['name'] as String).compareTo(b['name'] as String);
            if (c1 != 0) return c1;
            final c2 = ((a['path'] as String?) ?? '').compareTo(
              (b['path'] as String?) ?? '',
            );
            if (c2 != 0) return c2;
            return ((a['domain'] as String?) ?? '').compareTo(
              (b['domain'] as String?) ?? '',
            );
          });
          records[syncRecordKey('cookies', [entry.key])] = {
            'cookies': entry.value,
          };
        }
      } finally {
        isolatedDb?.dispose();
      }
    }

    // 3. Read isolated comic_source directory
    final sourceDir = Directory(p.join(extracted.path, 'comic_source'));
    if (sourceDir.existsSync()) {
      final sourceNames = await _readSourceNames(sourceDir);
      for (final entity in sourceDir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;

        if (name.endsWith('.js')) {
          final content = entity.readAsStringSync();
          final key = await ComicSourceParser.probeKey(content, entity.path);
          if (key != null && key.isNotEmpty) {
            _validateRecordKey(key);
            _validateFileName(name);
            final recordKey = syncRecordKey('source', [key]);
            if (records.containsKey(recordKey)) {
              throw FormatException('Duplicate legacy source identity "$key"');
            }
            records[syncRecordKey('source', [key])] = {
              'script': {
                'filename': _logicalSourceName(key, name, content, sourceNames),
                'content': content,
              },
            };
          } else {
            throw FormatException(
              'Cannot resolve comic source key for legacy script $name',
            );
          }
        } else if (name.endsWith('.data')) {
          final key = name.substring(0, name.length - 5);
          _validateRecordKey(key);
          final raw = entity.readAsStringSync();
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw FormatException(
              'Invalid legacy comic source session for $name: must be JSON object',
            );
          }
          records[syncRecordKey('sourceSession', [key])] = {
            'data': Map<String, Object?>.from(decoded),
          };
        }
      }
    }

    return records;
  }
}
