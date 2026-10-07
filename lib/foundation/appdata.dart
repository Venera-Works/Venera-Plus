import 'dart:async';
import 'dart:convert';

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_layout.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/init.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];
  var _overflowSearchHistory = <String>[];
  final _searchHistoryOrders = <String, num>{};
  int _nextSearchHistoryOrder = -1;

  List<String> get fullSearchHistory => [
    ...searchHistory,
    ..._overflowSearchHistory,
  ];

  void setFullSearchHistory(
    List<String> orderedKeywords, {
    Map<String, num>? orders,
  }) {
    _overflowSearchHistory.clear();
    searchHistory.clear();
    _searchHistoryOrders.clear();
    for (var i = 0; i < orderedKeywords.length; i++) {
      final keyword = orderedKeywords[i];
      if (i < 50) {
        searchHistory.add(keyword);
      } else {
        _overflowSearchHistory.add(keyword);
      }
      final order = orders == null ? i : orders[keyword];
      if (order != null) {
        _searchHistoryOrders[keyword] = order;
        final next = order.floor() - 1;
        if (next < _nextSearchHistoryOrder) {
          _nextSearchHistoryOrder = next;
        }
      }
    }
    _ensureSearchHistoryOrders();
  }

  void _ensureSearchHistoryOrders() {
    final count = searchHistory.length + _overflowSearchHistory.length;
    var changed = _searchHistoryOrders.length != count;
    if (_searchHistoryOrders.isEmpty && _nextSearchHistoryOrder == -1) {
      // Old backups store only a list. Seed it once, never renumber after edits.
      for (var i = 0; i < count; i++) {
        final keyword = i < searchHistory.length
            ? searchHistory[i]
            : _overflowSearchHistory[i - searchHistory.length];
        _searchHistoryOrders[keyword] = i;
      }
      return;
    }
    for (var i = count - 1; i >= 0; i--) {
      final keyword = i < searchHistory.length
          ? searchHistory[i]
          : _overflowSearchHistory[i - searchHistory.length];
      if (!_searchHistoryOrders.containsKey(keyword)) {
        _searchHistoryOrders[keyword] = _nextSearchHistoryOrder--;
        changed = true;
      }
    }
    if (changed) {
      final live = {...searchHistory, ..._overflowSearchHistory};
      _searchHistoryOrders.removeWhere((keyword, _) => !live.contains(keyword));
    }
  }

  SyncRecords exportSearchHistoryRecords() {
    _ensureSearchHistoryOrders();
    return {
      for (final keyword in searchHistory)
        syncRecordKey('search', [keyword]): {
          'order': _searchHistoryOrders[keyword],
        },
      for (final keyword in _overflowSearchHistory)
        syncRecordKey('search', [keyword]): {
          'order': _searchHistoryOrders[keyword],
        },
    };
  }

  /// Shared by live persistence and isolated legacy readers.
  static ({Map<String, num> orders, int nextOrder}) decodeSearchHistoryOrder(
    Map<Object?, Object?> data,
    List<String> keywords,
  ) {
    final rawOrders = data['searchHistoryOrders'];
    final rawNext = data['nextSearchHistoryOrder'];
    if (rawNext != null && rawNext is! int) {
      throw const FormatException(
        'Next search history order must be an integer',
      );
    }
    var next = rawNext is int && rawNext < -1 ? rawNext : -1;
    final orders = <String, num>{};
    if (rawOrders == null) {
      for (var i = 0; i < keywords.length; i++) {
        orders[keywords[i]] = i;
      }
    } else {
      if (rawOrders is! Map) {
        throw const FormatException('Search history orders must be an object');
      }
      for (final entry in rawOrders.entries) {
        if (entry.key is! String ||
            entry.value is! num ||
            !(entry.value as num).isFinite) {
          throw const FormatException('Invalid search history order');
        }
      }
      for (final keyword in keywords) {
        final order = rawOrders[keyword];
        if (order is num) {
          orders[keyword] = order;
          final floor = order.floor() - 1;
          if (floor < next) {
            next = floor;
          }
        }
      }
      for (var i = keywords.length - 1; i >= 0; i--) {
        if (!orders.containsKey(keywords[i])) {
          orders[keywords[i]] = next--;
        }
      }
    }
    return (orders: orders, nextOrder: next);
  }

  Future<void> _writeQueue = Future.value();

  FutureOr<void> Function()? _syncDataRequestHandler;

  void registerSyncDataRequestHandler(FutureOr<void> Function()? handler) {
    _syncDataRequestHandler = handler;
  }

  Future<void> saveData([bool sync = true]) {
    final handler = _syncDataRequestHandler;
    if (sync && handler != null) {
      // Invalidate an in-flight sync before its commit guard can run. This
      // notification remains in the caller's zone, including imported writes.
      unawaited(Future.sync(handler));
    }
    final data = jsonEncode(toJson());
    final syncJson = jsonDecode(data) as Map<String, dynamic>;
    final syncSettings = syncJson['settings'] as Map<String, dynamic>;
    for (final field in getDisabledSyncFields(forExport: true)) {
      syncSettings.remove(field);
    }
    final syncData = jsonEncode(syncJson);
    return _enqueueWrite(() => _writeAppData(data, syncData));
  }

  void addSearchHistory(String keyword) {
    _ensureSearchHistoryOrders();
    _searchHistoryOrders[keyword] = _nextSearchHistoryOrder--;
    _overflowSearchHistory.remove(keyword);
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      final overflow = searchHistory.removeLast();
      if (!_overflowSearchHistory.contains(overflow)) {
        _overflowSearchHistory.insert(0, overflow);
      }
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    _overflowSearchHistory.remove(keyword);
    _searchHistoryOrders.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    _overflowSearchHistory.clear();
    _searchHistoryOrders.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    settings._materializeChangedDefaults();
    _ensureSearchHistoryOrders();
    return {
      'settings': settings._data,
      'searchHistory': searchHistory,
      if (_overflowSearchHistory.isNotEmpty)
        'overflowSearchHistory': _overflowSearchHistory,
      if (_searchHistoryOrders.isNotEmpty)
        'searchHistoryOrders': _searchHistoryOrders,
      if (_nextSearchHistoryOrder != -1)
        'nextSearchHistoryOrder': _nextSearchHistoryOrder,
    };
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Settings that are always device-local or synchronized only by an
  /// explicit opt-in policy.
  static const _disableSync = {
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "webdavAutoSync",
    "webdavSyncMode",
    "webdavSyncDirection",
    "webdavSyncTiming",
    "webdavSyncIntervalMinutes",
    "webdavSyncPending",
    "webdavSyncLastAttempt",
    "webdavBaselineTarget",
    "webdavLastSyncedRemoteFile",
    "webdavLastSyncedRemoteVersion",
    "webdavLastSyncedRemoteEtag",
    "webdavProxyEnabled",
    "backupWebdav",
    "backupWebdavPath",
    "backupWebdavSyncEnabled",
    "webdavComicLibrary",
    "webdavComicLibraryPath",
    "webdavComicLibraryAutoSync",
    "webdavComicLibrarySyncIntervalMinutes",
    "webdavComicLibrarySyncEnabled",
    "disableSyncFields",
    "deviceId",
    "deviceSpecificSettings",
    "bangumiAccessToken",
    "bangumiUsername",
    "lastSyncTime",
  };

  static const _archiveSyncFields = {"backupWebdav", "backupWebdavPath"};

  static const _comicLibrarySyncFields = {
    "webdavComicLibrary",
    "webdavComicLibraryPath",
    "webdavComicLibraryAutoSync",
    "webdavComicLibrarySyncIntervalMinutes",
  };

  static const _obsoleteSetting = "readLaterFolder";

  /// Returns the effective set of forbidden / device-local setting keys.
  Set<String> getDisabledSyncFields({bool forExport = false}) {
    final disabled = <String>{
      ..._disableSync,
      _obsoleteSetting,
      'readingFolder',
    };
    if (settings["backupWebdavSyncEnabled"] == true) {
      disabled.removeAll(_archiveSyncFields);
    }
    if (settings["webdavComicLibrarySyncEnabled"] == true) {
      disabled.removeAll(_comicLibrarySyncFields);
    }
    final custom = settings["disableSyncFields"];
    if (custom is String) {
      disabled.addAll(splitField(custom));
    }
    return disabled;
  }

  /// Checks if a setting key is allowed to be exported or imported via sync.
  bool isSettingSyncAllowed(String rootKey) {
    return !getDisabledSyncFields().contains(rootKey);
  }

  /// Exports settings that are permitted by sync safety policies.
  Map<String, dynamic> exportSyncSettings() {
    settings._materializeChangedDefaults();
    final disabled = getDisabledSyncFields(forExport: true);
    final result = <String, dynamic>{};
    for (final entry in settings._data.entries) {
      if (disabled.contains(entry.key) || entry.key == _obsoleteSetting) {
        continue;
      }
      result[entry.key] = entry.value;
    }
    return result;
  }

  /// Validates known setting roots against their existing default value types.
  /// Unknown extension settings remain JSON-valued rather than a new allowlist.
  void validateSyncSetting(String key, Object? value) {
    Settings.validateValue(key, value);
  }

  /// Applies a single root setting if permitted.
  void applySyncSetting(String key, dynamic value) {
    if (!isSettingSyncAllowed(key) || key == _obsoleteSetting) return;
    validateSyncSetting(key, value);
    settings[key] = value;
  }

  /// Applies a nested setting leaf along [path] if the root key is permitted.
  void applySyncSettingLeaf(List<String> path, dynamic value) {
    if (path.isEmpty) return;
    final rootKey = path.first;
    if (!isSettingSyncAllowed(rootKey) || rootKey == _obsoleteSetting) return;
    if (path.length == 1) {
      applySyncSetting(rootKey, value);
      return;
    }

    final current = settings[rootKey];
    final rootMap = current is Map
        ? Map<String, dynamic>.from(current)
        : <String, dynamic>{};

    Map<String, dynamic> cursor = rootMap;
    for (int i = 1; i < path.length - 1; i++) {
      final key = path[i];
      final next = cursor[key];
      if (next is Map) {
        final childMap = Map<String, dynamic>.from(next);
        cursor[key] = childMap;
        cursor = childMap;
      } else {
        final childMap = <String, dynamic>{};
        cursor[key] = childMap;
        cursor = childMap;
      }
    }
    cursor[path.last] = value;
    validateSyncSetting(rootKey, rootMap);
    settings[rootKey] = rootMap;
  }

  /// Removes a nested setting leaf along [path] if the root key is permitted.
  void removeSyncSettingLeaf(List<String> path) {
    if (path.isEmpty) return;
    final rootKey = path.first;
    if (!isSettingSyncAllowed(rootKey) || rootKey == _obsoleteSetting) return;
    if (path.length == 1) {
      settings.remove(rootKey);
      return;
    }
    if (!settings.containsKey(rootKey)) return;

    final current = settings[rootKey];
    if (current is! Map) return;
    final rootMap = Map<String, dynamic>.from(current);
    Map<String, dynamic> cursor = rootMap;
    for (int i = 1; i < path.length - 1; i++) {
      final key = path[i];
      final next = cursor[key];
      if (next is! Map) return;
      final childMap = Map<String, dynamic>.from(next);
      cursor[key] = childMap;
      cursor = childMap;
    }
    cursor.remove(path.last);
    settings[rootKey] = rootMap;
  }

  /// Returns keys currently set that are eligible for sync export/import.
  List<String> get syncAllowedSettingKeys {
    return exportSyncSettings().keys.toList();
  }

  /// Removes an eligible setting by key, strictly observing safety filtering.
  void removeSyncSetting(String key) {
    if (!isSettingSyncAllowed(key) ||
        key == _obsoleteSetting ||
        key == 'readingFolder') {
      return;
    }
    settings.remove(key);
  }

  /// Sync data from another device and persist the accepted settings.
  Future<void> syncData(Map<String, dynamic> data) async {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"] as String,
      );

      final archiveSyncEnabled =
          this.settings["backupWebdavSyncEnabled"] == true;
      final comicLibrarySyncEnabled =
          this.settings["webdavComicLibrarySyncEnabled"] == true;

      // A legacy snapshot has no role marker. Do not inherit this device's
      // binding when replacing its favorites database.
      if (!settings.containsKey('readingFolder') &&
          !customDisableSync.contains('readingFolder')) {
        this.settings._data.remove('readingFolder');
      }
      for (var key in settings.keys) {
        if (key == _obsoleteSetting) continue;
        if (_archiveSyncFields.contains(key)) {
          if (archiveSyncEnabled) {
            this.settings[key] = settings[key];
          }
          continue;
        }
        if (_comicLibrarySyncFields.contains(key)) {
          if (comicLibrarySyncEnabled) {
            this.settings[key] = settings[key];
          }
          continue;
        }
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }
    }
    final keywords = <String>[
      ...List<String>.from(data['searchHistory'] ?? const <String>[]),
      ...List<String>.from(data['overflowSearchHistory'] ?? const <String>[]),
    ];
    final orderState = decodeSearchHistoryOrder(data, keywords);
    _nextSearchHistoryOrder = orderState.nextOrder;
    setFullSearchHistory(keywords, orders: orderState.orders);
    await saveData(false);
  }

  var implicitData = <String, dynamic>{};

  Future<void> _enqueueWrite(Future<void> Function() write) {
    var next = _writeQueue.then((_) => write(), onError: (_) => write());
    _writeQueue = next.catchError((Object error, StackTrace stackTrace) {
      Log.error("Appdata", error, stackTrace);
    });
    return next;
  }

  Future<void> _writeAppData(String data, String syncData) async {
    final file = File(FilePath.join(App.dataPath, 'appdata.json'));
    final file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
    await Future.wait([
      _writeTextAtomically(file, data),
      _writeTextAtomically(file4sync, syncData),
    ]);
  }

  Future<void> writeImplicitData() => _enqueueWrite(() async {
    var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
    await _writeTextAtomically(file, jsonEncode(implicitData));
  });

  @override
  Future<void> doInit() async {
    var dataPath = App.dataPath;
    await _loadAppData(dataPath);
    if ((settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    await _loadImplicitData(dataPath);
  }

  @visibleForTesting
  Future<void> loadDataForTesting(String dataPath) => _loadAppData(dataPath);

  Future<void> _loadAppData(String dataPath) async {
    final primary = File(FilePath.join(dataPath, 'appdata.json'));
    final candidates = [
      primary,
      File('${primary.path}.bak'),
      File(FilePath.join(dataPath, 'syncdata.json')),
    ];
    File? loadedFrom;
    var primaryInvalid = false;

    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      try {
        final decoded = _decodeAppData(await candidate.readAsString());
        // Persisted absence is a setting tombstone. Defaults are read-only
        // fallbacks, not fresh stored values reintroduced at every startup.
        settings.replaceAll(decoded.settings);
        _nextSearchHistoryOrder = decoded.nextSearchHistoryOrder;
        setFullSearchHistory([
          ...decoded.searchHistory,
          ...decoded.overflowSearchHistory,
        ], orders: decoded.searchHistoryOrders);
        loadedFrom = candidate;
        break;
      } catch (error, stackTrace) {
        Log.error(
          "Appdata",
          "Failed to load ${candidate.path}",
          '$error\n$stackTrace',
        );
        if (candidate.path == primary.path) {
          primaryInvalid = true;
        }
      }
    }

    if (loadedFrom == null) {
      if (primaryInvalid) {
        await _preserveCorruptFile(primary);
      }
      return;
    }
    if (loadedFrom.path == primary.path) {
      return;
    }

    if (primaryInvalid) {
      await _preserveCorruptFile(primary);
    }
    await _writeTextAtomically(
      primary,
      await loadedFrom.readAsString(),
      createBackup: false,
    );
    Log.info("Appdata", "Recovered appdata from ${loadedFrom.path}");
  }

  ({
    Map<String, dynamic> settings,
    List<String> searchHistory,
    List<String> overflowSearchHistory,
    Map<String, num> searchHistoryOrders,
    int nextSearchHistoryOrder,
  })
  _decodeAppData(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('Appdata root must be an object');
    }
    final rawSettings = decoded['settings'];
    if (rawSettings is! Map) {
      throw const FormatException('Appdata settings must be an object');
    }
    final normalizedSettings = <String, dynamic>{};
    for (final entry in rawSettings.entries) {
      if (entry.key is String && entry.key != _obsoleteSetting) {
        final value = entry.key == 'initialPage'
            ? normalizeStartupPage(entry.value)
            : entry.value;
        Settings.validateValue(entry.key as String, value);
        normalizedSettings[entry.key as String] = value;
      }
    }

    final rawSearchHistory = decoded['searchHistory'];
    if (rawSearchHistory != null && rawSearchHistory is! List) {
      throw const FormatException('Appdata searchHistory must be a list');
    }
    final rawOverflow = decoded['overflowSearchHistory'];
    if (rawOverflow != null && rawOverflow is! List) {
      throw const FormatException(
        'Appdata overflowSearchHistory must be a list',
      );
    }
    final searchHistory = rawSearchHistory == null
        ? <String>[]
        : rawSearchHistory.whereType<String>().toList();
    final overflow = rawOverflow == null
        ? <String>[]
        : rawOverflow.whereType<String>().toList();
    final orderState = decodeSearchHistoryOrder(decoded, [
      ...searchHistory,
      ...overflow,
    ]);
    return (
      settings: normalizedSettings,
      searchHistory: searchHistory,
      overflowSearchHistory: overflow,
      searchHistoryOrders: orderState.orders,
      nextSearchHistoryOrder: orderState.nextOrder,
    );
  }

  Future<void> _loadImplicitData(String dataPath) async {
    final primary = File(FilePath.join(dataPath, 'implicitData.json'));
    final candidates = [primary, File('${primary.path}.bak')];
    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Implicit data root must be an object');
        }
        implicitData = Map<String, dynamic>.from(decoded);
        if (candidate.path != primary.path) {
          await _preserveCorruptFile(primary);
          await _writeTextAtomically(
            primary,
            await candidate.readAsString(),
            createBackup: false,
          );
          Log.info("Appdata", "Recovered implicit data from ${candidate.path}");
        }
        return;
      } catch (error, stackTrace) {
        Log.error(
          "Appdata",
          "Failed to load ${candidate.path}",
          '$error\n$stackTrace',
        );
      }
    }
    if (await primary.exists()) {
      await _preserveCorruptFile(primary);
    }
  }

  Future<void> _writeTextAtomically(
    File target,
    String content, {
    bool createBackup = true,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(content, flush: true);

    try {
      if (createBackup && await target.exists()) {
        await target.copy('${target.path}.bak');
      }
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        await target.deleteIgnoreError();
        await temporary.rename(target.path);
      }
    } finally {
      await temporary.deleteIgnoreError();
    }
  }

  Future<void> _preserveCorruptFile(File file) async {
    if (!await file.exists()) {
      return;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final destination = '${file.path}.corrupt-$timestamp';
    try {
      await file.rename(destination);
      Log.warning("Appdata", "Preserved invalid data as $destination");
    } catch (error, stackTrace) {
      Log.error("Appdata", "Failed to preserve ${file.path}", stackTrace);
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = _createDefaults();
  final _readDefaults = <String, dynamic>{};

  static final _defaults = _createDefaults();

  static Map<String, dynamic> _createDefaults() => <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'favoritesDisplayMode': 'list', // list, gallery
    'favoritesGalleryColumns': 0, // 0 means automatic, 2-6 are fixed
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'searchShortcuts': [],
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'showUpdateStatusOnTile': true,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'waterfallTopToBottom', // values of [ReaderMode]
    'autoReaderMode': false,
    'pagedReaderMode': 'galleryRightToLeft',
    'longStripReaderMode': 'continuousTopToBottom',
    'comicLayoutDetections': <String, dynamic>{},
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'oneHandedMode': false,
    'enablePageAnimation': true,
    'readerBrightnessEnabled': false,
    'readerBrightness': 50, // 20 - 100
    'eInkRefreshEnabled': false,
    'eInkRefreshDuration': 100, // milliseconds
    'eInkRefreshInterval': 1, // page changes
    'eInkRefreshStyle': 'black', // black, white, whiteThenBlack
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'historyRetentionDays': 0, // 0 means disabled
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'limitImageWidth': true,
    'readerSideMargin': 0, // Percent on each side of the limited flow width.
    'webdav': [], // empty means not configured
    'webdavProxyEnabled': true,
    'backupWebdav': [], // empty means not configured
    'backupWebdavPath': '/venera_backup/',
    'backupWebdavSyncEnabled': false,
    'webdavComicLibrary': [], // empty means not configured
    'webdavComicLibraryPath': '/venera_comics/',
    'webdavComicLibraryAutoSync': true,
    'webdavComicLibrarySyncIntervalMinutes': 360,
    'webdavComicLibrarySyncEnabled': false,
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': "",
    'preloadImageCount': 4,
    'initialPage': StartupPage.home.id,
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'splitDualPage': false,
    'splitDualPageInvert': false,
    'bangumiAccessToken': '',
    'bangumiUsername': '',
    'bangumiAutoSyncEnabled': true,
    'bangumiAutoMetadataScrapeEnabled': false,
    'bangumiBindings': <String, Map<String, dynamic>>{},
  };

  static void validateValue(String key, Object? value) {
    if (!_defaults.containsKey(key)) {
      jsonEncode(value);
      return;
    }
    final defaultValue = _defaults[key];
    final bool valid;
    if (defaultValue == null) {
      valid = switch (key) {
        'searchSources' => value == null || value is List,
        'defaultSearchTarget' ||
        'quickFavorite' => value == null || value is String,
        _ => value == null,
      };
    } else {
      valid = switch (defaultValue) {
        bool() => value is bool,
        int() => value is int,
        num() => value is num,
        String() => value is String,
        List() => value is List,
        Map() => value is Map,
        _ => false,
      };
    }
    if (!valid) {
      throw FormatException('Invalid value type for setting "$key"');
    }
    jsonEncode(value);
  }

  operator [](String key) {
    if (_data.containsKey(key)) return _data[key];
    final value = _defaults[key];
    if (value is! Map && value is! List) return value;
    return _readDefaults.putIfAbsent(key, () => _copyDefault(value));
  }

  static dynamic _copyDefault(dynamic value) => switch (value) {
    Map() => <String, dynamic>{
      for (final entry in value.entries)
        entry.key as String: _copyDefault(entry.value),
    },
    List() => [for (final item in value) _copyDefault(item)],
    _ => value,
  };

  // Existing callers mutate lists returned by [] and then saveData. Promote
  // only an actual mutation, never a default merely read after a tombstone.
  void _materializeChangedDefaults() {
    for (final entry in _readDefaults.entries) {
      if (!_data.containsKey(entry.key) &&
          !syncValuesEqual(entry.value, _defaults[entry.key])) {
        _data[entry.key] = entry.value;
      }
    }
  }

  operator []=(String key, dynamic value) {
    if (key == 'initialPage') {
      value = normalizeStartupPage(value);
    }
    _data[key] = value;
    _readDefaults.remove(key);
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  bool containsKey(String key) => _data.containsKey(key);

  dynamic remove(String key) {
    _readDefaults.remove(key);
    if (!_data.containsKey(key)) return null;
    final value = _data.remove(key);
    notifyListeners();
    return value;
  }

  void replaceAll(Map<String, dynamic> values) {
    _readDefaults.clear();
    _data
      ..clear()
      ..addAll(values);
    if (_data.containsKey('initialPage')) {
      _data['initialPage'] = normalizeStartupPage(_data['initialPage']);
    }
    notifyListeners();
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    final values = this['comicSpecificSettings']["$comicId@$sourceKey"];
    if (values is Map &&
        values.containsKey('readerMode') &&
        !values.containsKey('readerModeOverride')) {
      setComicReaderModeOverride(
        comicId,
        sourceKey,
        comicReaderModeOverride(comicId, sourceKey),
      );
    }
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return this['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (key == 'readerMode') return resolveReaderMode(comicId, sourceKey);
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          this['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  String? comicReaderModeOverride(String comicId, String sourceKey) {
    final values = this['comicSpecificSettings']["$comicId@$sourceKey"];
    if (values is! Map) return null;
    if (values.containsKey('readerModeOverride')) {
      final mode = values['readerModeOverride'];
      return mode is String && mode != 'default' ? mode : null;
    }
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      final mode = values['readerMode'];
      return mode is String ? mode : null;
    }
    return null;
  }

  void setComicReaderModeOverride(
    String comicId,
    String sourceKey,
    String? mode,
  ) {
    setReaderSetting(
      comicId,
      sourceKey,
      'readerModeOverride',
      mode ?? 'default',
    );
  }

  ComicLayout comicLayout(String comicId, String sourceKey) {
    final record = this['comicLayoutDetections']["$comicId@$sourceKey"];
    if (record is! Map || record['version'] != ComicLayoutDetection.version) {
      return ComicLayout.unknown;
    }
    return ComicLayout.fromKey(record['layout']);
  }

  void setComicLayout(
    String comicId,
    String sourceKey,
    ComicLayoutDetection detection,
  ) {
    final records =
        _data.putIfAbsent(
              'comicLayoutDetections',
              () => this['comicLayoutDetections'],
            )
            as Map;
    records["$comicId@$sourceKey"] = {
      'layout': detection.layout.name,
      'samples': detection.sampleCount,
      'version': ComicLayoutDetection.version,
    };
    notifyListeners();
  }

  String resolveReaderMode(String comicId, String sourceKey) {
    final override = comicReaderModeOverride(comicId, sourceKey);
    if (override != null) return override;
    if (getDeviceReaderSetting('autoReaderMode') == true) {
      final key = switch (comicLayout(comicId, sourceKey)) {
        ComicLayout.paged => 'pagedReaderMode',
        ComicLayout.longStrip => 'longStripReaderMode',
        ComicLayout.unknown => 'readerMode',
      };
      return getDeviceReaderSetting(key) as String;
    }
    return getDeviceReaderSetting('readerMode') as String;
  }

  void setActiveReaderSetting(
    String? comicId,
    String? sourceKey,
    String key,
    dynamic value,
  ) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      setReaderSetting(comicId!, sourceKey!, key, value);
    } else if (isDeviceSpecificSettingsEnabled()) {
      setDeviceReaderSetting(key, value);
    } else {
      this[key] = value;
    }
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    final records =
        _data.putIfAbsent(
              'comicSpecificSettings',
              () => this['comicSpecificSettings'],
            )
            as Map<String, dynamic>;
    records.putIfAbsent("$comicId@$sourceKey", () => <String, dynamic>{})[key] =
        value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (this['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = this['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return this['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return this[key];
    }
    var deviceId = this['deviceId'] as String;
    return this['deviceSpecificSettings'][deviceId]?[key] ?? this[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    final records =
        _data.putIfAbsent(
              'deviceSpecificSettings',
              () => this['deviceSpecificSettings'],
            )
            as Map<String, dynamic>;
    records.putIfAbsent(deviceId, () => <String, dynamic>{})[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = this['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (this['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = this['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';
