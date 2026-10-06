import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:venera_plus/features/sync/app_data_transfer.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

enum _DataSyncTask { sync, upload, download, configure }

class _SyncRequest {
  _SyncRequest(this.type, this.run, this.key);
  final _DataSyncTask type;
  final Future<Res<bool>> Function() run;
  final Object? key;
  final completer = Completer<Res<bool>>();
}

enum SyncDirection { bidirectional, uploadOnly, downloadOnly }

enum SyncTiming { manual, realtime, scheduled }

enum SyncAction { upload, download, conflict, inSync }

String? _strongEtag(String? value) =>
    value == null || value.isEmpty || value.startsWith('W/') ? null : value;

class RemoteSnapshot {
  const RemoteSnapshot({
    required this.file,
    required this.name,
    required this.day,
    required this.version,
    required this.eTag,
  });

  final dav.File file;
  final String name;
  final int day;
  final int version;
  final String? eTag;

  static RemoteSnapshot? tryParse(dav.File file) {
    if (file.isDir == true) return null;
    final name = file.name;
    if (name == null || !name.endsWith('.venera')) return null;
    final base = name.substring(0, name.length - '.venera'.length);
    final parts = base.split('-');
    if (parts.length != 2) return null;
    final day = int.tryParse(parts[0]);
    final version = int.tryParse(parts[1]);
    if (day == null || version == null) return null;
    return RemoteSnapshot(
      file: file,
      name: name,
      day: day,
      version: version,
      eTag: file.eTag,
    );
  }
}

int compareRemoteSnapshots(RemoteSnapshot a, RemoteSnapshot b) {
  if (a.version != b.version) {
    return b.version.compareTo(a.version); // Numerically higher version first
  }
  return b.day.compareTo(a.day); // Numerically higher day first
}

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
    this.conflictRemoteFile,
    this.conflictRemoteVersion,
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
  final String? conflictRemoteFile;
  final int? conflictRemoteVersion;

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
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    HistoryManager().addListener(onDataChanged);
    ImageFavoriteManager().addListener(onDataChanged);
    checkForAutomaticSync(startup: true);
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

  void onDataChanged() {
    // A zone tags only import-originated notifications, not user edits that
    // arrive while the network or importer is awaiting I/O.
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
        !_configuring) {
      unawaited(syncNow());
    }
  }

  static final Object _importZoneKey = Object();

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

  bool get hasConfiguration => _validateConfig()?.isValid == true;

  bool get hasPendingChanges =>
      appdata.implicitData['webdavSyncPending'] == true;

  bool get isEnabled => timing != SyncTiming.manual && hasConfiguration;

  Timer? _scheduleTimer;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  DateTime? _lastRealtimeCheck;

  bool _hasConflict = false;
  String? _conflictRemoteFile;
  int? _conflictRemoteVersion;

  bool get hasConflict => _hasConflict;
  String? get conflictRemoteFile => _conflictRemoteFile;
  int? get conflictRemoteVersion => _conflictRemoteVersion;

  void _clearConflict() {
    if (_hasConflict ||
        _conflictRemoteFile != null ||
        _conflictRemoteVersion != null) {
      _hasConflict = false;
      _conflictRemoteFile = null;
      _conflictRemoteVersion = null;
      _lastError = null;
      if (!_disposed) notifyListeners();
    }
  }

  @visibleForTesting
  static DateTime Function()? debugNow;

  DateTime get _now => debugNow?.call() ?? DateTime.now();

  static String endpointTarget(WebDavEndpoint endpoint) {
    return '${endpoint.url}#${endpoint.user}';
  }

  @visibleForTesting
  void debugSetConflict({
    required String remoteFile,
    required int remoteVersion,
  }) {
    _hasConflict = true;
    _conflictRemoteFile = remoteFile;
    _conflictRemoteVersion = remoteVersion;
    notifyListeners();
  }

  @visibleForTesting
  static SyncAction evaluateSyncAction({
    required bool localHasPending,
    required int localVersion,
    required RemoteSnapshot? latestRemote,
    required String? baselineTarget,
    required String currentTarget,
    required String? baselineFile,
    required int? baselineVersion,
    required String? baselineEtag,
    required bool hasRemoteCollision,
  }) {
    if (hasRemoteCollision) {
      return SyncAction.conflict;
    }

    final isSameTarget =
        baselineTarget != null && baselineTarget == currentTarget;
    final effectiveBaselineFile = isSameTarget ? baselineFile : null;
    final effectiveBaselineVersion = isSameTarget ? baselineVersion : null;
    final effectiveBaselineEtag = isSameTarget ? baselineEtag : null;

    if (latestRemote == null) {
      return SyncAction.upload;
    }

    // A zero version is not proof of an empty local database.
    if (effectiveBaselineFile == null || effectiveBaselineVersion == null) {
      return SyncAction.conflict;
    }

    bool remoteChanged = false;
    if (latestRemote.name != effectiveBaselineFile) {
      remoteChanged = true;
    } else if (latestRemote.version != effectiveBaselineVersion) {
      remoteChanged = true;
    } else if (_strongEtag(latestRemote.eTag) == null ||
        _strongEtag(effectiveBaselineEtag) == null ||
        latestRemote.eTag != effectiveBaselineEtag) {
      remoteChanged = true;
    }

    final localChanged =
        localHasPending || localVersion > effectiveBaselineVersion;

    if (remoteChanged && localChanged) {
      return SyncAction.conflict;
    }
    if (remoteChanged && !localChanged) {
      return SyncAction.download;
    }
    if (!remoteChanged && localChanged) {
      return SyncAction.upload;
    }
    return SyncAction.inSync;
  }

  /// Called at startup and resume, independently of the home page being mounted.
  /// Timers only run in this process; overdue checks are caught up on next launch.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (_disposed || _configuring || !isEnabled || _active != null) return;
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

  /// Configuration and its confirmed initial transfer occupy the same queue
  /// as manual, automatic and headless work.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required SyncDirection direction,
    required SyncTiming timing,
    required int minutes,
    required bool initialUpload,
  }) {
    final draft = List<String>.of(config);
    final requestedGeneration = _changeGeneration;
    return _enqueue(_DataSyncTask.configure, () async {
      _configuring = true;
      final oldConfig = appdata.settings['webdav'];
      final oldFields = appdata.settings['disableSyncFields'];
      final oldConflict = (
        _hasConflict,
        _conflictRemoteFile,
        _conflictRemoteVersion,
      );
      const keys = [
        'webdavSyncDirection',
        'webdavSyncTiming',
        'webdavSyncIntervalMinutes',
        'webdavSyncLastAttempt',
        'webdavSyncPending',
        'webdavBaselineTarget',
        'webdavLastSyncedRemoteFile',
        'webdavLastSyncedRemoteVersion',
        'webdavLastSyncedRemoteEtag',
      ];
      final previous = {for (final key in keys) key: appdata.implicitData[key]};
      final generation = _changeGeneration;
      var committed = false;
      try {
        appdata.settings['webdav'] = draft;
        appdata.settings['disableSyncFields'] = excludedFields;
        final endpoint = _validateConfig();
        if (draft.isNotEmpty && endpoint?.isValid != true) {
          return const Res.error('Invalid WebDAV configuration');
        }
        final target = endpoint == null ? null : endpointTarget(endpoint);
        if (draft.isEmpty || previous['webdavBaselineTarget'] != target) {
          for (final key in keys.where(
            (key) =>
                key.startsWith('webdavLastSynced') ||
                key == 'webdavBaselineTarget',
          )) {
            appdata.implicitData.remove(key);
          }
        }
        // Draft direction is private until commit, but its transfer is real
        // queued work and uses the same generation/baseline accounting.
        if (draft.isNotEmpty && timing != SyncTiming.manual) {
          final upload =
              direction == SyncDirection.uploadOnly ||
              (direction == SyncDirection.bidirectional && initialUpload);
          final result = upload
              ? await _uploadDataNow()
              : await _downloadDataNow(
                  checkVersion: false,
                  expectedGeneration: requestedGeneration,
                );
          if (result.error) return result;
        }
        appdata.implicitData['webdavSyncDirection'] = direction.name;
        appdata.implicitData['webdavSyncTiming'] =
            (draft.isEmpty ? SyncTiming.manual : timing).name;
        appdata.implicitData['webdavSyncIntervalMinutes'] =
            intervalOptions.contains(minutes) ? minutes : 30;
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        if (draft.isEmpty ||
            (generation == _changeGeneration &&
                (_uploadApplied || _downloadApplied))) {
          appdata.implicitData['webdavSyncPending'] = false;
        }
        await appdata.saveData(false);
        await appdata.writeImplicitData();
        committed = true;
        if (draft.isEmpty ||
            previous['webdavBaselineTarget'] != target ||
            previous['webdavSyncDirection'] != direction.name ||
            _uploadApplied ||
            _downloadApplied) {
          _clearConflict();
        }
        return const Res(true);
      } finally {
        try {
          if (!committed) {
            appdata.settings['webdav'] = oldConfig;
            appdata.settings['disableSyncFields'] = oldFields;
            for (final key in keys) {
              final value = previous[key];
              if (value == null) {
                appdata.implicitData.remove(key);
              } else {
                appdata.implicitData[key] = value;
              }
            }
            if (_changeGeneration != generation && hasConfiguration) {
              appdata.implicitData['webdavSyncPending'] = true;
            }
            _hasConflict = oldConflict.$1;
            _conflictRemoteFile = oldConflict.$2;
            _conflictRemoteVersion = oldConflict.$3;
            await appdata.saveData(false);
            await appdata.writeImplicitData();
          }
        } finally {
          _configuring = false;
          _lastRealtimeCheck = _now;
          if (hasPendingChanges &&
              isEnabled &&
              DataSync.timing == SyncTiming.realtime &&
              DataSync.direction != SyncDirection.downloadOnly &&
              _changeGeneration != generation) {
            unawaited(syncNow());
          }
        }
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
      request.type == _DataSyncTask.configure ||
      (request.type == _DataSyncTask.sync &&
          direction != SyncDirection.downloadOnly);

  bool get _hasUploadWork =>
      (_active != null && _canUpload(_active!)) || _queue.any(_canUpload);

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
      await _active!.completer.future;
    }
  }

  Future<void> waitForDownload() async {
    while ((_active != null && _active!.type != _DataSyncTask.upload) ||
        _queue.any((request) => request.type != _DataSyncTask.upload)) {
      await _active!.completer.future;
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
  static dav.Client Function(WebDavEndpoint)? debugClientFactory;

  @visibleForTesting
  static Future<File> Function()? debugExport;

  @visibleForTesting
  static Future<void> Function(File, bool)? debugImport;

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
    debugDisableWindowCloseHandler = false;
    debugNow = null;
    debugClientFactory = null;
    debugExport = null;
    debugImport = null;
  }

  bool _isDownloading = false;
  bool _downloadApplied = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;
  bool _uploadApplied = false;

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
    appdata.registerSyncDataRequestHandler(null);
    LocalFavoritesManager().removeListener(onDataChanged);
    ComicSourceManager().removeListener(onDataChanged);
    HistoryManager().removeListener(onDataChanged);
    ImageFavoriteManager().removeListener(onDataChanged);
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
    lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
    lastError: _lastError,
    hasConflict: _hasConflict,
    conflictRemoteFile: _conflictRemoteFile,
    conflictRemoteVersion: _conflictRemoteVersion,
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

  Future<Res<bool>> syncNow() => _enqueue(_DataSyncTask.sync, () {
    switch (direction) {
      case SyncDirection.uploadOnly:
        return _uploadDataNow();
      case SyncDirection.downloadOnly:
        return _downloadDataNow(checkVersion: false);
      case SyncDirection.bidirectional:
        return _syncBidirectionalNow();
    }
  }, key: _DataSyncTask.sync);

  Future<Res<bool>> uploadData() => _enqueue(_DataSyncTask.upload, () {
    if (direction == SyncDirection.downloadOnly) {
      return Future.value(
        const Res.error('Action not allowed by current sync direction'),
      );
    }
    return _uploadDataNow();
  }, key: _DataSyncTask.upload);

  Future<Res<bool>> downloadData({bool checkVersion = true}) {
    final generation = _changeGeneration;
    return _enqueue(_DataSyncTask.download, () {
      if (direction == SyncDirection.uploadOnly) {
        return Future.value(
          const Res.error('Action not allowed by current sync direction'),
        );
      }
      return _downloadDataNow(
        checkVersion: direction == SyncDirection.downloadOnly
            ? false
            : checkVersion,
        expectedGeneration: generation,
      );
    }, key: (_DataSyncTask.download, checkVersion, generation));
  }

  Future<Res<bool>> resolveConflict({required bool keepLocal}) =>
      keepLocal ? uploadData() : downloadData(checkVersion: false);

  Future<Res<bool>> _enqueue(
    _DataSyncTask type,
    Future<Res<bool>> Function() run, {
    Object? key,
  }) {
    if (_disposed) {
      return Future.value(const Res.error('Sync service is disposed'));
    }
    // Only adjacent queued requests with identical semantics may share a result.
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
    _downloadApplied = false;
    _uploadApplied = false;
    _lastError = null;
    final generation = _changeGeneration;
    final wasPending = hasPendingChanges;
    Res<bool> result;
    if (request.type != _DataSyncTask.configure && hasConfiguration) {
      appdata.implicitData['webdavSyncLastAttempt'] =
          _now.millisecondsSinceEpoch;
    }
    try {
      if (!_disposed) notifyListeners();
      if (request.type != _DataSyncTask.configure && !hasConfiguration) {
        result = const Res.error(
          'WebDAV is not configured. Please configure it first.',
        );
      } else {
        result = await request.run();
        if (request.type != _DataSyncTask.configure) {
          if (result.success &&
              generation == _changeGeneration &&
              (_uploadApplied || _downloadApplied)) {
            appdata.implicitData['webdavSyncPending'] = false;
          }
          appdata.implicitData['webdavSyncLastAttempt'] =
              _now.millisecondsSinceEpoch;
          await appdata.writeImplicitData();
        }
      }
      if (result.success && (_uploadApplied || _downloadApplied)) {
        _clearConflict();
      }
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      result = Res.error(error.toString());
      // A failed network request still counts as a scheduled attempt.
      if (request.type != _DataSyncTask.configure) {
        if (wasPending) appdata.implicitData['webdavSyncPending'] = true;
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        try {
          await appdata.writeImplicitData();
        } catch (persistenceError, persistenceStack) {
          Log.error('Data Sync', persistenceError, persistenceStack);
          result = Res.error('$error; $persistenceError');
        }
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

  Future<List<RemoteSnapshot>> _snapshots(dav.Client client) async {
    final files = (await client.readDir(
      '/',
    )).map(RemoteSnapshot.tryParse).whereType<RemoteSnapshot>().toList();
    files.sort(compareRemoteSnapshots);
    return files;
  }

  bool _collision(List<RemoteSnapshot> files) =>
      files.length > 1 && files[0].version == files[1].version;

  bool _sameSnapshot(RemoteSnapshot? a, RemoteSnapshot? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.name == b.name &&
        a.version == b.version &&
        a.day == b.day &&
        _strongEtag(a.eTag) != null &&
        a.eTag == b.eTag;
  }

  Res<bool> _conflict(RemoteSnapshot? remote, String reason) {
    _hasConflict = true;
    _conflictRemoteFile = remote?.name;
    _conflictRemoteVersion = remote?.version;
    _lastError = reason;
    if (!_disposed) notifyListeners();
    return Res.error(reason);
  }

  Future<Res<bool>> _syncBidirectionalNow() async {
    final endpoint = _validateConfig()!;
    final client = _client(endpoint);
    final generation = _changeGeneration;
    final snapshots = await _snapshots(client);
    final latest = snapshots.firstOrNull;
    final action = evaluateSyncAction(
      localHasPending: hasPendingChanges || generation != _changeGeneration,
      localVersion: (appdata.settings['dataVersion'] as int?) ?? 0,
      latestRemote: latest,
      baselineTarget: appdata.implicitData['webdavBaselineTarget'] as String?,
      currentTarget: endpointTarget(endpoint),
      baselineFile:
          appdata.implicitData['webdavLastSyncedRemoteFile'] as String?,
      baselineVersion:
          appdata.implicitData['webdavLastSyncedRemoteVersion'] as int?,
      baselineEtag:
          appdata.implicitData['webdavLastSyncedRemoteEtag'] as String?,
      hasRemoteCollision: _collision(snapshots),
    );
    switch (action) {
      case SyncAction.conflict:
        return _conflict(
          latest,
          'Sync requires a choice: the baseline is unknown, data diverged, or remote versions collide.',
        );
      case SyncAction.download:
        return _downloadRemoteFile(client, endpoint, latest!, generation);
      case SyncAction.upload:
        return _uploadDataNow(expected: latest, protectRemote: true);
      case SyncAction.inSync:
        appdata.settings['lastSyncTime'] = _now.millisecondsSinceEpoch;
        await appdata.saveData(false);
        return const Res(true);
    }
  }

  Future<Res<bool>> _uploadDataNow({
    RemoteSnapshot? expected,
    bool protectRemote = false,
  }) async {
    _isUploading = true;
    if (!_disposed) notifyListeners();
    final override = debugUploadOverride;
    if (override != null) {
      final result = await override();
      _uploadApplied = result.success;
      return result;
    }
    final endpoint = _validateConfig()!;
    final client = _client(endpoint);
    final snapshots = await _snapshots(client);
    if (protectRemote &&
        (_collision(snapshots) ||
            !_sameSnapshot(expected, snapshots.firstOrNull))) {
      return _conflict(
        snapshots.firstOrNull,
        'Remote data changed during sync. Please retry.',
      );
    }
    final version =
        max(
          (appdata.settings['dataVersion'] as int?) ?? 0,
          snapshots.firstOrNull?.version ?? 0,
        ) +
        1;
    appdata.settings['dataVersion'] = version;
    await appdata.saveData(false);
    final data = await (debugExport?.call() ?? exportAppData());
    final filename =
        '${_now.millisecondsSinceEpoch ~/ 86400000}-$version.venera';
    try {
      // Authenticate before opening a single-use stream. No conditional headers
      // are attached to OPTIONS, PROPFIND, or any directory operations.
      await client.ping();
      final fresh = await _snapshots(client);
      if (protectRemote &&
          (_collision(fresh) || !_sameSnapshot(expected, fresh.firstOrNull))) {
        return _conflict(
          fresh.firstOrNull,
          'Remote data changed during sync. Please retry.',
        );
      }
      if (fresh.any((file) => file.version >= version)) {
        return _conflict(
          fresh.firstOrNull,
          'Remote version collision detected',
        );
      }
      final length = await data.length();
      final response = await client.c.req(
        client,
        'PUT',
        filename,
        data: data.openRead(),
        optionsHandler: (options) {
          options.headers = {
            'If-None-Match': '*',
            'content-length': length,
            'content-type': 'application/octet-stream',
          };
        },
      );
      if (response.statusCode == 412) {
        return _conflict(
          fresh.firstOrNull,
          'Remote version collision detected',
        );
      }
      if (![200, 201, 204].contains(response.statusCode)) {
        throw StateError('WebDAV upload failed: HTTP ${response.statusCode}');
      }
      final after = await _snapshots(client);
      final uploaded = after.where((file) => file.name == filename).firstOrNull;
      if (_collision(after) ||
          after.firstOrNull?.name != filename ||
          uploaded == null) {
        return _conflict(
          after.firstOrNull,
          'Remote data changed during sync. Please retry.',
        );
      }
      if (protectRemote &&
          !_sameSnapshot(
            expected,
            after.where((file) => file.name != filename).firstOrNull,
          )) {
        return _conflict(
          after.firstOrNull,
          'Remote data changed during sync. Please retry.',
        );
      }
      // Only inspect pre-upload candidates; conditional DELETE cannot remove
      // a file another client replaced since that listing.
      for (var i = 0; i < snapshots.length; i++) {
        final old = snapshots[i];
        final etag = _strongEtag(old.eTag);
        if (old.version >= version ||
            (i > 0 && snapshots[i - 1].version == old.version) ||
            (i + 1 < snapshots.length &&
                snapshots[i + 1].version == old.version) ||
            etag == null ||
            (old.day != uploaded.day && i < 9)) {
          continue;
        }
        try {
          final deleted = await client.c.req(
            client,
            'DELETE',
            old.name,
            optionsHandler: (options) => options.headers = {'If-Match': etag},
          );
          if (![200, 204, 404, 412].contains(deleted.statusCode)) {
            Log.warning(
              'Data Sync',
              'Snapshot cleanup failed: HTTP ${deleted.statusCode}',
            );
          }
        } catch (error) {
          Log.warning('Data Sync', 'Snapshot cleanup failed: $error');
        }
      }
      await _updateBaseline(endpoint, uploaded);
      appdata.settings['lastSyncTime'] = _now.millisecondsSinceEpoch;
      await appdata.saveData(false);
      _uploadApplied = true;
      return const Res(true);
    } finally {
      await data.deleteIgnoreError();
    }
  }

  Future<Res<bool>> _downloadDataNow({
    bool checkVersion = true,
    int? expectedGeneration,
  }) async {
    _isDownloading = true;
    if (!_disposed) notifyListeners();
    final generation = expectedGeneration ?? _changeGeneration;
    if (generation != _changeGeneration) {
      return _conflict(
        null,
        'Local data changed during download. Please retry.',
      );
    }
    final override = debugDownloadOverride;
    if (override != null) {
      final result = await override();
      if (generation != _changeGeneration) {
        return _conflict(
          null,
          'Local data changed during download. Please retry.',
        );
      }
      _downloadApplied = result.success;
      return result;
    }
    final endpoint = _validateConfig()!;
    final client = _client(endpoint);
    final snapshots = await _snapshots(client);
    final latest = snapshots.firstOrNull;
    if (_collision(snapshots)) {
      return _conflict(latest, 'Remote version collision detected');
    }
    if (latest == null) return const Res.error('No data file found');
    if (checkVersion &&
        latest.version <= ((appdata.settings['dataVersion'] as int?) ?? 0)) {
      return const Res(true);
    }
    return _downloadRemoteFile(
      client,
      endpoint,
      latest,
      generation,
      allowUnverified: true,
    );
  }

  Future<Res<bool>> _downloadRemoteFile(
    dav.Client client,
    WebDavEndpoint endpoint,
    RemoteSnapshot snapshot,
    int generation, {
    bool allowUnverified = false,
  }) async {
    _isDownloading = true;
    if (!_disposed) notifyListeners();
    // A strong validator binds the downloaded bytes to the inspected snapshot.
    final etag = _strongEtag(snapshot.eTag);
    if (etag == null && !allowUnverified) {
      return _conflict(
        snapshot,
        'Automatic download needs a strong ETag. Choose Download Remote explicitly to use this server.',
      );
    }
    final localFile = File(FilePath.join(App.cachePath, snapshot.name));
    try {
      final response = await client.c.req<ResponseBody>(
        client,
        'GET',
        snapshot.name,
        optionsHandler: (options) {
          options.responseType = ResponseType.stream;
          if (etag != null) options.headers = {'If-Match': etag};
        },
      );
      if (response.statusCode != 200 ||
          (etag != null && response.headers.value('etag') != etag) ||
          response.data == null) {
        await response.data?.stream.drain<void>();
        return _conflict(
          snapshot,
          'Remote data changed during sync. Please retry.',
        );
      }
      final sink = localFile.openWrite();
      try {
        await sink.addStream(response.data!.stream);
      } finally {
        await sink.close();
      }
      final fresh = await _snapshots(client);
      final sameRemote = etag == null
          ? fresh.firstOrNull?.name == snapshot.name
          : _sameSnapshot(snapshot, fresh.firstOrNull);
      if (_collision(fresh) || !sameRemote) {
        return _conflict(
          fresh.firstOrNull,
          'Remote data changed during sync. Please retry.',
        );
      }
      if (generation != _changeGeneration) {
        return _conflict(
          snapshot,
          'Local data changed during download. Please retry.',
        );
      }
      await runZoned(() async {
        void beforeCommit() {
          if (generation != _changeGeneration) {
            const reason = 'Local data changed during download. Please retry.';
            _conflict(snapshot, reason);
            throw StateError(reason);
          }
        }

        final importer = debugImport;
        if (importer != null) {
          beforeCommit();
          await importer(localFile, false);
        } else {
          await importAppData(localFile, beforeCommit: beforeCommit);
        }
        HistoryManager().notifyChanges();
        LocalFavoritesManager().notifyChanges();
        ImageFavoriteManager().notifyChanges();
      }, zoneValues: {_importZoneKey: true});
      await _updateBaseline(
        endpoint,
        RemoteSnapshot(
          file: snapshot.file,
          name: snapshot.name,
          day: snapshot.day,
          version: snapshot.version,
          eTag: etag,
        ),
      );
      appdata.settings['lastSyncTime'] = _now.millisecondsSinceEpoch;
      await appdata.saveData(false);
      _downloadApplied = true;
      return const Res(true);
    } finally {
      await localFile.deleteIgnoreError();
    }
  }

  Future<void> _updateBaseline(
    WebDavEndpoint endpoint,
    RemoteSnapshot snapshot,
  ) async {
    appdata.implicitData['webdavBaselineTarget'] = endpointTarget(endpoint);
    appdata.implicitData['webdavLastSyncedRemoteFile'] = snapshot.name;
    appdata.implicitData['webdavLastSyncedRemoteVersion'] = snapshot.version;
    final etag = _strongEtag(snapshot.eTag);
    if (etag == null) {
      appdata.implicitData.remove('webdavLastSyncedRemoteEtag');
    } else {
      appdata.implicitData['webdavLastSyncedRemoteEtag'] = etag;
    }
    await appdata.writeImplicitData();
  }
}
