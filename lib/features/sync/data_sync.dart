import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
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
import 'sync_device.dart';

const bool _syncDiagnosticsEnabled =
    kDebugMode || bool.fromEnvironment('VENERA_SYNC_DIAGNOSTICS');

enum _DataSyncTask {
  sync,
  upload,
  download,
  configure,
  resolve,
  repair,
  listBackups,
}

class _SyncRequest {
  _SyncRequest(
    this.type,
    this.run,
    this.key, {
    this.trigger,
    this.checkRemote = false,
    this.forceCapture = false,
  });
  final _DataSyncTask type;
  final Future<Res<bool>> Function() run;
  final Object? key;
  final String? trigger;
  final bool checkRemote;
  final bool forceCapture;
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
    this.lastTrigger,
    this.lastSuccessTime = 0,
    this.lastSyncDurationMs = 0,
    this.pendingChangeCount = 0,
    this.changedRecordCounts = const {},
    this.uploadedBytes = 0,
    this.downloadedBytes = 0,
    this.uploadedObjects = 0,
    this.downloadedObjects = 0,
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
  final String? lastTrigger;
  final int lastSuccessTime;
  final bool hasConflict;
  final int conflictCount;
  final List<SyncSourceIssue> sourceIssues;
  final Set<String> unavailableDomains;
  final bool isPartial;
  final int lastSyncDurationMs;
  final int pendingChangeCount;
  final Map<String, int> changedRecordCounts;
  final int uploadedBytes;
  final int downloadedBytes;
  final int uploadedObjects;
  final int downloadedObjects;
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
    _appDataSettingsSnapshot = canonicalSyncJson(appdata.exportSyncSettings());
    _appDataSearchSnapshot = canonicalSyncJson(
      appdata.exportSearchHistoryRecords(),
    );
    appdata.registerSyncDataRequestHandler(_onAppDataSaveRequested);
    appdata.settings.addListener(_onSettingsChanged);
    LocalFavoritesManager().addListener(_onFavoritesChanged);
    ComicSourceManager().addListener(_onSourcesChanged);
    HistoryManager().addListener(_onHistoryChanged);
    ImageFavoriteManager().addListener(_onImageFavoritesChanged);
    CookieJarSql.registerCookiesChangedHandler(_onCookiesChanged);

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
  static const _changeQuietPeriod = Duration(seconds: 10);
  static const _minimumUploadInterval = Duration(seconds: 60);
  static const _maximumDirtyWait = Duration(minutes: 2);
  static const _remoteCheckInterval = Duration(minutes: 10);

  static const _importZoneKey = #_dataSyncImporting;
  late String _appDataSettingsSnapshot;
  late String _appDataSearchSnapshot;

  Timer? _scheduleTimer;
  Timer? _debounceTimer;
  Timer? _remoteCheckTimer;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  DateTime? _dirtySince;
  DateTime? _lastLocalChange;
  bool _localDirty = false;
  bool _automaticAuthenticationBlocked =
      appdata.implicitData['webdavSyncAuthenticationBlocked'] == true;
  bool _flushRequested = false;
  bool _activeRequestDidRemote = false;
  Set<String>? _unattachedDirtyDomains = <String>{};

  DateTime get _now => debugNow?.call() ?? DateTime.now();

  void _onSettingsChanged() => _observeAppDataSyncChanges(const {'setting'});

  void _onAppDataSaveRequested({Set<String>? domains}) {
    _observeAppDataSyncChanges(domains);
  }

  void _observeAppDataSyncChanges(Set<String>? requestedDomains) {
    final changed = <String>{};
    if (requestedDomains == null || requestedDomains.contains('setting')) {
      final current = canonicalSyncJson(appdata.exportSyncSettings());
      if (current != _appDataSettingsSnapshot) {
        _appDataSettingsSnapshot = current;
        changed.add('setting');
      }
    }
    if (requestedDomains == null || requestedDomains.contains('search')) {
      final current = canonicalSyncJson(appdata.exportSearchHistoryRecords());
      if (current != _appDataSearchSnapshot) {
        _appDataSearchSnapshot = current;
        changed.add('search');
      }
    }
    if (changed.isNotEmpty) onDataChanged(domains: changed);
  }

  void _onFavoritesChanged() =>
      onDataChanged(domains: const {'favorite', 'folder', 'favoriteRole'});
  void _onSourcesChanged() =>
      onDataChanged(domains: const {'source', 'sourceSession'});
  void _onHistoryChanged() =>
      onDataChanged(domains: const {'history', 'historyChapter'});
  void _onImageFavoritesChanged() =>
      onDataChanged(domains: const {'imageFavorite'});
  void _onCookiesChanged() => onDataChanged(domains: const {'cookies'});

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

  void onDataChanged({Set<String>? domains}) {
    if (_disposed ||
        Zone.current[_importZoneKey] == true ||
        (domains != null && domains.isEmpty)) {
      return;
    }
    _changeGeneration++;
    final coordinator = _coordinator;
    if (coordinator != null) {
      coordinator.markDirty(domains == null ? null : Set.of(domains));
    } else if (domains == null) {
      _unattachedDirtyDomains = null;
    } else if (_unattachedDirtyDomains != null) {
      _unattachedDirtyDomains!.addAll(domains);
    }
    _localDirty = true;
    _dirtySince ??= _now;
    _lastLocalChange = _now;
    if (!hasConfiguration) return;
    if (appdata.implicitData['webdavSyncPending'] != true) {
      appdata.implicitData['webdavSyncPending'] = true;
      _writeImplicitStatus();
    }
    _scheduleAutomaticWork();
    if (!_disposed) notifyListeners();
  }

  void _writeImplicitStatus() {
    unawaited(
      appdata.writeImplicitData().catchError((Object error, StackTrace stack) {
        Log.error('Data Sync', error, stack);
        _lastError = error.toString();
        if (!_disposed) notifyListeners();
      }),
    );
  }

  DateTime? _readTimestamp(String key) {
    final value = appdata.implicitData[key];
    return value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }

  DateTime? get _retryNotBefore => _readTimestamp('webdavSyncRetryAfter');

  bool get _automaticWorkBlocked {
    if (_automaticAuthenticationBlocked ||
        appdata.implicitData['webdavSyncAuthenticationBlocked'] == true) {
      return true;
    }
    final retryAt = _retryNotBefore;
    return retryAt != null && _now.isBefore(retryAt);
  }

  bool get _remoteCheckDue {
    if (direction == SyncDirection.uploadOnly) return false;
    final last = _readTimestamp('webdavSyncLastRemoteCheck');
    if (last == null) return true;
    return !_now.isBefore(last) &&
        _now.difference(last) >= _remoteCheckInterval;
  }

  bool get _uploadThrottleActive {
    final lastUpload =
        _readTimestamp('webdavSyncLastUploadAttempt') ??
        _readTimestamp('webdavSyncLastAttempt');
    return lastUpload != null &&
        _now.isBefore(lastUpload.add(_minimumUploadInterval));
  }

  DateTime _nextLocalChangeAttempt() {
    final now = _now;
    final quietDeadline = _flushRequested
        ? now
        : (_lastLocalChange ?? now).add(_changeQuietPeriod);
    final maximumDeadline = (_dirtySince ?? now).add(_maximumDirtyWait);
    var deadline = quietDeadline.isAfter(maximumDeadline)
        ? maximumDeadline
        : quietDeadline;
    if (direction != SyncDirection.downloadOnly) {
      final lastUpload =
          _readTimestamp('webdavSyncLastUploadAttempt') ??
          _readTimestamp('webdavSyncLastAttempt');
      if (lastUpload != null) {
        final uploadDeadline = lastUpload.add(_minimumUploadInterval);
        if (uploadDeadline.isAfter(deadline)) deadline = uploadDeadline;
      }
    }
    final retryAt = _retryNotBefore;
    if (retryAt != null && retryAt.isAfter(deadline)) deadline = retryAt;
    return deadline;
  }

  void _scheduleAutomaticWork() {
    if (_disposed ||
        !_startupReady ||
        _configuring ||
        timing != SyncTiming.realtime ||
        !isEnabled ||
        _automaticAuthenticationBlocked ||
        appdata.implicitData['webdavSyncAuthenticationBlocked'] == true) {
      return;
    }
    final retryAt = _retryNotBefore;
    if (retryAt != null && _now.isBefore(retryAt)) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(retryAt.difference(_now), () {
        _debounceTimer = null;
        if (!_disposed) _scheduleAutomaticWork();
      });
      return;
    }
    _scheduleRemoteCheckTimer();
    if (_active != null) return;
    final checkRemote = _remoteCheckDue;
    if (checkRemote) {
      final remoteOnly =
          _localDirty &&
          direction == SyncDirection.bidirectional &&
          _uploadThrottleActive;
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _queueAutomaticSync(
        trigger: remoteOnly || !_localDirty ? 'Remote check' : 'Local changes',
        checkRemote: true,
        forceCapture: false,
        remoteOnly: remoteOnly,
      );
      return;
    }
    if (!_localDirty && !hasPendingChanges) return;
    if (direction == SyncDirection.downloadOnly) return;
    final remaining = _nextLocalChangeAttempt().difference(_now);
    if (remaining <= Duration.zero) {
      _queueAutomaticSync(
        trigger: 'Local changes',
        checkRemote: false,
        forceCapture: false,
      );
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(remaining, () {
      _debounceTimer = null;
      if (!_disposed) _scheduleAutomaticWork();
    });
  }

  void _scheduleRemoteCheckTimer() {
    _remoteCheckTimer?.cancel();
    _remoteCheckTimer = null;
    if (_disposed ||
        !_startupReady ||
        _configuring ||
        !isEnabled ||
        direction == SyncDirection.uploadOnly ||
        _automaticWorkBlocked) {
      return;
    }
    final last = _readTimestamp('webdavSyncLastRemoteCheck');
    final dueAt = (last ?? _now).add(_remoteCheckInterval);
    final retryAt = _retryNotBefore;
    final deadline = retryAt != null && retryAt.isAfter(dueAt)
        ? retryAt
        : dueAt;
    final remaining = deadline.difference(_now);
    if (remaining <= Duration.zero) {
      if (_active == null) {
        _queueAutomaticSync(
          trigger: 'Remote check',
          checkRemote: true,
          forceCapture: false,
        );
      }
      return;
    }
    _remoteCheckTimer = Timer(remaining, () {
      _remoteCheckTimer = null;
      if (!_disposed) _scheduleAutomaticWork();
    });
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
  Map<String, String> get deviceNames =>
      _coordinator?.remote.deviceNames ?? const {};
  SyncRecords get localObservedRecords =>
      _coordinator?.store.observed ?? const {};
  int get pendingChangeCount => _coordinator?.pendingChangeCount ?? 0;
  Map<String, int> get changedRecordCounts =>
      _coordinator?.changedRecordCounts ?? const {};
  int get uploadedBytes => _coordinator?.remote.uploadedBytes ?? 0;
  int get downloadedBytes => _coordinator?.remote.downloadedBytes ?? 0;
  int get uploadedObjects => _coordinator?.remote.uploadedObjects ?? 0;
  int get downloadedObjects => _coordinator?.remote.downloadedObjects ?? 0;
  int get lastSyncDurationMs => _coordinator?.lastSyncDurationMs ?? 0;

  @visibleForTesting
  static DateTime Function()? debugNow;

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

  static String endpointTarget(WebDavEndpoint endpoint) {
    return '${endpoint.url}#${endpoint.user}';
  }

  /// Called at startup and resume, independently of the home page being mounted.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (_disposed || !_startupReady || _configuring || !isEnabled) {
      return;
    }

    if (timing == SyncTiming.scheduled) {
      if (_automaticAuthenticationBlocked) return;
      final last = _readTimestamp('webdavSyncLastAttempt');
      final interval = Duration(minutes: intervalMinutes);
      final elapsed = last == null ? interval : _now.difference(last);
      var remaining = interval - (elapsed.isNegative ? interval : elapsed);
      final retryAt = _retryNotBefore;
      if (retryAt != null && retryAt.isAfter(_now)) {
        final retryRemaining = retryAt.difference(_now);
        if (retryRemaining > remaining) remaining = retryRemaining;
      }
      if (remaining > Duration.zero) {
        _scheduleTimer = Timer(remaining, () => checkForAutomaticSync());
        return;
      }
      if (_active == null) {
        _queueAutomaticSync(
          trigger: 'Scheduled sync',
          checkRemote: direction != SyncDirection.uploadOnly,
          forceCapture: true,
        );
      }
      return;
    }
    if (timing != SyncTiming.realtime) return;

    _localDirty = _localDirty || hasPendingChanges;
    if (_localDirty) {
      _dirtySince ??= _now;
      _lastLocalChange ??= _now;
    }
    if (_automaticWorkBlocked) {
      _scheduleAutomaticWork();
      return;
    }
    if (_active != null) {
      return;
    }
    if (startup) {
      _queueAutomaticSync(
        trigger: 'Startup check',
        checkRemote: _remoteCheckDue,
        forceCapture: true,
      );
    } else if (_remoteCheckDue) {
      _queueAutomaticSync(
        trigger: 'Resume check',
        checkRemote: true,
        forceCapture: true,
      );
    } else {
      _scheduleAutomaticWork();
    }
    _scheduleRemoteCheckTimer();
  }

  void _queueAutomaticSync({
    required String trigger,
    required bool checkRemote,
    required bool forceCapture,
    bool remoteOnly = false,
  }) {
    if (_disposed || !isEnabled) return;
    if (_active != null) {
      return;
    }
    final retryAt = _retryNotBefore;
    final failureCount = appdata.implicitData['webdavSyncFailureCount'];
    final effectiveTrigger =
        failureCount is int &&
            failureCount > 0 &&
            retryAt != null &&
            !_now.isBefore(retryAt)
        ? 'Retry'
        : trigger;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(
      _enqueue(
        _DataSyncTask.sync,
        () => _executeAutomaticSync(
          checkRemote: checkRemote,
          forceCapture: forceCapture,
          remoteOnly: remoteOnly,
        ),
        key: _DataSyncTask.sync,
        trigger: effectiveTrigger,
        checkRemote: checkRemote,
        forceCapture: forceCapture,
      ),
    );
  }

  /// Prepares a new endpoint without touching business data. Configuration
  /// persistence commits first; subsequent transfer is a separate queued task.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required SyncDirection direction,
    required SyncTiming timing,
    required int minutes,
    String? deviceName,
    Set<String>? excludedDomains,
  }) {
    final draft = List<String>.of(config);
    final Set<String>? normalizedExcludedDomains;
    try {
      normalizedExcludedDomains = excludedDomains == null
          ? null
          : normalizeAppDataSyncExcludedDomains(excludedDomains);
    } catch (error) {
      return Future.value(Res.error(error.toString()));
    }
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
        'webdavSyncDeviceName',
        'webdavSyncFailureCount',
        'webdavSyncRetryAfter',
        'webdavSyncAuthenticationBlocked',
        appdataSyncExcludedDomainsKey,
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
        String? resolvedDeviceName;
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
          resolvedDeviceName = await _resolveDeviceName(deviceName);
          await client.ping();
          final hash = MergeSyncCoordinator.computeEndpointHash(
            endpoint.url,
            endpoint.user,
          );
          final actor = await MergeSyncCoordinator.getOrCreateActorId();
          final directory =
              debugStateDirFactory?.call(hash) ??
              Directory(FilePath.join(App.dataPath, 'sync_state_$hash'));
          prepared = _createCoordinator(
            hash,
            directory,
            actor,
            client,
            resolvedDeviceName,
          );
          // Validation/reconciliation may touch only endpoint metadata. Pending
          // business replay and legacy migration wait for the config commit.
          await prepared.store.load();
          await prepared.reconcileBackupRecoveryIfNeeded();
        }

        mutated = true;
        appdata.settings['webdav'] = draft;
        appdata.settings['disableSyncFields'] = excludedFields;
        if (resolvedDeviceName != null) {
          appdata.implicitData['webdavSyncDeviceName'] = resolvedDeviceName;
        }
        appdata.implicitData['webdavSyncDirection'] = direction.name;
        appdata.implicitData['webdavSyncTiming'] =
            (draft.isEmpty ? SyncTiming.manual : timing).name;
        appdata.implicitData['webdavSyncIntervalMinutes'] =
            intervalOptions.contains(minutes) ? minutes : 30;
        appdata.implicitData['webdavSyncPending'] =
            prepared?.store.outbox.isNotEmpty ?? false;
        if (normalizedExcludedDomains != null) {
          appdata.implicitData[appdataSyncExcludedDomainsKey] =
              normalizedExcludedDomains.toList()..sort();
        }
        appdata.implicitData
          ..remove('webdavSyncFailureCount')
          ..remove('webdavSyncRetryAfter')
          ..remove('webdavSyncAuthenticationBlocked');
        prepared?.markDirty(null);
        await appdata.saveData(false);
        await appdata.writeImplicitData();
        committed = true;
        _coordinator = prepared;
        _coordinatorNeedsRecovery = prepared != null;
        _startupReady = true;
        _startupError = null;
        _automaticAuthenticationBlocked = false;
        if (prepared != null && timing != SyncTiming.manual) {
          unawaited(
            _enqueue(
              _DataSyncTask.sync,
              () => _executeAutomaticSync(
                checkRemote: direction != SyncDirection.uploadOnly,
                forceCapture: true,
              ),
              key: _DataSyncTask.sync,
              trigger: timing == SyncTiming.scheduled
                  ? 'Scheduled sync'
                  : 'Startup check',
              checkRemote: direction != SyncDirection.uploadOnly,
              forceCapture: true,
            ),
          );
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
    _remoteCheckTimer?.cancel();
    appdata.registerSyncDataRequestHandler(null);
    appdata.settings.removeListener(_onSettingsChanged);
    LocalFavoritesManager().removeListener(_onFavoritesChanged);
    ComicSourceManager().removeListener(_onSourcesChanged);
    HistoryManager().removeListener(_onHistoryChanged);
    ImageFavoriteManager().removeListener(_onImageFavoritesChanged);
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
    lastSyncTime:
        _readTimestamp('webdavSyncLastAttempt')?.millisecondsSinceEpoch ?? 0,
    lastError: _lastError,
    hasConflict: hasConflict,
    conflictCount: conflictCount,
    sourceIssues: sourceIssues,
    unavailableDomains: unavailableDomains,
    isPartial: isPartial,
    lastTrigger: appdata.implicitData['webdavSyncLastTrigger'] is String
        ? appdata.implicitData['webdavSyncLastTrigger'] as String
        : null,
    lastSuccessTime:
        _readTimestamp('webdavSyncLastSuccess')?.millisecondsSinceEpoch ?? 0,
    lastSyncDurationMs: lastSyncDurationMs,
    pendingChangeCount: pendingChangeCount,
    changedRecordCounts: changedRecordCounts,
    uploadedBytes: uploadedBytes,
    downloadedBytes: downloadedBytes,
    uploadedObjects: uploadedObjects,
    downloadedObjects: downloadedObjects,
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
    String deviceName,
  ) {
    final coordinator = MergeSyncCoordinator(
      endpointHash: hash,
      stateDirectory: directory,
      actor: actor,
      store: MergeStore(directory, actor),
      remote: MergeRemote(
        client,
        deviceName: deviceName,
        cacheDirectory: Directory(
          FilePath.join(directory.path, 'remote-object-cache'),
        ),
      ),
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

  Future<String> _resolveDeviceName([String? requested]) async {
    if (requested != null) return normalizeSyncDeviceName(requested);
    final saved = appdata.implicitData['webdavSyncDeviceName'];
    if (saved is String && saved.trim().isNotEmpty) {
      return normalizeSyncDeviceName(saved);
    }
    return normalizeSyncDeviceName(await readSyncDeviceName());
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
      final deviceName = await _resolveDeviceName();
      appdata.implicitData['webdavSyncDeviceName'] = deviceName;
      await appdata.writeImplicitData();
      final directory =
          debugStateDirFactory?.call(hash) ??
          Directory(FilePath.join(App.dataPath, 'sync_state_$hash'));
      _coordinator = _createCoordinator(
        hash,
        directory,
        actor,
        _client(endpoint),
        deviceName,
      );
      _coordinatorNeedsRecovery = true;
    }
    if (_coordinatorNeedsRecovery || _coordinator!.store.needsRecovery) {
      await _coordinator!.startupRecovery();
      _coordinatorNeedsRecovery = false;
    }
    final dirtyDomains = _unattachedDirtyDomains;
    if (dirtyDomains == null || dirtyDomains.isNotEmpty) {
      _coordinator!.markDirty(
        dirtyDomains == null ? null : Set.of(dirtyDomains),
      );
      _unattachedDirtyDomains = <String>{};
    }
  }

  Future<Res<bool>> syncNow() => _enqueue(
    _DataSyncTask.sync,
    () => _syncDataNow(checkRemote: true, forceCapture: true),
    key: _DataSyncTask.sync,
    trigger: 'Manual sync',
    checkRemote: true,
    forceCapture: true,
  );

  Future<Res<bool>> syncData() => syncNow();
  Future<void> flushPendingChanges() async {
    if (_disposed ||
        !_startupReady ||
        _configuring ||
        !isEnabled ||
        timing != SyncTiming.realtime ||
        direction == SyncDirection.downloadOnly ||
        (!_localDirty && !hasPendingChanges)) {
      return;
    }
    _localDirty = true;
    _dirtySince ??= _now;
    _lastLocalChange ??= _now;
    _flushRequested = true;
    if (_active != null) {
      _scheduleAutomaticWork();
      await waitForSync();
      return;
    }
    if (_automaticWorkBlocked || _nextLocalChangeAttempt().isAfter(_now)) {
      _scheduleAutomaticWork();
      return;
    }
    final remoteDue = _remoteCheckDue;
    final remoteOnly = remoteDue && _uploadThrottleActive;
    _queueAutomaticSync(
      trigger: remoteOnly ? 'Remote check' : 'Local changes',
      checkRemote: remoteDue,
      forceCapture: false,
      remoteOnly: remoteOnly,
    );
    await waitForSync();
  }

  Future<List<LegacyRemoteBackup>> listLegacyBackups() async {
    List<LegacyRemoteBackup>? backups;
    final result = await _enqueue(_DataSyncTask.listBackups, () async {
      final coordinator = _coordinator;
      if (coordinator == null) {
        return const Res.error('WebDAV is not configured');
      }
      await _recordSyncAttempt(
        trigger: 'List root backups',
        checkRemote: false,
        requestUpload: false,
      );
      backups = await coordinator.listLegacyBackups();
      return const Res(true);
    }, trigger: 'List root backups');
    if (result.error) {
      throw StateError(result.errorMessage ?? 'Could not list root backups');
    }
    return backups!;
  }

  Future<Res<bool>> importLegacyBackup(String backupName) => _enqueue(
    _DataSyncTask.sync,
    () async {
      final coordinator = _coordinator;
      if (coordinator == null) {
        return const Res.error('WebDAV is not configured');
      }
      _activeRequestDidRemote = true;
      await _recordSyncAttempt(
        trigger: 'Import root backup',
        checkRemote: true,
        requestUpload: direction != SyncDirection.downloadOnly,
      );
      return coordinator.importLegacyBackup(backupName, direction: direction);
    },
    key: (_DataSyncTask.sync, 'root-backup-import', backupName),
    trigger: 'Import root backup',
    checkRemote: true,
    forceCapture: true,
  );

  Future<Res<bool>> uploadData() => _enqueue(
    _DataSyncTask.upload,
    () {
      if (direction == SyncDirection.downloadOnly) {
        return Future.value(
          const Res.error('Action not allowed by current sync direction'),
        );
      }
      return _uploadDataNow();
    },
    key: _DataSyncTask.upload,
    trigger: 'Manual sync',
    forceCapture: true,
  );

  Future<Res<bool>> downloadData() => _enqueue(
    _DataSyncTask.download,
    () {
      if (direction == SyncDirection.uploadOnly) {
        return Future.value(
          const Res.error('Action not allowed by current sync direction'),
        );
      }
      return _downloadDataNow();
    },
    key: _DataSyncTask.download,
    trigger: 'Manual sync',
    checkRemote: true,
  );

  Future<Res<bool>> resolveConflicts(
    List<MergeConflictResolution> resolutions,
  ) {
    final choices = List<MergeConflictResolution>.unmodifiable(resolutions);
    return _enqueue(
      _DataSyncTask.resolve,
      () async {
        await _ensureCoordinatorLoaded();
        if (_coordinator == null) {
          return const Res.error('WebDAV is not configured');
        }
        _activeRequestDidRemote = true;
        await _recordSyncAttempt(
          trigger: 'Manual sync',
          checkRemote: direction != SyncDirection.uploadOnly,
          requestUpload: direction != SyncDirection.downloadOnly,
        );
        return await _coordinator!.resolveConflicts(
          choices,
          direction: direction,
        );
      },
      trigger: 'Manual sync',
      checkRemote: true,
      forceCapture: true,
    );
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

  Future<Res<bool>> _executeAutomaticSync({
    required bool checkRemote,
    required bool forceCapture,
    bool remoteOnly = false,
  }) async {
    final startupUploadHasNoKnownWork =
        forceCapture &&
        !checkRemote &&
        direction == SyncDirection.uploadOnly &&
        _active?.trigger == 'Startup check' &&
        !_localDirty &&
        !hasPendingChanges;
    if (debugSyncOverride != null ||
        (direction == SyncDirection.uploadOnly &&
            debugUploadOverride != null &&
            !startupUploadHasNoKnownWork) ||
        (direction == SyncDirection.downloadOnly &&
            checkRemote &&
            debugDownloadOverride != null)) {
      return _syncDataNow(checkRemote: checkRemote, forceCapture: forceCapture);
    }
    await _ensureCoordinatorLoaded();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    final generation = _changeGeneration;
    final currentDirection = direction;
    if (remoteOnly) {
      _isDownloading = true;
      return _performCoordinatorSync(
        direction: SyncDirection.downloadOnly,
        checkRemote: true,
        forceCapture: false,
      );
    }

    final shouldCheckRemote =
        checkRemote && currentDirection != SyncDirection.uploadOnly;
    if (currentDirection == SyncDirection.downloadOnly) {
      if (!shouldCheckRemote) return const Res(true);
      _isDownloading = true;
      return _performCoordinatorSync(
        direction: currentDirection,
        checkRemote: true,
        forceCapture: forceCapture,
      );
    }

    var hasOutbox = coordinator.store.outbox.isNotEmpty;
    if (!forceCapture || !shouldCheckRemote) {
      hasOutbox = await coordinator.captureLocalChanges();
    }
    if (!hasOutbox &&
        !shouldCheckRemote &&
        (!forceCapture || currentDirection != SyncDirection.uploadOnly)) {
      await _clearLocalPendingIfUnchanged(generation);
      _flushRequested = false;
      return const Res(true);
    }
    if (hasOutbox &&
        currentDirection == SyncDirection.uploadOnly &&
        debugUploadOverride != null) {
      _isUploading = true;
      _flushRequested = false;
      return _uploadDataNow(forceCapture: false);
    }
    _flushRequested = false;
    if (hasOutbox || forceCapture) _isUploading = true;
    if (shouldCheckRemote) _isDownloading = true;
    return _performCoordinatorSync(
      direction: currentDirection,
      checkRemote: shouldCheckRemote,
      forceCapture: forceCapture,
    );
  }

  Future<void> _clearLocalPendingIfUnchanged(int generation) async {
    if (generation != _changeGeneration ||
        (_coordinator?.store.outbox.isNotEmpty ?? false)) {
      return;
    }
    _localDirty = false;
    _dirtySince = null;
    _lastLocalChange = null;
    _flushRequested = false;
    appdata.implicitData['webdavSyncPending'] = false;
    await _writeImplicitStatusAndWait();
  }

  Future<void> _writeImplicitStatusAndWait() async {
    try {
      await appdata.writeImplicitData();
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
    }
  }

  Future<void> _recordSyncAttempt({
    required String trigger,
    required bool checkRemote,
    required bool requestUpload,
  }) async {
    final now = _now.millisecondsSinceEpoch;
    appdata.implicitData['webdavSyncLastAttempt'] = now;
    appdata.implicitData['webdavSyncLastTrigger'] = trigger;
    if (requestUpload) {
      appdata.implicitData['webdavSyncLastUploadAttempt'] = now;
    }
    if (checkRemote) {
      appdata.implicitData['webdavSyncLastRemoteCheck'] = now;
    }
    await _writeImplicitStatusAndWait();
  }

  Future<Res<bool>> _performCoordinatorSync({
    required SyncDirection direction,
    required bool checkRemote,
    required bool forceCapture,
  }) async {
    final coordinator = _coordinator;
    if (coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    _activeRequestDidRemote = true;
    await _recordSyncAttempt(
      trigger: _active?.trigger ?? 'Manual sync',
      checkRemote: checkRemote && direction != SyncDirection.uploadOnly,
      requestUpload: direction != SyncDirection.downloadOnly,
    );
    return coordinator.performSync(
      direction: direction,
      checkRemote: checkRemote,
      forceCapture: forceCapture,
    );
  }

  Future<Res<bool>> _syncDataNow({
    required bool checkRemote,
    required bool forceCapture,
  }) async {
    if (debugSyncOverride != null) {
      _activeRequestDidRemote = true;
      await _recordSyncAttempt(
        trigger: _active?.trigger ?? 'Manual sync',
        checkRemote: checkRemote && direction != SyncDirection.uploadOnly,
        requestUpload: direction != SyncDirection.downloadOnly,
      );
      return await debugSyncOverride!();
    }
    if (direction == SyncDirection.uploadOnly && debugUploadOverride != null) {
      return _uploadDataNow(forceCapture: forceCapture);
    }
    if (direction == SyncDirection.downloadOnly &&
        debugDownloadOverride != null) {
      return _downloadDataNow(
        checkRemote: checkRemote,
        forceCapture: forceCapture,
      );
    }
    await _ensureCoordinatorLoaded();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    final shouldCheckRemote =
        checkRemote && direction != SyncDirection.uploadOnly;
    if (direction != SyncDirection.downloadOnly &&
        direction != SyncDirection.uploadOnly &&
        !shouldCheckRemote &&
        forceCapture) {
      final generation = _changeGeneration;
      if (!await coordinator.captureLocalChanges()) {
        await _clearLocalPendingIfUnchanged(generation);
        return const Res(true);
      }
    }
    return _performCoordinatorSync(
      direction: direction,
      checkRemote: shouldCheckRemote,
      forceCapture: forceCapture,
    );
  }

  Future<Res<bool>> _uploadDataNow({bool forceCapture = true}) async {
    if (debugUploadOverride != null) {
      _activeRequestDidRemote = true;
      await _recordSyncAttempt(
        trigger: _active?.trigger ?? 'Manual sync',
        checkRemote: false,
        requestUpload: true,
      );
      return await debugUploadOverride!();
    }
    await _ensureCoordinatorLoaded();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    if (forceCapture) await coordinator.captureLocalChanges();
    return _performCoordinatorSync(
      direction: SyncDirection.uploadOnly,
      checkRemote: false,
      forceCapture: forceCapture,
    );
  }

  Future<Res<bool>> _downloadDataNow({
    bool checkRemote = true,
    bool forceCapture = false,
  }) async {
    if (debugDownloadOverride != null) {
      _activeRequestDidRemote = true;
      await _recordSyncAttempt(
        trigger: _active?.trigger ?? 'Manual sync',
        checkRemote: true,
        requestUpload: false,
      );
      return await debugDownloadOverride!();
    }
    await _ensureCoordinatorLoaded();
    if (_coordinator == null) {
      return const Res.error('WebDAV is not configured');
    }
    return _performCoordinatorSync(
      direction: SyncDirection.downloadOnly,
      checkRemote: checkRemote,
      forceCapture: forceCapture,
    );
  }

  Future<Res<bool>> _enqueue(
    _DataSyncTask type,
    Future<Res<bool>> Function() run, {
    Object? key,
    String? trigger,
    bool checkRemote = false,
    bool forceCapture = false,
  }) {
    if (_disposed) {
      return Future.value(const Res.error('Sync service is disposed'));
    }
    if (key != null && _queue.isNotEmpty) {
      final queued = _queue.last;
      if (queued.key == key &&
          queued.trigger == trigger &&
          queued.checkRemote == checkRemote &&
          queued.forceCapture == forceCapture) {
        return queued.completer.future;
      }
    }
    final request = _SyncRequest(
      type,
      run,
      key,
      trigger: trigger,
      checkRemote: checkRemote,
      forceCapture: forceCapture,
    );
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _remoteCheckTimer?.cancel();
    _remoteCheckTimer = null;
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
    _activeRequestDidRemote = false;
    Res<bool> result;
    final automaticLocal =
        request.trigger == 'Local changes' && !request.forceCapture;
    if (!automaticLocal && request.type == _DataSyncTask.upload) {
      _isUploading = true;
    } else if (!automaticLocal && request.type == _DataSyncTask.download) {
      _isDownloading = true;
    } else if (!automaticLocal && request.type == _DataSyncTask.listBackups) {
      _isDownloading = true;
    } else if (!automaticLocal && request.type == _DataSyncTask.sync) {
      if (direction == SyncDirection.uploadOnly) {
        _isUploading = true;
      } else if (direction == SyncDirection.downloadOnly) {
        _isDownloading = true;
      } else {
        _isUploading = true;
        _isDownloading = true;
      }
    }

    var runGeneration = _changeGeneration;
    try {
      if (!_disposed) notifyListeners();
      if (request.type != _DataSyncTask.configure &&
          request.type != _DataSyncTask.repair &&
          !hasConfiguration) {
        result = const Res.error(
          'WebDAV is not configured. Please configure it first.',
        );
      } else {
        if (request.type != _DataSyncTask.configure &&
            request.type != _DataSyncTask.repair) {
          await _startupCompleter.future;
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
            } catch (error, stack) {
              Log.error(
                'DataSync',
                'Startup recovery retry failed: $error\n$stack',
              );
              _startupError = error;
              _startupReady = false;
              _lastError = error.toString();
              if (!_disposed) notifyListeners();
              throw StateError('Sync startup recovery failed: $_startupError');
            }
          }
          if (!isReady) {
            throw StateError('Sync startup recovery failed: $_startupError');
          }
        }
        runGeneration = _changeGeneration;
        result = await runZoned(
          request.run,
          zoneValues: {_importZoneKey: true},
        );
        if (result.success) {
          if (_activeRequestDidRemote) {
            appdata.implicitData['webdavSyncLastSuccess'] =
                _now.millisecondsSinceEpoch;
            appdata.implicitData
              ..remove('webdavSyncFailureCount')
              ..remove('webdavSyncRetryAfter')
              ..remove('webdavSyncAuthenticationBlocked');
            _automaticAuthenticationBlocked = false;
          }
          if (request.type != _DataSyncTask.listBackups &&
              _changeGeneration == runGeneration &&
              (_coordinator?.store.outbox.isEmpty ?? true)) {
            appdata.implicitData['webdavSyncPending'] = false;
            _localDirty = false;
            _dirtySince = null;
            _lastLocalChange = null;
            _flushRequested = false;
          }
        } else {
          _recordSyncFailure(result.errorMessage);
        }
        await _writeImplicitStatusAndWait();
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
          request.type != _DataSyncTask.repair &&
          hasConfiguration) {
        _recordSyncFailure(result.errorMessage);
        await _writeImplicitStatusAndWait();
      }
    } finally {
      _isUploading = false;
      _isDownloading = false;
    }

    _lastError = result.errorMessage;
    _active = null;
    final next = _queue.isEmpty ? null : _queue.removeAt(0);
    if (next != null) _active = next;
    request.completer.complete(result);
    if (!_disposed) notifyListeners();
    if (next != null) {
      unawaited(_runTask(next));
    } else if (!_disposed) {
      checkForAutomaticSync();
    }
  }

  void _recordSyncFailure(String? message) {
    final previous = appdata.implicitData['webdavSyncFailureCount'];
    final failures = (previous is int ? previous : 0) + 1;
    appdata.implicitData['webdavSyncFailureCount'] = failures;
    if (_isAuthenticationFailure(message)) {
      _automaticAuthenticationBlocked = true;
      appdata.implicitData['webdavSyncAuthenticationBlocked'] = true;
      appdata.implicitData.remove('webdavSyncRetryAfter');
      return;
    }
    final exponent = (failures - 1).clamp(0, 5).toInt();
    final retryMinutes = exponent == 5 ? 60 : 1 << exponent;
    appdata.implicitData['webdavSyncRetryAfter'] = _now
        .add(Duration(minutes: retryMinutes))
        .millisecondsSinceEpoch;
  }

  bool _isAuthenticationFailure(String? message) {
    final value = message?.toLowerCase() ?? '';
    return RegExp(r'\b(?:401|403)\b').hasMatch(value) ||
        value.contains('unauthorized') ||
        value.contains('forbidden') ||
        value.contains('authentication failed');
  }

  dav.Client _client(WebDavEndpoint endpoint) =>
      debugClientFactory?.call(endpoint) ??
      endpoint.createClient(logRequests: _syncDiagnosticsEnabled);
}
