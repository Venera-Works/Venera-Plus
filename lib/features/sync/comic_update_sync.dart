import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

/// Subdirectory name under the configured sync directory for per-device update state files.
const String comicUpdateSyncDirectoryName = 'comic_updates';

/// Key for the stable local device UUID in implicitData (never synced).
const String comicUpdateDeviceIdImplicitKey = 'comicUpdateDeviceId';

/// Current schema version for comic update state documents.
const int comicUpdateDocumentCurrentVersion = 1;
bool _isComicUpdateSyncMerging = false;

/// Whether an incoming comic update state merge is currently active.
///
/// Used by DataSync change listeners to distinguish remotely applied peer
/// states from local user edits, preventing redundant upload loops while
/// still updating badges and UI tiles.
bool get isComicUpdateSyncMerging => _isComicUpdateSyncMerging;

/// Returns the stable local writer UUID stored in implicitData (never synced).
String getOrCreateComicUpdateDeviceId({Map<String, dynamic>? implicitData}) {
  final target = implicitData ?? appdata.implicitData;
  var id = target[comicUpdateDeviceIdImplicitKey] as String?;
  if (id == null || id.isEmpty) {
    id = const Uuid().v4();
    target[comicUpdateDeviceIdImplicitKey] = id;
    if (implicitData == null) {
      unawaited(appdata.writeImplicitData());
    }
  }
  return id;
}

/// Checks whether comic update synchronization is enabled according to domain policy.
bool isComicUpdateSyncEnabled({Map<String, dynamic>? implicitData}) {
  final target = implicitData ?? appdata.implicitData;
  return isAppDataSyncDomainEnabled(target, 'comicUpdate');
}

/// Strict JSON encoder for a device's comic update states document.
String encodeComicUpdateStatesDocument({
  required String deviceId,
  required Map<(String, int), ComicUpdateState> states,
  int? updatedAt,
}) {
  final list = <Map<String, dynamic>>[];
  for (final entry in states.entries) {
    list.add({
      'id': entry.key.$1,
      'type': entry.key.$2,
      'state': entry.value.toJson(),
    });
  }
  final doc = <String, dynamic>{
    'version': comicUpdateDocumentCurrentVersion,
    'deviceId': deviceId,
    'updatedAt': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    'states': list,
  };
  return jsonEncode(doc);
}

/// Strict JSON decoder for a comic update states document.
///
/// Throws [FormatException] if JSON structure, types, or version are invalid,
/// avoiding silent failures.
Map<(String, int), ComicUpdateState> decodeComicUpdateStatesDocument(
  String jsonStr,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonStr);
  } catch (e) {
    throw FormatException('Invalid JSON in comic update state document: $e');
  }
  if (decoded is! Map) {
    throw const FormatException(
      'Expected root JSON object in comic update state document',
    );
  }
  final version = decoded['version'];
  if (version is! int || version != comicUpdateDocumentCurrentVersion) {
    throw FormatException(
      'Unsupported version in comic update state document: $version (expected $comicUpdateDocumentCurrentVersion)',
    );
  }
  final deviceId = decoded['deviceId'];
  if (deviceId is! String || deviceId.isEmpty) {
    throw const FormatException(
      'Missing or invalid deviceId in comic update state document',
    );
  }
  final rawStates = decoded['states'];
  if (rawStates is! List) {
    throw const FormatException(
      'Missing or invalid states list in comic update state document',
    );
  }
  final result = <(String, int), ComicUpdateState>{};
  for (final item in rawStates) {
    if (item is! Map) {
      throw const FormatException(
        'Item in comic update states list is not a JSON object',
      );
    }
    final id = item['id'];
    final typeInt = item['type'];
    final stateRaw = item['state'];
    if (id is! String || id.isEmpty || typeInt is! int) {
      throw const FormatException(
        'Invalid comic ID or type in comic update state item',
      );
    }
    final state = ComicUpdateState.fromJson(stateRaw);
    result[(id, typeInt)] = state;
  }
  return result;
}

/// Merges incoming states into storage (using LocalFavoritesManager if available,
/// or raw SQLite database if manager is not initialized or closed).
bool applyComicUpdateStatesLocally(
  Map<(String, int), ComicUpdateState> incoming, {
  bool notify = true,
}) {
  if (incoming.isEmpty) return false;
  _isComicUpdateSyncMerging = true;
  try {
    final manager = LocalFavoritesManager.cache;
    if (manager != null && manager.isCurrentGeneration(manager.generation)) {
      return manager.mergeComicUpdateStates(incoming, notify: notify);
    }
    final dbFile = File(FilePath.join(App.dataPath, 'local_favorite.db'));
    if (dbFile.existsSync()) {
      final db = sqlite3.open(dbFile.path);
      try {
        FavoriteSyncData.ensureComicUpdateSchema(db);
        return FavoriteSyncData.mergeComicUpdateStates(db, incoming);
      } finally {
        db.close();
      }
    }
    return false;
  } finally {
    _isComicUpdateSyncMerging = false;
  }
}

/// Exports current local update states from manager or raw database.
Map<(String, int), ComicUpdateState> exportComicUpdateStatesLocally() {
  final manager = LocalFavoritesManager.cache;
  if (manager != null && manager.isCurrentGeneration(manager.generation)) {
    return manager.exportComicUpdateStates();
  }
  final dbFile = File(FilePath.join(App.dataPath, 'local_favorite.db'));
  if (dbFile.existsSync()) {
    final db = sqlite3.open(dbFile.path);
    try {
      FavoriteSyncData.ensureComicUpdateSchema(db);
      return FavoriteSyncData.readComicUpdateStates(db);
    } finally {
      db.close();
    }
  }
  return const {};
}

/// Syncs comic update state files over WebDAV.
///
/// Reads all peer state files in `comic_updates/`, merges their states locally,
/// and writes the local device's own state file if [uploadSelf] is true.
Future<bool> syncComicUpdatesWithWebDav(
  dav.Client client, {
  required String remoteBaseDirectory,
  required bool uploadSelf,
  String? deviceIdOverride,
  bool Function()? isCurrent,
}) async {
  if (!isComicUpdateSyncEnabled()) {
    return false;
  }
  final base = remoteBaseDirectory.endsWith('/')
      ? remoteBaseDirectory
      : '$remoteBaseDirectory/';
  final updateDir = '$base$comicUpdateSyncDirectoryName/';
  final deviceId = deviceIdOverride ?? getOrCreateComicUpdateDeviceId();
  final ownFilename = '$deviceId.json';

  List<dav.File> files;
  var dirExists = true;
  try {
    files = await client.readDir(updateDir);
  } on DioException catch (error) {
    if (error.response?.statusCode != 404) rethrow;
    dirExists = false;
    files = const [];
  }

  if (isCurrent?.call() == false) return false;
  final stateFiles = files
      .where(
        (f) => f.name != null && f.isDir != true && f.name!.endsWith('.json'),
      )
      .toList();

  final incomingStates = <(String, int), ComicUpdateState>{};
  for (final file in stateFiles) {
    if (isCurrent?.call() == false) return false;
    final fileName = file.name!;
    final remotePath = '$updateDir$fileName';
    final tempFile = File(
      FilePath.join(
        App.cachePath,
        'temp_dl_state_${DateTime.now().microsecondsSinceEpoch}_$fileName',
      ),
    );
    try {
      await client.read2File(remotePath, tempFile.path);
      if (isCurrent?.call() == false) return false;
      final content = await tempFile.readAsString();
      final decoded = decodeComicUpdateStatesDocument(content);
      for (final entry in decoded.entries) {
        final existing = incomingStates[entry.key];
        incomingStates[entry.key] = existing == null
            ? entry.value
            : existing.merge(entry.value);
      }
    } finally {
      if (await tempFile.exists()) {
        await tempFile.deleteIgnoreError();
      }
    }
  }

  if (isCurrent?.call() == false) return false;

  final changed = applyComicUpdateStatesLocally(incomingStates, notify: true);

  if (uploadSelf) {
    if (isCurrent?.call() == false) return false;
    if (!dirExists) {
      await client.mkdir(updateDir);
    }
    if (isCurrent?.call() == false) return false;
    final currentStates = exportComicUpdateStatesLocally();
    final docString = encodeComicUpdateStatesDocument(
      deviceId: deviceId,
      states: currentStates,
    );
    final tempUploadFile = File(
      FilePath.join(
        App.cachePath,
        'temp_up_state_${DateTime.now().microsecondsSinceEpoch}_$ownFilename',
      ),
    );
    try {
      await tempUploadFile.writeAsString(docString);
      if (isCurrent?.call() == false) return false;
      await client.writeFromFile(tempUploadFile.path, '$updateDir$ownFilename');
    } finally {
      if (await tempUploadFile.exists()) {
        await tempUploadFile.deleteIgnoreError();
      }
    }
  }

  return changed;
}

/// Syncs comic update state files over [RemoteFileStore].
///
/// Reads all peer state files in `comic_updates/`, merges their states locally,
/// and writes the local device's own state file if [uploadSelf] is true.
Future<bool> syncComicUpdatesWithStore(
  RemoteFileStore store, {
  required String remoteBaseDirectory,
  required bool uploadSelf,
  String? deviceIdOverride,
  bool Function()? isCurrent,
}) async {
  if (!isComicUpdateSyncEnabled()) {
    return false;
  }
  final base = normalizeRemoteDirectory(remoteBaseDirectory);
  final updateDir = '$base$comicUpdateSyncDirectoryName/';
  final deviceId = deviceIdOverride ?? getOrCreateComicUpdateDeviceId();
  final ownFilename = '$deviceId.json';

  List<RemoteEntry> entries;
  var dirExists = true;
  try {
    entries = await store.list(updateDir);
  } on RemoteStorageException catch (error) {
    if (error.code != 'not_found') rethrow;
    dirExists = false;
    entries = const [];
  }

  if (isCurrent?.call() == false) return false;
  final stateFiles = entries
      .where((e) => !e.isDirectory && e.name.endsWith('.json'))
      .toList();

  final incomingStates = <(String, int), ComicUpdateState>{};
  for (final file in stateFiles) {
    if (isCurrent?.call() == false) return false;
    final fileName = file.name;
    final tempFile = File(
      FilePath.join(
        App.cachePath,
        'temp_dl_state_${DateTime.now().microsecondsSinceEpoch}_$fileName',
      ),
    );
    try {
      await store.download(file.path, tempFile.path);
      if (isCurrent?.call() == false) return false;
      final content = await tempFile.readAsString();
      final decoded = decodeComicUpdateStatesDocument(content);
      for (final entry in decoded.entries) {
        final existing = incomingStates[entry.key];
        incomingStates[entry.key] = existing == null
            ? entry.value
            : existing.merge(entry.value);
      }
    } finally {
      if (await tempFile.exists()) {
        await tempFile.deleteIgnoreError();
      }
    }
  }

  if (isCurrent?.call() == false) return false;

  final changed = applyComicUpdateStatesLocally(incomingStates, notify: true);

  if (uploadSelf) {
    if (isCurrent?.call() == false) return false;
    if (!dirExists) {
      await store.mkdir(updateDir);
    }
    if (isCurrent?.call() == false) return false;
    final currentStates = exportComicUpdateStatesLocally();
    final docString = encodeComicUpdateStatesDocument(
      deviceId: deviceId,
      states: currentStates,
    );
    final tempUploadFile = File(
      FilePath.join(
        App.cachePath,
        'temp_up_state_${DateTime.now().microsecondsSinceEpoch}_$ownFilename',
      ),
    );
    try {
      await tempUploadFile.writeAsString(docString);
      if (isCurrent?.call() == false) return false;
      await store.upload(tempUploadFile.path, '$updateDir$ownFilename');
    } finally {
      if (await tempUploadFile.exists()) {
        await tempUploadFile.deleteIgnoreError();
      }
    }
  }

  return changed;
}
