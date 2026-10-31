import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/local_comics/local_storage_migration.dart';

void main() {
  late Directory root, source, destination;
  late File pathFile;
  late Database db;
  late String published;

  setUp(() {
    root = Directory.systemTemp.createTempSync('local-move-');
    source = Directory('${root.path}/old')..createSync();
    destination = Directory('${root.path}/new')..createSync();
    File('${source.path}/page.png').writeAsStringSync('page');
    pathFile = File('${root.path}/local_path')..writeAsStringSync(source.path);
    published = source.path;
    db = sqlite3.open('${root.path}/local.db');
    db.execute(
      'CREATE TABLE comics (id TEXT, comic_type INTEGER, directory TEXT)',
    );
    db.execute('INSERT INTO comics VALUES (?, 0, ?), (?, 0, ?), (?, 0, ?)', [
      'owned',
      '${source.path}/book',
      'relative',
      'book',
      'external',
      '${root.path}/external',
    ]);
  });
  tearDown(() {
    db.close();
    root.deleteSync(recursive: true);
  });

  LocalStorageMigration migration({
    Future<void> Function(Directory)? clear,
    Future<void> Function()? persist,
  }) => LocalStorageMigration(
    db: db,
    pathFile: pathFile,
    publish: (_, path) => published = path,
    clear: clear,
    persistRelated: persist,
  );

  test(
    'commits the root and owned references before clearing the old copy',
    () async {
      await migration(
        persist: () async {
          expect(published, destination.path);
          expect(pathFile.readAsStringSync(), destination.path);
          expect(File('${source.path}/page.png').existsSync(), isTrue);
        },
      ).move(source, destination);
      expect(File('${destination.path}/page.png').readAsStringSync(), 'page');
      expect(source.listSync(), isEmpty);
      expect(
        db
            .select("SELECT directory FROM comics WHERE id = 'owned'")
            .single['directory'],
        '${destination.path}${Platform.pathSeparator}book',
      );
      expect(
        db
            .select("SELECT directory FROM comics WHERE id = 'relative'")
            .single['directory'],
        'book',
      );
      expect(
        db
            .select("SELECT directory FROM comics WHERE id = 'external'")
            .single['directory'],
        '${root.path}/external',
      );
      expect(db.select('SELECT * FROM local_storage_move'), isEmpty);
    },
  );

  test(
    'cleanup failure keeps the new root and recovers after reopening the database',
    () async {
      await migration(
        clear: (_) async => throw const FileSystemException('locked'),
      ).move(source, destination);
      expect(published, destination.path);
      expect(pathFile.readAsStringSync(), destination.path);
      expect(File('${source.path}/page.png').existsSync(), isTrue);
      expect(db.select('SELECT * FROM local_storage_move'), hasLength(1));
      db.close();
      db = sqlite3.open('${root.path}/local.db');
      expect(await migration().recover(), isTrue);
      expect(source.listSync(), isEmpty);
      expect(File('${destination.path}/page.png').existsSync(), isTrue);
    },
  );

  test(
    'checkpoint failure preserves both copies until related paths can be saved',
    () async {
      await expectLater(
        migration(
          persist: () async => throw const FileSystemException('checkpoint'),
        ).move(source, destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${source.path}/page.png').existsSync(), isTrue);
      expect(File('${destination.path}/page.png').existsSync(), isTrue);
      expect(db.select('SELECT * FROM local_storage_move'), hasLength(1));
      expect(await migration().recover(), isTrue);
      expect(published, destination.path);
    },
  );

  test(
    'overlapping directories are rejected before copying or changing references',
    () async {
      final child = Directory('${source.path}/nested')..createSync();
      await expectLater(
        migration().move(source, child),
        throwsA(isA<FileSystemException>()),
      );
      expect(pathFile.readAsStringSync(), source.path);
      expect(File('${source.path}/page.png').readAsStringSync(), 'page');
      expect(child.listSync(), isEmpty);
    },
  );
}
