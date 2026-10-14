import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/local_comics/import_export/import_export.dart';
import 'package:venera_plus/features/local_comics/local_storage_guard.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// WebDAV archive backup configuration for local comic CBZ files.
class BackupConfig {
  BackupConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
    this.location,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_backup/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;
  final RemoteLocation? location;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => location != null || endpoint.isValid;

  String get targetIdentity => location == null
      ? '${endpoint.url}|${endpoint.user}|$remotePath'
      : '${location!.accountId}|${location!.directory}';

  static BackupConfig fromSettings() {
    final location = remoteLocation;
    final config = appdata.settings['backupWebdav'];
    final path = appdata.settings['backupWebdavPath'];
    if (config is List && config.whereType<String>().length == 3) {
      final values = config.whereType<String>().toList();
      return BackupConfig(
        url: values[0].trim(),
        user: values[1].trim(),
        pass: values[2].trim(),
        remotePath:
            location?.directory ?? (path is String ? path : '/venera_backup/'),
        location: location,
      );
    }
    return BackupConfig(
      url: '',
      user: '',
      pass: '',
      remotePath:
          location?.directory ?? (path is String ? path : '/venera_backup/'),
      location: location,
    );
  }

  static RemoteLocation? get remoteLocation {
    final raw = appdata.settings['backupRemoteLocation'];
    if (raw is! Map) return null;
    final location = RemoteLocation.fromJson(raw);
    return location.accountId.isEmpty ? null : location;
  }

  static Future<void> saveToSettings(BackupConfig config) async {
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      appdata.settings['backupWebdav'] = [];
    } else {
      appdata.settings['backupWebdav'] = [
        config.url.trim(),
        config.user.trim(),
        config.pass.trim(),
      ];
    }
    appdata.settings['backupWebdavPath'] = config.remotePath;
    await appdata.saveData(false);
  }

  String remoteFilePath(String fileName) {
    final directory = location?.directory ?? remotePath;
    return '${normalizeRemoteDirectory(directory)}$fileName';
  }
}

/// A CBZ backup file stored on WebDAV.
class BackupFile {
  const BackupFile({
    required this.name,
    required this.size,
    required this.modified,
    this.targetIdentity,
  });

  final String name;
  final int size;
  final DateTime modified;
  final String? targetIdentity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupFile &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          size == other.size &&
          modified == other.modified;

  @override
  int get hashCode => Object.hash(name, size, modified, targetIdentity);
}

/// Abstraction over WebDAV operations to keep backup logic testable.
abstract class ComicBackupWebDavOps {
  Future<void> test(BackupConfig config);

  Future<List<BackupFile>> list(BackupConfig config);

  Future<bool> exists(BackupConfig config, String remotePath);

  Future<void> ensureDirectory(BackupConfig config);

  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  );

  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  );

  Future<void> deleteFile(BackupConfig config, String remotePath);
}

class _WebDavComicBackupOps implements ComicBackupWebDavOps {
  Client _client(BackupConfig config) {
    return config.endpoint.createClient();
  }

  @override
  Future<void> test(BackupConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<BackupFile>> list(BackupConfig config) async {
    final entries = await _client(config).readDir(config.remotePath);
    return entries
        .where((entry) => entry.isDir != true && entry.name != null)
        .map(
          (entry) => BackupFile(
            name: entry.name!,
            size: entry.size ?? 0,
            modified: entry.mTime ?? DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
  }

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async {
    final entries = await _client(config).readDir(config.remotePath);
    final name = remotePath.split('/').last;
    return entries.any((entry) => entry.name == name);
  }

  @override
  Future<void> ensureDirectory(BackupConfig config) async {
    await _client(config).mkdirAll(config.remotePath);
  }

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) async {
    await _client(config).writeFromFile(localPath, remotePath);
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) async {
    await _client(config).read2File(remotePath, localPath);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) async {
    await _client(config).remove(remotePath);
  }
}

class _RemoteComicBackupOps implements ComicBackupWebDavOps {
  static final _active = <RemoteFileStore>{};

  static Future<void> cancelActive() =>
      Future.wait(_active.map((store) => store.cancelAll()));

  Future<T> _run<T>(
    BackupConfig config,
    Future<T> Function(RemoteFileStore store) action,
  ) async {
    final accounts = RemoteStorageAccounts.instance;
    final store = accounts.storeFor(config.location!.accountId);
    _active.add(store);
    try {
      return await action(store);
    } finally {
      _active.remove(store);
      accounts.release(store);
    }
  }

  @override
  Future<void> test(BackupConfig config) =>
      _run(config, (store) => store.list(config.remotePath));

  @override
  Future<List<BackupFile>> list(BackupConfig config) async =>
      (await _run(config, (store) => store.list(config.remotePath)))
          .where((entry) => !entry.isDirectory)
          .map(
            (entry) => BackupFile(
              name: entry.name,
              size: entry.size ?? 0,
              modified: DateTime.fromMillisecondsSinceEpoch(
                entry.modifiedAt ?? 0,
              ),
            ),
          )
          .toList();

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async =>
      (await _run(
        config,
        (store) => store.list(config.remotePath),
      )).any((entry) => entry.name == remotePath.split('/').last);

  @override
  Future<void> ensureDirectory(BackupConfig config) =>
      _run(config, (store) => store.mkdir(config.remotePath));

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) => _run(config, (store) => store.upload(localPath, remotePath));

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) => _run(config, (store) => store.download(remotePath, localPath));

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) =>
      _run(config, (store) => store.delete(remotePath));
}

/// Aggregate result for backup and restore operations.
class BackupResult {
  const BackupResult({
    required this.success,
    required this.skipped,
    required this.failed,
    this.errors = const [],
  });

  final int success;
  final int skipped;
  final int failed;
  final List<String> errors;
}

/// Manager for WebDAV comic archive backup and restore operations.
class ComicBackupManager {
  const ComicBackupManager._();

  static ComicBackupWebDavOps ops = _WebDavComicBackupOps();
  static final ComicBackupWebDavOps _remoteOps = _RemoteComicBackupOps();

  static ComicBackupWebDavOps _opsFor(BackupConfig config) =>
      config.location == null ? ops : _remoteOps;

  static void resetOps() {
    ops = _WebDavComicBackupOps();
  }

  static Future<void> Function(LocalComic comic, String outputPath)?
  exportComic;

  static Future<LocalComic> Function(String filePath)? importComic;

  static Future<void> Function(LocalComic comic)? registerImportedComic;

  static BackupConfig get config => BackupConfig.fromSettings();
  static int _taskEpoch = 0;

  static Future<void> cancelActiveTasks() async {
    _taskEpoch++;
    await _RemoteComicBackupOps.cancelActive();
  }

  static Future<Res<bool>> testConnection(BackupConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      await _opsFor(config).test(config);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<BackupFile>>> listBackups() async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      final files = await _opsFor(config).list(config);
      final cbzFiles =
          files
              .where((file) => file.name.toLowerCase().endsWith('.cbz'))
              .map(
                (file) => BackupFile(
                  name: file.name,
                  size: file.size,
                  modified: file.modified,
                  targetIdentity: config.targetIdentity,
                ),
              )
              .toList()
            ..sort((a, b) => b.modified.compareTo(a.modified));
      return Res(cbzFiles);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<BackupResult> backup(
    List<LocalComic> comics, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final epoch = _taskEpoch;
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const BackupResult(
        success: 0,
        skipped: 0,
        failed: 1,
        errors: ['Invalid WebDAV archive configuration'],
      );
    }
    var success = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    try {
      await _opsFor(config).ensureDirectory(config);
    } catch (e) {
      return BackupResult(
        success: 0,
        skipped: 0,
        failed: comics.length,
        errors: [e.toString()],
      );
    }
    // 批量获取远端已有文件，避免逐本 PROPFIND
    final remoteFileNames = <String>{};
    var listSuccess = false;
    try {
      final remoteFiles = await _opsFor(config).list(config);
      for (final f in remoteFiles) {
        remoteFileNames.add(f.name);
      }
      listSuccess = true;
    } catch (_) {
      // 列表失败忽略，后续退化为逐本检查
    }
    for (var i = 0; i < comics.length; i++) {
      if (isCancelled?.call() == true || epoch != _taskEpoch) {
        await cancelActiveTasks();
        break;
      }
      final comic = comics[i];
      onProgress?.call(i + 1, comics.length, comic.title);
      final fileName = backupFileName(comic);
      final remotePath = config.remoteFilePath(fileName);
      final localPath = FilePath.join(
        App.cachePath,
        'comic_backup_${DateTime.now().microsecondsSinceEpoch}_$fileName',
      );
      final localFile = File(localPath);
      try {
        final exists = listSuccess
            ? remoteFileNames.contains(fileName)
            : await _opsFor(config).exists(config, remotePath);
        if (exists) {
          skipped++;
          continue;
        }
        final exporter = exportComic;
        if (exporter != null) {
          await exporter(comic, localPath);
        } else {
          await CBZ.export(comic, localPath);
        }
        if (isCancelled?.call() == true || epoch != _taskEpoch) {
          await cancelActiveTasks();
          break;
        }
        await _opsFor(config).uploadFile(config, localPath, remotePath);
        if (epoch != _taskEpoch) break;
        success++;
      } catch (e) {
        failed++;
        errors.add('${comic.title}: $e');
      } finally {
        await localFile.deleteIgnoreError();
      }
    }
    return BackupResult(
      success: success,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  static Future<BackupResult> restore(
    List<BackupFile> files, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final epoch = _taskEpoch;
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const BackupResult(
        success: 0,
        skipped: 0,
        failed: 1,
        errors: ['Invalid WebDAV archive configuration'],
      );
    }
    if (files.any(
      (file) =>
          file.targetIdentity != null &&
          file.targetIdentity != config.targetIdentity,
    )) {
      return BackupResult(
        success: 0,
        skipped: 0,
        failed: files.length,
        errors: const ['Backup target changed. Refresh the archive list.'],
      );
    }
    var success = 0;
    var failed = 0;
    final errors = <String>[];
    return await LocalComicStorageGuard.instance.runImport(() async {
      for (var i = 0; i < files.length; i++) {
        if (isCancelled?.call() == true || epoch != _taskEpoch) {
          await cancelActiveTasks();
          break;
        }
        final backup = files[i];
        onProgress?.call(i + 1, files.length, backup.name);
        final remotePath = config.remoteFilePath(backup.name);
        final localPath = FilePath.join(
          App.cachePath,
          'comic_restore_${DateTime.now().microsecondsSinceEpoch}_${backup.name}',
        );
        final localFile = File(localPath);
        try {
          await _opsFor(config).downloadFile(config, remotePath, localPath);
          if (epoch != _taskEpoch) break;
          late LocalComic comic;
          final importer = importComic;
          if (importer != null) {
            comic = await importer(localPath);
          } else {
            comic = await CBZ.import(localFile);
          }
          final register = registerImportedComic;
          if (register != null) {
            await register(comic);
          } else {
            LocalManager().add(
              comic,
              LocalManager().findValidId(comic.comicType),
            );
          }
          success++;
        } catch (e) {
          failed++;
          errors.add('${backup.name}: $e');
        } finally {
          await localFile.deleteIgnoreError();
        }
      }
      return BackupResult(
        success: success,
        skipped: 0,
        failed: failed,
        errors: errors,
      );
    });
  }

  static Future<Res<bool>> deleteBackup(BackupFile file) async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    if (file.targetIdentity != null &&
        file.targetIdentity != config.targetIdentity) {
      return const Res.error(
        'Backup target changed. Refresh the archive list.',
      );
    }
    try {
      await _opsFor(
        config,
      ).deleteFile(config, config.remoteFilePath(file.name));
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static String backupFileName(LocalComic comic) {
    final name = sanitizeFileName(
      comic.title,
      maxLength: maxSanitizedFileNameLength,
    );
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}';
    return '${name}_$timestamp.cbz';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
