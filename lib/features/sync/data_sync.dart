import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/sync/app_data_transfer.dart';
import 'package:venera_plus/foundation/app.dart';
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
      unawaited(uploadData());
    }
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
    unawaited(hasPendingChanges ? uploadData() : downloadData());
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
          unawaited(uploadData());
        }
        if (!_disposed) notifyListeners();
      }
    }
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    await _waitForUploadBeforeClose();
    exit(0);
  }

  Future<void> _waitForUploadBeforeClose() async {
    return _waitForTask(_DataSyncTask.upload);
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

  _DataSyncTask? _pendingTaskType;

  String? _lastError;

  RemoteFileStore? _activeStore;

  String? get lastError => _lastError;

  @override
  void dispose() {
    _disposed = true;
    _scheduleTimer?.cancel();
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
    if (_activeTaskType == _DataSyncTask.download) {
      return const Res(true);
    }
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.upload, _uploadDataNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadDataNow);
  }

  Future<Res<bool>> downloadData() async {
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.download, _downloadDataNow);
    }
    return _startTask(_DataSyncTask.download, _downloadDataNow);
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
        if (mode == DataSyncMode.scheduled && _pendingTask == null) {
          checkForAutomaticSync();
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
      _isUploading = false;
      _isDownloading = false;
      if (hasConfiguration && !_configuring && !_disposed) {
        appdata.implicitData['webdavSyncLastAttempt'] =
            _now.millisecondsSinceEpoch;
        appdata.writeImplicitData();
      }
      if (!_disposed) notifyListeners();
    }
  }

  String _taskLogTag(_DataSyncTask task) {
    return task == _DataSyncTask.upload ? 'Upload Data' : 'Data Sync';
  }

  Future<File> _exportSnapshot() {
    return debugSnapshotProducer?.call() ?? exportAppData();
  }

  bool _isTaskCurrent(int epoch) => !_disposed && epoch == _taskEpoch;

  Future<Res<bool>> _uploadDataNow() async {
    var debugUpload = debugUploadOverride;
    if (debugUpload != null) {
      return debugUpload();
    }
    final epoch = _taskEpoch;
    final location = _remoteLocation;
    if (location != null) return _uploadToStore(location, epoch);
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    var client =
        debugClientFactory?.call(config) ??
        config.createClient(logRequests: true);

    File? data;
    try {
      appdata.settings['dataVersion']++;
      await appdata.saveData(false);
      data = await _exportSnapshot();
      if (!_isTaskCurrent(epoch)) return const Res(true);
      var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
      var filename = time;
      filename += '-';
      filename += appdata.settings['dataVersion'].toString();
      filename += '.venera';
      late List<dav.File> files;
      try {
        files = await client.readDir(_remoteDirectory);
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
        await client.mkdir(_remoteDirectory);
        files = await client.readDir(_remoteDirectory);
      }
      files =
          files
              .where(
                (e) =>
                    e.name != null &&
                    e.isDir != true &&
                    _snapshotVersion(e.name!) != null,
              )
              .toList()
            ..sort((a, b) => _compareSnapshotNames(a.name!, b.name!));
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final remotePath = '$_remoteDirectory$filename';
      final options = await client.c.wdOptions(client, remotePath);
      if (options.statusCode == null || options.statusCode! >= 400) {
        throw DioException(
          requestOptions: options.requestOptions,
          response: options,
          type: DioExceptionType.badResponse,
          error: options.statusMessage,
        );
      }
      // The directory was verified above; writeFromFile would recreate it.
      final length = await data.length();
      final response = await client.c.req<Object?>(
        client,
        'PUT',
        remotePath,
        data: data.openRead(),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['content-length'] = length;
          options.headers!['content-type'] = 'application/octet-stream';
        },
      );
      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          error: response.statusMessage,
        );
      }
      if (!_isTaskCurrent(epoch)) return const Res(true);
      files =
          (await client.readDir(_remoteDirectory))
              .where(
                (e) =>
                    e.name != null &&
                    e.isDir != true &&
                    _snapshotVersion(e.name!) != null,
              )
              .toList()
            ..sort((a, b) => _compareSnapshotNames(a.name!, b.name!));
      final old = files
          .where((e) => e.name!.startsWith("$time-") && e.name != filename)
          .toList();
      for (final file in old) {
        if (!_isTaskCurrent(epoch)) return const Res(true);
        await client.remove('$_remoteDirectory${file.name!}');
      }
      final retained = files.where((file) => !old.contains(file)).toList();
      while (retained.length > 10) {
        if (!_isTaskCurrent(epoch)) return const Res(true);
        final oldest = retained.firstWhere((file) => file.name != filename);
        await client.remove('$_remoteDirectory${oldest.name!}');
        retained.remove(oldest);
      }
      if (!_isTaskCurrent(epoch)) return const Res(true);
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Upload Data", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      if (data != null) await data.deleteIgnoreError();
    }
  }

  Future<Res<bool>> _downloadDataNow() async {
    var debugDownload = debugDownloadOverride;
    if (debugDownload != null) {
      return debugDownload();
    }
    final epoch = _taskEpoch;
    final location = _remoteLocation;
    if (location != null) return _downloadFromStore(location, epoch);
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    var client =
        debugClientFactory?.call(config) ??
        config.createClient(logRequests: true);

    try {
      var files = await client.readDir(_remoteDirectory);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      files =
          files
              .where(
                (e) =>
                    e.name != null &&
                    e.isDir != true &&
                    _snapshotVersion(e.name!) != null,
              )
              .toList()
            ..sort((a, b) => _compareSnapshotNames(b.name!, a.name!));
      var file = files.firstOrNull;
      if (file == null) {
        throw 'No data file found';
      }
      var version = file.name!.split('-').elementAtOrNull(1)?.split('.').first;
      if (version != null && int.tryParse(version) != null) {
        var currentVersion = appdata.settings['dataVersion'];
        if (currentVersion != null && int.parse(version) <= currentVersion) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }
      }
      Log.info("Data Sync", "Downloading data from WebDAV server");
      var localFile = File(FilePath.join(App.cachePath, file.name!));
      await client.read2File('$_remoteDirectory${file.name!}', localFile.path);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await importAppData(localFile, checkVersion: true);
      _downloadApplied = true;
      await localFile.delete();
      HistoryManager().notifyChanges();
      LocalFavoritesManager().notifyChanges();
      ImageFavoriteManager().notifyChanges();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Data Sync", "Data downloaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Data Sync", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> _uploadToStore(RemoteLocation location, int epoch) async {
    RemoteFileStore? store;
    File? data;
    final directory = location.directory;
    try {
      store = RemoteStorageAccounts.instance.storeFor(location.accountId);
      _activeStore = store;
      appdata.settings['dataVersion']++;
      await appdata.saveData(false);
      data = await _exportSnapshot();
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final day = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
          .toString();
      final filename = '$day-${appdata.settings['dataVersion']}.venera';
      try {
        await store.list(directory);
      } on RemoteStorageException catch (error) {
        if (error.code != 'not_found') rethrow;
        await store.mkdir(directory);
        await store.list(directory);
      }
      final path = '${normalizeRemoteDirectory(directory)}$filename';
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await store.upload(data.path, path);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      final snapshots =
          (await store.list(directory))
              .where(
                (file) =>
                    !file.isDirectory && _snapshotVersion(file.name) != null,
              )
              .toList()
            ..sort((a, b) => _compareSnapshotNames(a.name, b.name));
      final oldSameDay = snapshots
          .where((file) => file.name.startsWith('$day-') && file.path != path)
          .toList();
      for (final file in oldSameDay) {
        if (!_isTaskCurrent(epoch)) return const Res(true);
        await store.delete(file.path);
      }
      final retained = snapshots
          .where((file) => !oldSameDay.contains(file))
          .toList();
      while (retained.length > 10) {
        if (!_isTaskCurrent(epoch)) return const Res(true);
        final oldest = retained.firstWhere((file) => file.path != path);
        await store.delete(oldest.path);
        retained.remove(oldest);
      }
      if (!_isTaskCurrent(epoch)) return const Res(true);
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      return const Res(true);
    } catch (error, stack) {
      Log.error('Upload Data', error, stack);
      return Res.error(error.toString());
    } finally {
      if (data != null) await data.deleteIgnoreError();
      if (identical(_activeStore, store)) _activeStore = null;
      if (store != null) RemoteStorageAccounts.instance.release(store);
    }
  }

  Future<Res<bool>> _downloadFromStore(
    RemoteLocation location,
    int epoch,
  ) async {
    RemoteFileStore? store;
    File? localFile;
    try {
      store = RemoteStorageAccounts.instance.storeFor(location.accountId);
      _activeStore = store;
      final files = await store.list(location.directory);
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
      if (file == null) {
        return const Res.error('No data file found');
      }
      final version = file.name.split('-').elementAtOrNull(1)?.split('.').first;
      if (version != null && int.tryParse(version) != null) {
        final current = appdata.settings['dataVersion'];
        if (current is int && int.parse(version) <= current) {
          return const Res(true);
        }
      }
      localFile = File(FilePath.join(App.cachePath, file.name));
      await store.download(file.path, localFile.path);
      if (!_isTaskCurrent(epoch)) return const Res(true);
      await importAppData(localFile, checkVersion: true);
      _downloadApplied = true;
      HistoryManager().notifyChanges();
      LocalFavoritesManager().notifyChanges();
      ImageFavoriteManager().notifyChanges();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      return const Res(true);
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      return Res.error(error.toString());
    } finally {
      if (localFile != null) await localFile.deleteIgnoreError();
      if (identical(_activeStore, store)) _activeStore = null;
      if (store != null) RemoteStorageAccounts.instance.release(store);
    }
  }

  static (int, int)? _snapshotVersion(String name) {
    final match = RegExp(r'^(\d+)-(\d+)\.venera$').firstMatch(name);
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  static int _compareSnapshotNames(String left, String right) {
    final a = _snapshotVersion(left)!;
    final b = _snapshotVersion(right)!;
    final day = a.$1.compareTo(b.$1);
    return day != 0 ? day : a.$2.compareTo(b.$2);
  }
}
