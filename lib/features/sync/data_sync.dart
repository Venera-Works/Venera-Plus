import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/sync/app_data_transfer.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_exit.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/file_system.dart';

enum _DataSyncTask { upload, download }

enum DataSyncMode { manual, realtime, scheduled }

class DataSyncStatusSnapshot {
  const DataSyncStatusSnapshot({
    this.isConfigured = false,
    required this.isEnabled,
    required this.isUploading,
    required this.isDownloading,
    required this.lastSyncTime,
    required this.lastError,
  });

  final bool isEnabled;
  final bool isConfigured;
  final bool isUploading;
  final bool isDownloading;
  final int lastSyncTime;
  final String? lastError;

  bool get isSyncing => isUploading || isDownloading;

  bool get shouldShow => isConfigured || isEnabled || isSyncing;

  String get title => isSyncing ? 'Syncing Data' : 'Sync Data';

  String get formattedLastSyncTime => _formatTime(lastSyncTime);

  static String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class DataSync with ChangeNotifier {
  static const _remoteDirectory = '/VeneraPlus/';
  static const _remoteLocationSetting = 'syncRemoteLocation';
  static const _realtimeDelay = Duration(seconds: 3);
  static const _realtimeMaxWait = Duration(seconds: 30);
  static const _cleanupInterval = Duration(minutes: 15);
  static const _cleanupSnapshotLimit = 20;

  DataSync._() {
    appdata.registerSyncDataRequestHandler(({domains}) => onDataChanged());
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    checkForAutomaticSync(startup: true);
    if (App.isDesktop && !debugDisableWindowCloseHandler) {
      Future.delayed(const Duration(seconds: 1), () {
        if (_disposed) return;
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    // Import notifications describe the downloaded snapshot, not local edits.
    if (_disposed ||
        _isDownloading ||
        isAppDataImporting ||
        !hasConfiguration) {
      return;
    }
    _changeGeneration++;
    if (!hasPendingChanges) {
      appdata.implicitData['webdavSyncPending'] = true;
      appdata.writeImplicitData();
    }
    if (isEnabled && mode == DataSyncMode.realtime && !_configuring) {
      _scheduleRealtimeUpload();
    }
  }

  void _scheduleRealtimeUpload() {
    if (_disposed ||
        _configuring ||
        !isEnabled ||
        mode != DataSyncMode.realtime) {
      return;
    }
    _firstRealtimeChange ??= _now;
    if (_activeTask != null) return;
    final elapsed = _now.difference(_firstRealtimeChange!);
    final remaining =
        _realtimeMaxWait - (elapsed.isNegative ? Duration.zero : elapsed);
    final delay = remaining < _realtimeDelay ? remaining : _realtimeDelay;
    _realtimeTimer?.cancel();
    _realtimeTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _realtimeTimer = null;
      unawaited(uploadData());
    });
  }

  void _cancelRealtimeUpload() {
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _firstRealtimeChange = null;
  }

  static DataSyncMode get mode {
    final stored = appdata.implicitData['webdavSyncMode'];
    return DataSyncMode.values.firstWhereOrNull(
          (value) => value.name == stored,
        ) ??
        (appdata.implicitData['webdavAutoSync'] == true
            ? DataSyncMode.realtime
            : DataSyncMode.manual);
  }

  static const intervalOptions = [5, 15, 30, 60, 180, 360];

  static int get intervalMinutes {
    final value = appdata.implicitData['webdavSyncIntervalMinutes'];
    return value is int && intervalOptions.contains(value) ? value : 30;
  }

  bool get hasConfiguration {
    final location = _remoteLocation;
    return location != null
        ? RemoteStorageAccounts.instance.account(location.accountId) != null
        : _validateConfig()?.isValid == true;
  }

  RemoteLocation? get _remoteLocation {
    final raw = appdata.settings[_remoteLocationSetting];
    if (raw is! Map) return null;
    final location = RemoteLocation.fromJson(raw);
    return location.accountId.isEmpty ? null : location;
  }

  bool get hasPendingChanges =>
      appdata.implicitData['webdavSyncPending'] == true;

  Timer? _scheduleTimer;
  Timer? _realtimeTimer;
  DateTime? _firstRealtimeChange;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  int _taskEpoch = 0;
  DateTime? _lastRealtimeCheck;

  @visibleForTesting
  static DateTime Function()? debugNow;

  DateTime get _now => debugNow?.call() ?? DateTime.now();

  /// Called at startup and resume, independently of the home page being mounted.
  /// Timers only run in this process; overdue checks are caught up on next launch.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (_disposed || _configuring || !isEnabled || _activeTask != null) return;
    if (mode == DataSyncMode.realtime) {
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
      // A clock moved backwards must not delay syncing indefinitely.
      final elapsed = last == null ? interval : _now.difference(last);
      final remaining = interval - (elapsed.isNegative ? interval : elapsed);
      if (remaining > Duration.zero) {
        _scheduleTimer = Timer(remaining, checkForAutomaticSync);
        return;
      }
    }
    // Do not download over local edits waiting for their next scheduled upload.
    unawaited(hasPendingChanges ? uploadData() : downloadData(force: false));
  }

  /// Save a draft only after its initial transfer succeeds. Automatic work is
  /// suspended while validating it, and existing transfers finish first.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required DataSyncMode syncMode,
    required int minutes,
    required bool initialUpload,
    RemoteLocation? remoteLocation,
  }) async {
    if (_configuring) return const Res.error('Sync configuration is busy');
    _configuring = true;
    _scheduleTimer?.cancel();
    _cancelRealtimeUpload();
    _taskEpoch++;
    final oldLocation = _remoteLocation;
    if (remoteLocation?.normalized().toJson().toString() !=
        oldLocation?.toJson().toString()) {
      await _activeStore?.cancelAll();
    }
    while (_activeTask != null || _pendingTask != null) {
      await (_pendingTask ?? _activeTask!);
    }
    final oldConfig = appdata.settings['webdav'];
    final oldLocationValue = appdata.settings[_remoteLocationSetting];
    final oldFields = appdata.settings['disableSyncFields'];
    const keys = [
      'webdavSyncMode',
      'webdavAutoSync',
      'webdavSyncIntervalMinutes',
      'webdavSyncLastAttempt',
      'webdavSyncPending',
      'webdavLastBackup',
    ];
    final previous = {for (final key in keys) key: appdata.implicitData[key]};
    final previousGeneration = _changeGeneration;
    var committed = false;
    Res<bool>? failureResult;
    try {
      appdata.settings['webdav'] = config;
      if (remoteLocation == null) {
        appdata.settings.remove(_remoteLocationSetting);
      } else {
        appdata.settings[_remoteLocationSetting] = remoteLocation
            .normalized()
            .toJson();
      }
      appdata.settings['disableSyncFields'] = excludedFields;
      if ((config.isNotEmpty || remoteLocation != null) && !hasConfiguration) {
        failureResult = const Res.error('Invalid storage configuration');
        return failureResult;
      }
      if ((config.isNotEmpty || remoteLocation != null) &&
          syncMode != DataSyncMode.manual) {
        final result = initialUpload
            ? await uploadData()
            : await downloadData();
        if (result.error) {
          failureResult = result;
          return result;
        }
      }
      final selected = config.isEmpty && remoteLocation == null
          ? DataSyncMode.manual
          : syncMode;
      appdata.implicitData['webdavSyncMode'] = selected.name;
      appdata.implicitData['webdavAutoSync'] = selected != DataSyncMode.manual;
      appdata.implicitData['webdavSyncIntervalMinutes'] =
          intervalOptions.contains(minutes) ? minutes : 30;
      appdata.implicitData['webdavSyncLastAttempt'] =
          _now.millisecondsSinceEpoch;
      if (config.isEmpty && remoteLocation == null) {
        appdata.implicitData['webdavSyncPending'] = false;
      }
      appdata.writeImplicitData();
      await appdata.saveData(false);
      committed = true;
      return const Res(true);
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      failureResult = Res.error(error.toString());
      return failureResult;
    } finally {
      try {
        if (!committed) {
          appdata.settings['webdav'] = oldConfig;
          if (oldLocationValue == null) {
            appdata.settings.remove(_remoteLocationSetting);
          } else {
            appdata.settings[_remoteLocationSetting] = oldLocationValue;
          }
          appdata.settings['disableSyncFields'] = oldFields;
          for (final key in keys) {
            if (previous[key] == null) {
              appdata.implicitData.remove(key);
            } else {
              appdata.implicitData[key] = previous[key];
            }
          }
          if (_changeGeneration != previousGeneration && hasConfiguration) {
            appdata.implicitData['webdavSyncPending'] = true;
          }
          appdata.writeImplicitData();
          try {
            await appdata.saveData(false);
          } catch (e, s) {
            Log.error('Data Sync', 'Failed to save rolled back appdata: $e', s);
          }
        }
      } finally {
        _configuring = false;
        _lastRealtimeCheck = _now;
        if (mode == DataSyncMode.scheduled) {
          checkForAutomaticSync();
        } else if (mode == DataSyncMode.realtime &&
            hasPendingChanges &&
            isEnabled) {
          _scheduleRealtimeUpload();
        }
        if (!_disposed) notifyListeners();
      }
    }
  }

  bool _windowCloseDialogOpen = false;

  bool _handleWindowClose() {
    if (_isUploading || _windowCloseDialogOpen || _realtimeTimer != null) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    if (_windowCloseDialogOpen) return;
    _windowCloseDialogOpen = true;
    final shutDown = Completer<void>();
    final dialog = showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () {
        if (!shutDown.isCompleted) shutDown.complete();
      },
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    try {
      await Future.any([_waitForUploadBeforeClose(), shutDown.future]);
      await exitApp();
    } catch (error, stackTrace) {
      Log.error(
        'Window close',
        'Failed to save reading data before exit: $error',
        stackTrace,
      );
      showToast(context: App.rootContext, message: 'Saved Failed'.tl);
    } finally {
      dialog.close();
      _windowCloseDialogOpen = false;
    }
  }

  Future<void> _waitForUploadBeforeClose() async {
    do {
      if (isEnabled &&
          mode == DataSyncMode.realtime &&
          hasPendingChanges &&
          !_isDownloading) {
        await uploadData();
      }
      await _waitForTask(_DataSyncTask.upload);
    } while (isEnabled &&
        mode == DataSyncMode.realtime &&
        hasPendingChanges &&
        !_isDownloading &&
        _lastError == null);
  }

  Future<void> waitForDownload() async {
    return _waitForTask(_DataSyncTask.download);
  }

  Future<void> _waitForTask(_DataSyncTask task) async {
    while (true) {
      Future<Res<bool>>? taskFuture;
      if (_pendingTaskType == task) {
        taskFuture = _pendingTask;
      } else if (_activeTaskType == task) {
        taskFuture = _activeTask;
      }
      if (taskFuture == null) {
        return;
      }
      await taskFuture;
    }
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  @visibleForTesting
  static Future<Res<bool>> Function()? debugUploadOverride;

  @visibleForTesting
  static Future<Res<bool>> Function()? debugDownloadOverride;

  @visibleForTesting
  static dav.Client Function(WebDavEndpoint endpoint)? debugClientFactory;

  /// Lets transfer tests provide a small snapshot without bypassing the
  /// upload, retention, or target-selection code.
  @visibleForTesting
  static Future<File> Function()? debugSnapshotProducer;

  @visibleForTesting
  static bool debugDisableWindowCloseHandler = false;

  @visibleForTesting
  bool debugHandleWindowClose() => _handleWindowClose();

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
    debugClientFactory = null;
    debugSnapshotProducer = null;
    debugDisableWindowCloseHandler = false;
    debugNow = null;
  }

  bool _isDownloading = false;
  bool _downloadApplied = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool get isSyncing => _isUploading || _isDownloading;

  Future<Res<bool>>? _activeTask;

  Future<Res<bool>>? _pendingTask;

  _DataSyncTask? _activeTaskType;
  int? _activeGeneration;

  _DataSyncTask? _pendingTaskType;

  String? _lastError;

  RemoteFileStore? _activeStore;

  String? get lastError => _lastError;

  @override
  void dispose() {
    _disposed = true;
    _scheduleTimer?.cancel();
    _cancelRealtimeUpload();
    appdata.registerSyncDataRequestHandler(null);
    LocalFavoritesManager().removeListener(onDataChanged);
    ComicSourceManager().removeListener(onDataChanged);
    unawaited(_activeStore?.cancelAll() ?? Future.value());
    super.dispose();
  }

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isConfigured: hasConfiguration,
    isEnabled: isEnabled,
    isUploading: _isUploading,
    isDownloading: _isDownloading,
    lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
    lastError: _lastError,
  );

  bool get isEnabled => mode != DataSyncMode.manual && hasConfiguration;

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

  Future<Res<bool>> uploadData() async {
    _cancelRealtimeUpload();
    if (_activeTaskType == _DataSyncTask.download) {
      return const Res(true);
    }
    if (_activeTask != null) {
      if (_activeTaskType == _DataSyncTask.upload &&
          _activeGeneration == _changeGeneration) {
        return _activeTask!;
      }
      return _schedulePendingTask(_DataSyncTask.upload, _uploadDataNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadDataNow);
  }

  /// Explicit downloads restore the latest remote snapshot, including an older
  /// or already restored backup. Automatic checks pass [force] as false.
  Future<Res<bool>> downloadData({bool force = true}) async {
    _cancelRealtimeUpload();
    Future<Res<bool>> run() => _downloadDataNow(force: force);
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.download, run);
    }
    return _startTask(_DataSyncTask.download, run);
  }

  Future<Res<bool>> _schedulePendingTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    if (_pendingTask != null) {
      return Future.value(const Res(true));
    }
    var activeTask = _activeTask!;
    final epoch = _taskEpoch;
    _pendingTaskType = task;
    var pendingTask = activeTask.then(
      (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        if (epoch != _taskEpoch) {
          return Future<Res<bool>>.value(const Res(true));
        }
        return _startTask(task, run);
      },
      onError: (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        if (epoch != _taskEpoch) {
          return Future<Res<bool>>.value(const Res(true));
        }
        return _startTask(task, run);
      },
    );
    _pendingTask = pendingTask;
    return pendingTask;
  }

  Future<Res<bool>> _startTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    late Future<Res<bool>> activeTask;
    activeTask = _runTask(task, run).whenComplete(() {
      if (identical(_activeTask, activeTask)) {
        _activeTask = null;
        if (_lastError != null) _cancelRealtimeUpload();
        if (mode == DataSyncMode.scheduled && _pendingTask == null) {
          checkForAutomaticSync();
        } else if (_pendingTask == null &&
            hasPendingChanges &&
            _lastError == null) {
          _scheduleRealtimeUpload();
        }
      }
    });
    _activeTask = activeTask;
    return activeTask;
  }

  Future<Res<bool>> _runTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) async {
    _activeTaskType = task;
    _isUploading = task == _DataSyncTask.upload;
    _isDownloading = task == _DataSyncTask.download;
    _downloadApplied = false;
    _lastError = null;
    final generation = _changeGeneration;
    _activeGeneration = generation;
    final stopwatch = Stopwatch()..start();
    if (hasConfiguration && !_configuring) {
      appdata.implicitData['webdavSyncLastAttempt'] =
          _now.millisecondsSinceEpoch;
      appdata.writeImplicitData();
    }
    notifyListeners();
    try {
      final result = await run();
      if (result.error) {
        _lastError = result.errorMessage;
      } else if (hasConfiguration &&
          generation == _changeGeneration &&
          (task == _DataSyncTask.upload || _downloadApplied)) {
        appdata.implicitData['webdavSyncPending'] = false;
      }
      return result;
    } catch (e, s) {
      Log.error(_taskLogTag(task), e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      _activeTaskType = null;
      _activeGeneration = null;
      _isUploading = false;
      _isDownloading = false;
      if (hasConfiguration && !_configuring && !_disposed) {
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        appdata.writeImplicitData();
      }
      if (!_disposed) notifyListeners();
      Log.info(
        _taskLogTag(task),
        '同步结束，耗时 ${stopwatch.elapsedMilliseconds} ms',
      );
    }
  }

  String _taskLogTag(_DataSyncTask task) {
    return task == _DataSyncTask.upload ? 'Upload Data' : 'Data Sync';
  }

  Future<File> _exportSnapshot() {
    return debugSnapshotProducer?.call() ?? exportAppData();
  }

  bool _isTaskCurrent(int epoch) => !_disposed && epoch == _taskEpoch;

  Future<Res<bool>> _uploadDataNow() => _transferSnapshot(_DataSyncTask.upload);

  Future<Res<bool>> _downloadDataNow({required bool force}) =>
      _transferSnapshot(_DataSyncTask.download, force: force);

  Future<Res<bool>> _transferSnapshot(
    _DataSyncTask task, {
    bool force = true,
  }) async {
    final debugTransfer = task == _DataSyncTask.upload
        ? debugUploadOverride
        : debugDownloadOverride;
    if (debugTransfer != null) return debugTransfer();
    final epoch = _taskEpoch;
    RemoteFileStore? store;
    try {
      final location = _remoteLocation;
      late String directory;
      late String target;
      if (location != null) {
        store = RemoteStorageAccounts.instance.storeFor(
          location.accountId,
          optimizeWebDavTransfers: true,
        );
        directory = location.directory;
        target = _storeTarget(location);
      } else {
        final config = _validateConfig();
        if (config == null) {
          return const Res.error('Invalid WebDAV configuration');
        }
        if (!config.isValid) return const Res(true);
        store = WebDavFileStore(
          StorageAccount(
            id: 'legacy-sync',
            backend: StorageBackend.webdav,
            driver: 'webdav',
            name: 'WebDAV',
            authorization: {
              'url': config.url,
              'user': config.user,
              'password': config.password,
            },
          ),
          client: debugClientFactory?.call(config),
          optimizeTransfers: true,
        );
        directory = _remoteDirectory;
        target = _webDavTarget(config);
      }
      _activeStore = store;
      return task == _DataSyncTask.upload
          ? await _uploadToStore(store, directory, target, epoch)
          : await _downloadFromStore(
              store,
              directory,
              target,
              epoch,
              force: force,
            );
    } catch (error, stack) {
      Log.error(_taskLogTag(task), error, stack);
      return Res.error(error.toString());
    } finally {
      if (identical(_activeStore, store)) _activeStore = null;
      if (store is WebDavFileStore) store.close();
      if (store != null) RemoteStorageAccounts.instance.release(store);
    }
  }

  Future<Res<bool>> _uploadToStore(
    RemoteFileStore store,
    String directory,
    String target,
    int epoch,
  ) async {
    File? data;
    final previousVersion = appdata.settings['dataVersion'] as int;
    int? uploadingVersion;
    var uploaded = false;
    final stopwatch = Stopwatch()..start();
    try {
      late List<RemoteEntry> files;
      try {
        files = await store.list(directory, refresh: true);
      } on RemoteStorageException catch (error) {
        if (error.code != 'not_found') rethrow;
        await store.mkdir(directory);
        files = await store.list(directory, refresh: true);
      }
      Log.info('Upload Data', '读取目录耗时 ${stopwatch.elapsedMilliseconds} ms');
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final names = files
          .where((file) => !file.isDirectory)
          .map((file) => file.name)
          .toList();
      uploadingVersion = _nextSnapshotVersion(previousVersion, names);
      appdata.settings['dataVersion'] = uploadingVersion;
      await appdata.saveData(false);
      stopwatch.reset();
      data = await _exportSnapshot();
      final length = await data.length();
      Log.info(
        'Upload Data',
        '生成快照耗时 ${stopwatch.elapsedMilliseconds} ms，大小 $length 字节',
      );
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final filename = _snapshotName(uploadingVersion);
      final path = '${normalizeRemoteDirectory(directory)}$filename';
      stopwatch.reset();
      await store.upload(data.path, path);
      uploaded = true;
      Log.info('Upload Data', '上传快照耗时 ${stopwatch.elapsedMilliseconds} ms');
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await _rememberSnapshot(target, filename, _snapshotIdentity(filename));
      appdata.settings['lastSyncTime'] = _now.millisecondsSinceEpoch;
      await appdata.saveData(false);
      await _cleanupSnapshots(store, directory, target, names, filename, epoch);
      return const Res(true);
    } finally {
      if (!uploaded &&
          uploadingVersion != null &&
          appdata.settings['dataVersion'] == uploadingVersion) {
        appdata.settings['dataVersion'] = previousVersion;
        await appdata.saveData(false);
      }
      if (data != null) await data.deleteIgnoreError();
    }
  }

  Future<void> _cleanupSnapshots(
    RemoteFileStore store,
    String directory,
    String target,
    List<String> names,
    String uploaded,
    int epoch,
  ) async {
    final previous = appdata.implicitData['webdavLastCleanup'];
    final lastTime = previous is Map && previous['target'] == target
        ? previous['time']
        : null;
    final elapsed = lastTime is int
        ? _now.difference(DateTime.fromMillisecondsSinceEpoch(lastTime))
        : null;
    final count =
        names.where((name) => _snapshotVersion(name) != null).length + 1;
    if (elapsed != null &&
        !elapsed.isNegative &&
        elapsed < _cleanupInterval &&
        count < _cleanupSnapshotLimit) {
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      // 只清理本次上传前已看到的旧快照，不再次列目录或触碰并发新快照。
      final obsolete = _snapshotsToPrune(names, uploaded);
      for (final name in obsolete) {
        if (!_isTaskCurrent(epoch)) return;
        await store.delete('${normalizeRemoteDirectory(directory)}$name');
      }
      if (!_isTaskCurrent(epoch)) return;
      appdata.implicitData['webdavLastCleanup'] = {
        'target': target,
        'time': _now.millisecondsSinceEpoch,
      };
      await appdata.writeImplicitData();
      Log.info(
        'Upload Data',
        '清理 ${obsolete.length} 份旧快照，耗时 ${stopwatch.elapsedMilliseconds} ms',
      );
    } catch (error, stack) {
      Log.error('Upload Data', '清理旧快照失败：$error', stack);
    }
  }

  Future<Res<bool>> _downloadFromStore(
    RemoteFileStore store,
    String directory,
    String target,
    int epoch, {
    required bool force,
  }) async {
    File? localFile;
    try {
      final files = await store.list(directory, refresh: true);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final snapshots =
          files
              .where(
                (item) =>
                    !item.isDirectory && _snapshotVersion(item.name) != null,
              )
              .toList()
            ..sort((a, b) => _compareSnapshotNames(b.name, a.name));
      final file = snapshots.firstOrNull;
      if (file == null) return const Res.error('No data file found');
      final identity = _snapshotIdentity(
        file.name,
        eTag: file.eTag,
        modifiedAt: file.modifiedAt,
        size: file.size,
      );
      if (!force &&
          _shouldSkipSnapshot(
            target,
            file.name,
            identity,
            hasMetadata:
                file.eTag?.isNotEmpty == true || file.modifiedAt != null,
          )) {
        return const Res(true);
      }
      localFile = File(FilePath.join(App.cachePath, file.name));
      await store.download(file.path, localFile.path);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await importAppData(
        localFile,
        checkVersion: true,
        allowSameOrOlderVersion: true,
      );
      _downloadApplied = true;
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await _rememberSnapshot(target, file.name, identity);
      HistoryManager().notifyChanges();
      LocalFavoritesManager().notifyChanges();
      ImageFavoriteManager().notifyChanges();
      appdata.settings['lastSyncTime'] = _now.millisecondsSinceEpoch;
      await appdata.saveData(false);
      return const Res(true);
    } finally {
      if (localFile != null) await localFile.deleteIgnoreError();
    }
  }

  static (int, int)? _snapshotVersion(String name) {
    final match = RegExp(r'^(\d+)-(\d+)(?:-(.+))?\.venera$').firstMatch(name);
    if (match == null) return null;
    final day = int.tryParse(match.group(1)!);
    final version = int.tryParse(match.group(2)!);
    return day == null || version == null ? null : (day, version);
  }

  static int _compareSnapshotNames(String left, String right) {
    final a = _snapshotVersion(left)!;
    final b = _snapshotVersion(right)!;
    final version = a.$2.compareTo(b.$2);
    if (version != 0) return version;
    final day = a.$1.compareTo(b.$1);
    return day != 0 ? day : left.compareTo(right);
  }

  String _snapshotName(int version) {
    final now = _now;
    final day = now.millisecondsSinceEpoch ~/ 86400000;
    final time = now.microsecondsSinceEpoch.toString().padLeft(20, '0');
    final id = const Uuid().v4().replaceAll('-', '');
    return '$day-$version-$time-$id.venera';
  }

  static int _nextSnapshotVersion(int current, Iterable<String> names) {
    for (final name in names) {
      final version = _snapshotVersion(name)?.$2;
      if (version != null && version > current) current = version;
    }
    return current + 1;
  }

  static List<String> _snapshotsToPrune(
    Iterable<String> names,
    String uploaded,
  ) {
    final current = _snapshotVersion(uploaded)!;
    final snapshots =
        names.where((name) => _snapshotVersion(name) != null).toSet()
          ..add(uploaded);
    final obsolete = snapshots.where((name) {
      final version = _snapshotVersion(name)!;
      return version.$1 == current.$1 && version.$2 < current.$2;
    }).toList();
    final remaining =
        snapshots.where((name) => !obsolete.contains(name)).toList()
          ..sort(_compareSnapshotNames);
    // Concurrent writers can share a counter. Keep all such snapshots, even
    // when that temporarily exceeds the normal ten-backup retention limit.
    final older = remaining.where(
      (name) => _snapshotVersion(name)!.$2 < current.$2,
    );
    final excess = remaining.length - 10;
    if (excess > 0) obsolete.addAll(older.take(excess));
    return obsolete;
  }

  static bool _hasUniqueSnapshotName(String name) =>
      RegExp(r'^\d+-\d+-\d{20}-[0-9a-f]{32}\.venera$').hasMatch(name);

  static String _snapshotIdentity(
    String name, {
    String? eTag,
    int? modifiedAt,
    int? size,
  }) => jsonEncode([
    name,
    if (!_hasUniqueSnapshotName(name)) ...[eTag, modifiedAt, size],
  ]);

  static String _webDavTarget(WebDavEndpoint endpoint) => sha256
      .convert(
        utf8.encode(
          jsonEncode(['webdav', endpoint.url, endpoint.user, _remoteDirectory]),
        ),
      )
      .toString();

  static String _storeTarget(RemoteLocation location) => sha256
      .convert(
        utf8.encode(jsonEncode(['store', location.normalized().toJson()])),
      )
      .toString();

  bool _shouldSkipSnapshot(
    String target,
    String name,
    String identity, {
    required bool hasMetadata,
  }) {
    final version = _snapshotVersion(name)!.$2;
    final current = appdata.settings['dataVersion'] as int;
    if (version < current) return true;
    final previous = appdata.implicitData['webdavLastBackup'];
    return previous is Map &&
        previous['target'] == target &&
        (_hasUniqueSnapshotName(name) || hasMetadata) &&
        previous['identity'] == identity;
  }

  Future<void> _rememberSnapshot(
    String target,
    String name,
    String identity,
  ) async {
    appdata.implicitData['webdavLastBackup'] = {
      'target': target,
      'name': name,
      'identity': identity,
    };
    await appdata.writeImplicitData();
  }
}
