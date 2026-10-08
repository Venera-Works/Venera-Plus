import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

import 'legacy_sync_reader.dart';
import 'merge_remote.dart';
import 'merge_store.dart';
import 'merge_sync_coordinator.dart';
import 'sync_preferences_adapter.dart';

enum _DataSyncTask { sync, upload, download, configure, resolve, repair }

class _SyncRequest {
  _SyncRequest(this.type, this.run, this.key);
  final _DataSyncTask type;
  final Future<Res<bool>> Function() run;
  final Object? key;
  final completer = Completer<Res<bool>>();
}

enum SyncDirection { bidirectional, uploadOnly, downloadOnly }

enum SyncTiming { manual, realtime, scheduled }

class DataSyncStatusSnapshot {
  const DataSyncStatusSnapshot({
    this.isConfigured = false,
    required this.isEnabled,
    required this.direction,
    required this.timing,
    required this.isUploading,
    required this.isDownloading,
    required this.isSyncing,
    required this.lastSyncTime,
    required this.lastError,
    this.hasConflict = false,
    this.conflictCount = 0,
    this.sourceIssues = const [],
    this.unavailableDomains = const {},
    this.isPartial = false,
  });

  final bool isEnabled;
  final bool isConfigured;
  final SyncDirection direction;
  final SyncTiming timing;
  final bool isUploading;
  final bool isDownloading;
  final bool isSyncing;
  final int lastSyncTime;
  final String? lastError;
  final bool hasConflict;
  final int conflictCount;
  final List<SyncSourceIssue> sourceIssues;
  final Set<String> unavailableDomains;
  final bool isPartial;
  bool get shouldShow => isConfigured || isEnabled || isSyncing;

  String get title => isSyncing ? 'Syncing Data' : 'Sync Data';

  String get formattedLastSyncTime => _formatTime(lastSyncTime);

  static String _formatTime(int timestamp) {
    if (timestamp <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class DataSync with ChangeNotifier {
  DataSync._() {
    appdata.registerSyncDataRequestHandler(onDataChanged);
    appdata.settings.addListener(onDataChanged);
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    HistoryManager().addListener(onDataChanged);
    ImageFavoriteManager().addListener(onDataChanged);
    CookieJarSql.registerCookiesChangedHandler(onDataChanged);

    unawaited(_initializeStartup());

    if (App.isDesktop && !debugDisableWindowCloseHandler) {
      Future.delayed(const Duration(seconds: 1), () {
        final context = App.rootNavigatorKey.currentContext;
        if (_disposed || context == null || !context.mounted) return;
        context
            .getInheritedWidgetOfExactType<WindowFrameController>()
            ?.addCloseListener(_handleWindowClose);
      });
    }
  }

  static const _importZoneKey = #_dataSyncImporting;

  MergeSyncCoordinator? _coordinator;
  @visibleForTesting
  MergeSyncCoordinator? get coordinator => _coordinator;

  final Completer<void> _startupCompleter = Completer<void>();
  bool _startupReady = false;
  Object? _startupError;
  bool _coordinatorNeedsRecovery = true;
  bool get isReady => _startupReady && !_coordinatorNeedsRecovery;

  Future<void> _initializeStartup() async {
    try {
      if (hasConfiguration) {
        await runZoned(
          _ensureCoordinatorLoaded,
          zoneValues: {_importZoneKey: true},
        );
        if (_coordinator != null) _startupReady = true;
      } else {
        _coordinatorNeedsRecovery = false;
        _startupReady = true;
      }
      checkForAutomaticSync(startup: true);
    } catch (e, s) {
      Log.error('DataSync', 'Startup initialization failed: $e\n$s');
      _startupError = e;
      _lastError = e.toString();
      if (!_disposed) notifyListeners();
    } finally {
      if (!_startupCompleter.isCompleted) {
        _startupCompleter.complete();
      }
    }
  }

  /// Waits for startup recovery; never reports a pending endpoint as ready.
  Future<void> waitForStartupMerge() async {
    await _startupCompleter.future;
    if (!isReady) {
      throw StateError('Sync startup recovery failed: $_startupError');
    }
  }

  void onDataChanged() {
    if (_disposed || Zone.current[_importZoneKey] == true) return;
    _changeGeneration++;
    if (!hasConfiguration) return;
    if (!hasPendingChanges) {
      appdata.implicitData['webdavSyncPending'] = true;
      unawaited(
        appdata.writeImplicitData().catchError((
          Object error,
          StackTrace stack,
        ) {
          Log.error('Data Sync', error, stack);
          _lastError = error.toString();
          if (!_disposed) notifyListeners();
        }),
      );
    }
    if (direction != SyncDirection.downloadOnly &&
        isEnabled &&
        timing == SyncTiming.realtime &&
        !_configuring &&
        isReady) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (!_disposed && isEnabled && timing == SyncTiming.realtime) {
          unawaited(syncNow());
        }
      });
    }
  }

  bool _interactionActive = false;
  bool beginInteraction() {
    if (_interactionActive || isSyncing) return false;
    _interactionActive = true;
    return true;
  }

  void endInteraction() => _interactionActive = false;

  static SyncDirection get direction {
    final stored = appdata.implicitData['webdavSyncDirection'];
    return SyncDirection.values.firstWhereOrNull(
          (value) => value.name == stored,
        ) ??
        SyncDirection.bidirectional;
  }

  static SyncTiming get timing {
    final stored = appdata.implicitData['webdavSyncTiming'];
    return SyncTiming.values.firstWhereOrNull(
          (value) => value.name == stored,
        ) ??
        SyncTiming.manual;
  }

  static const intervalOptions = [5, 15, 30, 60, 180, 360];

  static int get intervalMinutes {
    final value = appdata.implicitData['webdavSyncIntervalMinutes'];
    return value is int && intervalOptions.contains(value) ? value : 30;
  }

  bool get isConfigured => hasConfiguration;
  bool get hasConfiguration => _validateConfig()?.isValid == true;

  bool get hasPendingChanges {
    if (_coordinator != null && _coordinator!.store.outbox.isNotEmpty) {
      return true;
    }
    return appdata.implicitData['webdavSyncPending'] == true;
  }

  bool get isEnabled => timing != SyncTiming.manual && hasConfiguration;

  Timer? _scheduleTimer;
  Timer? _debounceTimer;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  DateTime? _lastRealtimeCheck;

  List<MergeConflict> get conflicts => _coordinator?.conflicts ?? const [];
  int get conflictCount => conflicts.length;
  bool get hasConflict => conflicts.isNotEmpty;

  List<SyncSourceIssue> get sourceIssues =>
      _coordinator?.sourceIssues ?? const [];
  Set<String> get unavailableDomains =>
      _coordinator?.unavailableDomains ?? const {};
  bool get isPartial =>
      unavailableDomains.isNotEmpty ||
      sourceIssues.any((issue) => !issue.recovered);

  @visibleForTesting
  static DateTime Function()? debugNow;

  DateTime get _now => debugNow?.call() ?? DateTime.now();

  static String endpointTarget(WebDavEndpoint endpoint) {
    return '${endpoint.url}#${endpoint.user}';
  }

  /// Called at startup and resume, independently of the home page being mounted.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (_disposed ||
        !_startupReady ||
        _configuring ||
        !isEnabled ||
        _active != null)
      return;
    if (timing == SyncTiming.realtime) {
      if (!startup &&
          _lastRealtimeCheck != null &&
          _now.difference(_lastRealtimeCheck!) < const Duration(minutes: 10)) {
        return;
      }
      _lastRealtimeCheck = _now;
    } else {
      final stored = appdata.implicitData['webdavSyncLastAttempt'];
      final last = stored is int
          ? DateTime.fromMillisecondsSinceEpoch(stored)
          : null;
      final interval = Duration(minutes: intervalMinutes);
      final elapsed = last == null ? interval : _now.difference(last);
      final remaining = interval - (elapsed.isNegative ? interval : elapsed);
      if (remaining > Duration.zero) {
        _scheduleTimer = Timer(remaining, checkForAutomaticSync);
        return;
      }
    }
    unawaited(syncNow());
  }

  /// Prepares a new endpoint without touching business data. Configuration
  /// persistence commits first; subsequent transfer is a separate queued task.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required SyncDirection direction,
    required SyncTiming timing,
    required int minutes,
  }) {
    final draft = List<String>.of(config);
    return _enqueue(_DataSyncTask.configure, () async {
      _configuring = true;
      final oldConfig = appdata.settings['webdav'];
      final oldFields = appdata.settings['disableSyncFields'];
      final oldCoordinator = _coordinator;
      final oldNeedsRecovery = _coordinatorNeedsRecovery;
      final oldReady = _startupReady;
      const configKeys = [
        'webdavSyncDirection',
        'webdavSyncTiming',
        'webdavSyncIntervalMinutes',
        'webdavSyncLastAttempt',
        'webdavSyncPending',
      ];
      final oldImplicit = {
        for (final key in configKeys)
          if (appdata.implicitData.containsKey(key))
            key: appdata.implicitData[key],
      };
      var mutated = false;
      var committed = false;
      try {
        MergeSyncCoordinator? prepared;
        if (draft.isNotEmpty) {
          if (draft.length != 3) {
            return const Res.error('Invalid WebDAV configuration format');
          }
          final endpoint = WebDavEndpoint(
            url: draft[0],
            user: draft[1],
            password: draft[2],
          );
          if (!endpoint.isValid) {
            return const Res.error('WebDAV URL cannot be empty');
          }
          final client = _client(endpoint);
          await client.ping();
          final hash = MergeSyncCoordinator.computeEndpointHash(
            endpoint.url,
            endpoint.user,
          );
          final actor = await MergeSyncCoordinator.getOrCreateActorId();
          final directory =
              debugStateDirFactory?.call(hash) ??
              Directory(FilePath.join(App.dataPath, 'sync_state_$hash'));
          prepared = _createCoordinator(hash, directory, actor, client);
          // Validation/reconciliation may touch only endpoint metadata. Pending
          // business replay and legacy migration wait for the config commit.
          await prepared.store.load();
          await prepared.reconcileBackupRecoveryIfNeeded();
        }

        mutated = true;
        appdata.settings['webdav'] = draft;
        appdata.settings['disableSyncFields'] = excludedFields;
        appdata.implicitData['webdavSyncDirection'] = direction.name;
        appdata.implicitData['webdavSyncTiming'] =
            (draft.isEmpty ? SyncTiming.manual : timing).name;
        appdata.implicitData['webdavSyncIntervalMinutes'] =
            intervalOptions.contains(minutes) ? minutes : 30;
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        appdata.implicitData['webdavSyncPending'] =
            prepared?.store.outbox.isNotEmpty ?? false;
        await appdata.saveData(false);
        await appdata.writeImplicitData();
        committed = true;
        _coordinator = prepared;
        _coordinatorNeedsRecovery = prepared != null;
        _startupReady = true;
        _startupError = null;
        if (prepared != null && timing != SyncTiming.manual) {
          // Queued behind configure, with the usual import zone/error/status
          // semantics. A failed transfer does not undo a saved configuration.
          unawaited(syncNow());
        }
        return const Res(true);
      } catch (error, stack) {
        Log.error('Data Sync', 'Configure error: $error\n$stack');
        if (mutated && !committed) {
          appdata.settings['webdav'] = oldConfig;
          appdata.settings['disableSyncFields'] = oldFields;
          for (final key in configKeys) {
            if (oldImplicit.containsKey(key)) {
              appdata.implicitData[key] = oldImplicit[key];
            } else {
              appdata.implicitData.remove(key);
            }
          }
          _coordinator = oldCoordinator;
          _coordinatorNeedsRecovery = oldNeedsRecovery;
          _startupReady = oldReady;
          try {
            await appdata.saveData(false);
            await appdata.writeImplicitData();
          } catch (restoreError) {
            return Res.error(
              '$error; restoring configuration failed: $restoreError',
            );
          }
        }
        return Res.error(error.toString());
      } finally {
        _configuring = false;
        _lastRealtimeCheck = _now;
        if (!_disposed) notifyListeners();
      }
    });
  }

  bool _handleWindowClose() {
    if (_hasUploadWork) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  bool _canUpload(_SyncRequest request) =>
      request.type == _DataSyncTask.upload ||
      request.type == _DataSyncTask.resolve ||
      (request.type == _DataSyncTask.sync &&
          direction != SyncDirection.downloadOnly);

  bool get _hasUploadWork =>
      direction != SyncDirection.downloadOnly &&
      ((_active != null && _canUpload(_active!)) ||
          _queue.any(_canUpload) ||
          (_coordinator?.store.outbox.isNotEmpty ?? false));

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: 'Shut Down'.tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: 'Uploading data...'.tl,
    );
    await _waitForUploadBeforeClose();
    exit(0);
  }

  Future<void> _waitForUploadBeforeClose() async {
    while (_hasUploadWork) {
      if (_active != null) {
        await _active!.completer.future;
      } else {
        break;
      }
    }
  }

  Future<void> waitForDownload() async {
    while ((_active != null && _active!.type != _DataSyncTask.upload) ||
        _queue.any((request) => request.type != _DataSyncTask.upload)) {
      if (_active != null) {
        await _active!.completer.future;
      } else {
        break;
      }
    }
  }

  Future<Res<bool>> waitForSync() async {
    Res<bool> result = const Res(true);
    while (_active != null) {
      final next = await _active!.completer.future;
      if (next.error) result = next;
    }
    return result.error
        ? result
        : (_lastError == null ? const Res(true) : Res.error(_lastError!));
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  @visibleForTesting
  static Future<Res<bool>> Function()? debugUploadOverride;

  @visibleForTesting
  static Future<Res<bool>> Function()? debugDownloadOverride;

  @visibleForTesting
  static Future<Res<bool>> Function()? debugSyncOverride;

  @visibleForTesting
  static dav.Client Function(WebDavEndpoint)? debugClientFactory;

  @visibleForTesting
  static Future<SyncRecords> Function()? debugExportRecords;

  @visibleForTesting
  static Future<void> Function(SyncRecords, {void Function()? beforeCommit})?
  debugApplyRecords;

  @visibleForTesting
  static Directory Function(String endpointHash)? debugStateDirFactory;

  @visibleForTesting
  static bool debugDisableWindowCloseHandler = false;

  @visibleForTesting
  Future<void> debugWaitForUploadBeforeClose() {
    return _waitForUploadBeforeClose();
  }

  @visibleForTesting
  static void resetForTesting() {
    instance?.dispose();
    instance = null;
    debugUploadOverride = null;
    debugDownloadOverride = null;
    debugSyncOverride = null;
    debugDisableWindowCloseHandler = false;
    debugNow = null;
    debugClientFactory = null;
    debugExportRecords = null;
    debugApplyRecords = null;
    debugStateDirFactory = null;
  }

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  bool _isUploading = false;
  bool get isUploading => _isUploading;

  bool get isSyncing => _active != null;

  _SyncRequest? _active;
  final List<_SyncRequest> _queue = [];

  String? _lastError;
  String? get lastError => _lastError;

  @override
  void dispose() {
    _disposed = true;
    _scheduleTimer?.cancel();
    _debounceTimer?.cancel();
    appdata.registerSyncDataRequestHandler(null);
    appdata.settings.removeListener(onDataChanged);
    LocalFavoritesManager().removeListener(onDataChanged);
    ComicSourceManager().removeListener(onDataChanged);
    HistoryManager().removeListener(onDataChanged);
    ImageFavoriteManager().removeListener(onDataChanged);
    CookieJarSql.registerCookiesChangedHandler(null);
    super.dispose();
  }

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isConfigured: hasConfiguration,
    isEnabled: isEnabled,
    direction: direction,
    timing: timing,
    isUploading: _isUploading,
    isDownloading: _isDownloading,
    isSyncing: isSyncing,
    lastSyncTime: (appdata.implicitData['webdavSyncLastAttempt'] as int?) ?? 0,
    lastError: _lastError,
    hasConflict: hasConflict,
    conflictCount: conflictCount,
    sourceIssues: sourceIssues,
    unavailableDomains: unavailableDomains,
    isPartial: isPartial,
  );

  WebDavEndpoint? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return WebDavEndpoint(url: '', user: '', password: '');
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return WebDavEndpoint(
      url: config[0] as String,
      user: config[1] as String,
      password: config[2] as String,
    );
  }

  MergeSyncCoordinator _createCoordinator(
    String hash,
    Directory directory,
    String actor,
    dav.Client client,
  ) {
    final coordinator = MergeSyncCoordinator(
      endpointHash: hash,
      stateDirectory: directory,
      actor: actor,
      store: MergeStore(directory, actor),
      remote: MergeRemote(client),
      exportPreferencesOverride: debugExportRecords,
      applyPreferencesOverride: debugApplyRecords,
      getGenerationOverride: () => _changeGeneration,
    );
    if (debugExportRecords != null) {
      coordinator.exportFavoritesOverride = () => {};
      coordinator.exportHistoryOverride = () => Future.value({});
    }
    if (debugApplyRecords != null) {
      coordinator.applyFavoritesOverride = (_) {};
      coordinator.applyHistoryOverride = (_) {};
    }
    return coordinator;
  }

  Future<void> _ensureCoordinatorLoaded() async {
    if (_coordinator == null) {
      final endpoint = _validateConfig();
      if (endpoint == null || !endpoint.isValid) return;
      final hash = MergeSyncCoordinator.computeEndpointHash(
        endpoint.url,
        endpoint.user,
      );
      final actor = await MergeSyncCoordinator.getOrCreateActorId();
      final directory =
          debugStateDirFactory?.call(hash) ??
          Directory(FilePath.join(App.dataPath, 'sync_state_$hash'));
      _coordinator = _createCoordinator(
        hash,
        directory,
        actor,
        _client(endpoint),
      );
      _coordinatorNeedsRecovery = true;
    }
    if (_coordinatorNeedsRecovery) {
      await _coordinator!.startupRecovery();
      _coordinatorNeedsRecovery = false;
    }
  }

  Future<Res<bool>> syncNow() => _enqueue(_DataSyncTask.sync, () {
    return _syncDataNow();
  }, key: _DataSyncTask.sync);

  Future<Res<bool>> syncData() => syncNow();

  Future<Res<bool>> uploadData() => _enqueue(_DataSyncTask.upload, () {
    if (direction == SyncDirection.downloadOnly) {
      return Future.value(
        const Res.error('Action not allowed by current sync direction'),
      );
    }
    return _uploadDataNow();
  }, key: _DataSyncTask.upload);

  Future<Res<bool>> downloadData() {
    return _enqueue(_DataSyncTask.download, () {
      if (direction == SyncDirection.uploadOnly) {
        return Future.value(
          const Res.error('Action not allowed by current sync direction'),
        );
      }
      return _downloadDataNow();
    }, key: _DataSyncTask.download);
  }

  Future<Res<bool>> resolveConflict({
    required String recordKey,
    required String field,
    required String candidateId,
  }) {
    return _enqueue(_DataSyncTask.resolve, () async {
      await _ensureCoordinatorLoaded();
      if (_coordinator == null) {
        return const Res.error('WebDAV is not configured');
      }
      return await _coordinator!.resolveConflict(
        recordKey: recordKey,
        field: field,
        candidateId: candidateId,
        direction: direction,
      );
    }, key: (_DataSyncTask.resolve, recordKey, field, candidateId));
  }

  Future<Res<bool>> repairSourceIssue({
    required SyncSourceIssue issue,
    required String replacementContent,
  }) {
    return _enqueue(
      _DataSyncTask.repair,
      () => _repairSourceIssueNow(
        issue: issue,
        replacementContent: replacementContent,
      ),
      key: (_DataSyncTask.repair, issue),
    );
  }

  Future<Res<bool>> _repairSourceIssueNow({
    required SyncSourceIssue issue,
    required String replacementContent,
  }) async {
    await _ensureCoordinatorLoaded();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return const Res.error('Sync coordinator is not configured or available');
    }
    if (issue.recovered || !coordinator.sourceIssues.contains(issue)) {
      return const Res.error(
        'This source issue is no longer current. Refresh the issue list and retry.',
      );
    }

    final isLegacy = issue.archiveName != null;
    if (!isLegacy && issue.reason == 'journalCorrupted') {
      return const Res.error(
        'The recovery journal is incomplete. Export the original files and backups, restore a complete journal matching the current quarantine, then retry. Do not delete the journal or reinstall sources to bypass recovery.',
      );
    }
    final normalizedFilename = issue.filename.replaceAll('\\', '/');
    final filenameParts = normalizedFilename.split('/');
    if (issue.filename.endsWith('.tmp') ||
        issue.filename.endsWith('.stage') ||
        filenameParts.any((part) => part == '.' || part == '..') ||
        normalizedFilename.contains('\u0000') ||
        normalizedFilename.contains(':')) {
      return const Res.error(
        'The selected file cannot safely repair this source issue.',
      );
    }
    if (isLegacy) {
      final validLegacyEntry =
          !p.isAbsolute(normalizedFilename) &&
          (filenameParts.length == 1 ||
              (filenameParts.length == 2 &&
                  filenameParts.first == 'comic_source')) &&
          filenameParts.every((part) => part.isNotEmpty);
      if (!validLegacyEntry) {
        return const Res.error(
          'The selected file cannot safely repair this source issue.',
        );
      }
    } else {
      final isRecoveryJournal =
          normalizedFilename == '.quarantine/journal.json';
      final isSafeLocalTarget =
          !p.isAbsolute(normalizedFilename) &&
          (filenameParts.length == 1 || isRecoveryJournal) &&
          filenameParts.every((part) => part.isNotEmpty);
      if (!isSafeLocalTarget) {
        return const Res.error(
          'The selected file cannot safely repair this source issue.',
        );
      }
    }

    if (isLegacy) {
      final backupPath = issue.backupPath;
      if (backupPath == null) {
        return const Res.error('The verified original archive is unavailable.');
      }
      final backupFile = File(backupPath);
      final backupName = p.basename(backupPath);
      if (!RegExp(r'^[0-9a-f]{64}\.venera$').hasMatch(backupName) ||
          !await backupFile.exists()) {
        return const Res.error('The verified original archive is unavailable.');
      }

      final backupDirectory = Directory(
        p.join(coordinator.stateDirectory.path, 'legacy_source_backups'),
      );
      if (!await backupDirectory.exists()) {
        return const Res.error(
          'The verified original archive is not bound to this sync endpoint.',
        );
      }
      final expectedDirectoryPath = p.normalize(
        p.absolute(backupDirectory.path),
      );
      final selectedFilePath = p.normalize(p.absolute(backupFile.path));
      final expectedDirectoryRealPath = await backupDirectory
          .resolveSymbolicLinks();
      final stateDirectoryRealPath = await coordinator.stateDirectory
          .resolveSymbolicLinks();
      final expectedBackupRealPath = p.join(
        stateDirectoryRealPath,
        'legacy_source_backups',
      );
      final selectedFileRealPath = await backupFile.resolveSymbolicLinks();
      if (!p.equals(expectedDirectoryRealPath, expectedBackupRealPath) ||
          !p.equals(p.dirname(selectedFilePath), expectedDirectoryPath) ||
          !p.equals(
            p.dirname(selectedFileRealPath),
            expectedDirectoryRealPath,
          )) {
        return const Res.error(
          'The verified original archive is not bound to this sync endpoint.',
        );
      }

      final archiveSha = backupName.substring(0, 64);
      final actualSha = (await sha256.bind(backupFile.openRead()).first)
          .toString()
          .toLowerCase();
      if (actualSha != archiveSha) {
        return const Res.error(
          'The verified original archive failed its content check.',
        );
      }

      final overrideDir = Directory(
        p.join(coordinator.stateDirectory.path, 'legacy_overrides'),
      );
      final bool registered;
      try {
        registered = await LegacySyncReader.registerLegacyOverride(
          overrideDirectory: overrideDir,
          archiveSha256: archiveSha,
          entryFilename: issue.filename,
          replacementContent: replacementContent,
          expectedKey: issue.sourceKey,
        );
      } on FormatException {
        return const Res.error(
          'Legacy repair metadata or the selected file is invalid. The original archive remains available for export.',
        );
      }
      if (!registered) {
        return const Res.error(
          'The selected file did not pass legacy repair validation.',
        );
      }
    } else {
      try {
        final repaired = await coordinator.preferencesAdapter.repairLocalSource(
          issue: issue,
          replacementContent: replacementContent,
        );
        if (!repaired) {
          return const Res.error(
            'The selected file does not match this source issue. Refresh the issue list and retry.',
          );
        }
      } on SourceRepairPendingException catch (error) {
        if (!error.fileCommitted) rethrow;
        if (hasConfiguration) unawaited(syncNow());
        return Res.error(
          error.reason == 'runtimeReloadDeferred'
              ? 'Source file was saved. Runtime reload is deferred until source dependencies are available.'
              : error.reason == 'runtimeReloadFailed'
              ? 'Source file was saved, but runtime reload is still pending.'
              : 'Source file was saved; repair completion is still pending.',
        );
      }
    }

    // Queue the network retry separately. Its later failure cannot undo this
    // committed local repair or change its result.
    if (hasConfiguration) unawaited(syncNow());
    return const Res(true);
  }

  Future<Res<bool>> _syncDataNow() async {
    if (debugSyncOverride != null) {
      return await debugSyncOverride!();
    }
    if (direction == SyncDirection.uploadOnly) return _uploadDataNow();
    if (direction == SyncDirection.downloadOnly) return _downloadDataNow();
    await _ensureCoordinatorLoaded();
    if (_coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    return await _coordinator!.performSync(direction: direction);
  }

  Future<Res<bool>> _uploadDataNow() async {
    if (debugUploadOverride != null) {
      return await debugUploadOverride!();
    }
    await _ensureCoordinatorLoaded();
    if (_coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    return await _coordinator!.performSync(direction: SyncDirection.uploadOnly);
  }

  Future<Res<bool>> _downloadDataNow() async {
    if (debugDownloadOverride != null) {
      return await debugDownloadOverride!();
    }
    await _ensureCoordinatorLoaded();
    if (_coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    return await _coordinator!.performSync(
      direction: SyncDirection.downloadOnly,
    );
  }

  Future<Res<bool>> _enqueue(
    _DataSyncTask type,
    Future<Res<bool>> Function() run, {
    Object? key,
  }) {
    if (_disposed) {
      return Future.value(const Res.error('Sync service is disposed'));
    }
    if (key != null && _queue.isNotEmpty && _queue.last.key == key) {
      return _queue.last.completer.future;
    }
    final request = _SyncRequest(type, run, key);
    _scheduleTimer?.cancel();
    if (_active == null) {
      _active = request;
      unawaited(_runTask(request));
    } else {
      _queue.add(request);
    }
    return request.completer.future;
  }

  Future<void> _runTask(_SyncRequest request) async {
    _lastError = null;
    Res<bool> result;

    if (request.type == _DataSyncTask.upload) {
      _isUploading = true;
    } else if (request.type == _DataSyncTask.download) {
      _isDownloading = true;
    } else if (request.type == _DataSyncTask.sync) {
      if (direction == SyncDirection.uploadOnly) {
        _isUploading = true;
      } else if (direction == SyncDirection.downloadOnly) {
        _isDownloading = true;
      } else {
        _isUploading = true;
        _isDownloading = true;
      }
    }

    if (request.type != _DataSyncTask.configure &&
        request.type != _DataSyncTask.repair &&
        hasConfiguration) {
      appdata.implicitData['webdavSyncLastAttempt'] =
          _now.millisecondsSinceEpoch;
    }

    try {
      if (!_disposed) notifyListeners();

      if (request.type != _DataSyncTask.configure &&
          request.type != _DataSyncTask.repair &&
          !hasConfiguration) {
        result = const Res.error(
          'WebDAV is not configured. Please configure it first.',
        );
      } else {
        await _startupCompleter.future;
        if (request.type != _DataSyncTask.configure &&
            request.type != _DataSyncTask.repair) {
          if (!isReady) {
            try {
              await runZoned(
                _ensureCoordinatorLoaded,
                zoneValues: {_importZoneKey: true},
              );
              if (_coordinator != null) {
                _startupReady = true;
                _startupError = null;
              }
            } catch (e, s) {
              Log.error('DataSync', 'Startup recovery retry failed: $e\n$s');
              _startupError = e;
              _startupReady = false;
              _lastError = e.toString();
              if (!_disposed) notifyListeners();
              throw StateError('Sync startup recovery failed: $_startupError');
            }
          }
          if (!isReady) {
            throw StateError('Sync startup recovery failed: $_startupError');
          }
        }
        final runGeneration = _changeGeneration;
        result = await runZoned(
          request.run,
          zoneValues: {_importZoneKey: true},
        );
        if (request.type != _DataSyncTask.configure &&
            request.type != _DataSyncTask.repair) {
          appdata.implicitData['webdavSyncLastAttempt'] =
              _now.millisecondsSinceEpoch;
          if (result.success &&
              _changeGeneration == runGeneration &&
              (_coordinator?.store.outbox.isEmpty ?? true)) {
            appdata.implicitData['webdavSyncPending'] = false;
          }
          await appdata.writeImplicitData();
        }
      }
    } catch (error, stack) {
      Log.error(
        'Data Sync',
        request.type == _DataSyncTask.repair ? 'Source repair failed' : error,
        stack,
      );
      result = Res.error(
        request.type == _DataSyncTask.repair
            ? 'Source repair could not complete because local storage or runtime access failed.'
            : error.toString(),
      );
      if (request.type != _DataSyncTask.configure &&
          request.type != _DataSyncTask.repair) {
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        try {
          await appdata.writeImplicitData();
        } catch (_) {}
      }
    } finally {
      _isUploading = false;
      _isDownloading = false;
    }

    _lastError = result.errorMessage;
    _active = null;

    if (_queue.isNotEmpty) {
      _active = _queue.removeAt(0);
      unawaited(_runTask(_active!));
    } else if (!_disposed && timing == SyncTiming.scheduled) {
      checkForAutomaticSync();
    }

    request.completer.complete(result);
    if (!_disposed) notifyListeners();
  }

  dav.Client _client(WebDavEndpoint endpoint) =>
      debugClientFactory?.call(endpoint) ??
      endpoint.createClient(logRequests: true);
}
