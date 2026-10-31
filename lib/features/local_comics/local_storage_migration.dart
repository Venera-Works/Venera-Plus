import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';

/// The database journal commits the new root and owned absolute references
/// together. Both copies survive until that root has also been saved to disk.
class LocalStorageMigration {
  LocalStorageMigration({
    required this.db,
    required this.pathFile,
    required this.publish,
    this.persistRelated,
    Future<void> Function(Directory, Directory)? copy,
    Future<void> Function(Directory)? clear,
  }) : copy = copy ?? copyDirectoryIsolate,
       clear =
           clear ?? ((directory) => directory.deleteContents(recursive: true));

  final Database db;
  final File pathFile;
  final void Function(String source, String destination) publish;
  final Future<void> Function()? persistRelated;
  final Future<void> Function(Directory, Directory) copy;
  final Future<void> Function(Directory) clear;

  void _ensureTable() => db.execute('''
    CREATE TABLE IF NOT EXISTS local_storage_move (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      source TEXT NOT NULL,
      destination TEXT NOT NULL
    );
  ''');

  Future<void> _savePath(String path) async {
    final temporary = File('${pathFile.path}.new');
    await temporary.writeAsString(path, flush: true);
    await temporary.rename(pathFile.path);
  }

  Future<bool> recover() async {
    _ensureTable();
    final rows = db.select(
      'SELECT source, destination FROM local_storage_move',
    );
    if (rows.isEmpty) return true;
    final source = rows.single['source'] as String;
    final destination = rows.single['destination'] as String;
    if (p.equals(source, destination) ||
        p.isWithin(source, destination) ||
        p.isWithin(destination, source)) {
      throw const FormatException('Invalid local storage relocation');
    }
    if (!await Directory(destination).exists()) {
      throw FileSystemException(
        'The relocated comic directory is unavailable. Both copies were kept.',
        destination,
      );
    }
    publish(source, destination);
    await _savePath(destination);
    await persistRelated?.call();
    try {
      await clear(Directory(source));
    } catch (error, stack) {
      Log.error('Local storage cleanup', error, stack);
      return false;
    }
    db.execute('DELETE FROM local_storage_move WHERE id = 1');
    return true;
  }

  Future<void> move(Directory source, Directory destination) async {
    if (!await recover()) {
      throw StateError(
        'Finish the previous library cleanup before moving again.',
      );
    }
    final sourcePath = await _canonical(source);
    final destinationPath = await _canonical(destination);
    if (p.equals(sourcePath, destinationPath) ||
        p.isWithin(sourcePath, destinationPath) ||
        p.isWithin(destinationPath, sourcePath)) {
      throw const FileSystemException(
        'Source and destination directories must not overlap',
      );
    }
    if (!await destination.list().isEmpty) {
      throw const FileSystemException('Directory is not empty');
    }
    await copy(source, destination);
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in db.select(
        'SELECT id, comic_type, directory FROM comics',
      )) {
        final directory = row['directory'] as String;
        if (p.isWithin(source.path, directory)) {
          db.execute(
            'UPDATE comics SET directory = ? WHERE id = ? AND comic_type = ?',
            [
              p.join(
                destination.path,
                p.relative(directory, from: source.path),
              ),
              row['id'],
              row['comic_type'],
            ],
          );
        }
      }
      db.execute(
        'INSERT INTO local_storage_move (id, source, destination) VALUES (1, ?, ?)',
        [source.path, destination.path],
      );
      db.execute('COMMIT');
    } catch (error, stack) {
      if (!db.autocommit) {
        db.execute('ROLLBACK');
      } else {
        // A failed COMMIT acknowledgement can still leave a committed root.
        try {
          await recover();
        } catch (recoveryError, recoveryStack) {
          Log.error('Local storage recovery', recoveryError, recoveryStack);
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
    publish(source.path, destination.path);
    await recover();
  }

  static Future<String> _canonical(Directory directory) =>
      directory.path.startsWith('android://') ||
          directory.path.startsWith('content://')
      ? Future.value(p.normalize(directory.path))
      : directory.resolveSymbolicLinks();
}
