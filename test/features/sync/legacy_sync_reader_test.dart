import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZipFile;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:zip_flutter/zip_flutter.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

const bool _ciRequireQuickJs = bool.fromEnvironment(
  'CI_REQUIRE_QUICKJS',
  defaultValue: false,
);
const bool _ciRequireNativeZip = bool.fromEnvironment(
  'CI_REQUIRE_NATIVE_ZIP',
  defaultValue: false,
);

String? _nativeZipLoadFailure() {
  final libraryPath = Platform.isWindows
      ? 'zip_flutter.dll'
      : Platform.isLinux
      ? 'libzip_flutter.so'
      : 'zip_flutter.framework/zip_flutter';
  try {
    if (Platform.isWindows) {
      for (final buildDir in [
        'build/windows/x64/runner/Debug',
        'build/windows/x64/runner/Release',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/zip_flutter.dll').existsSync()) {
          DynamicLibrary.open('$build/zip_flutter.dll');
          break;
        }
      }
    } else if (Platform.isLinux) {
      for (final buildDir in [
        'build/linux/x64/debug/bundle/lib',
        'build/linux/x64/release/bundle/lib',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/libzip_flutter.so').existsSync()) {
          DynamicLibrary.open('$build/libzip_flutter.so');
          break;
        }
      }
    }
    DynamicLibrary.open(libraryPath);
    return null;
  } catch (error) {
    return '$libraryPath: $error';
  }
}

String? _quickJsLoadFailure() {
  final libraryPath = Platform.isWindows
      ? 'flutter_qjs_plugin.dll'
      : Platform.isLinux
      ? 'libflutter_qjs_plugin.so'
      : 'flutter_qjs.framework/flutter_qjs';
  try {
    if (Platform.isWindows) {
      for (final buildDir in [
        'build/windows/x64/runner/Debug',
        'build/windows/x64/runner/Release',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/flutter_windows.dll').existsSync() &&
            File('$build/flutter_qjs_plugin.dll').existsSync()) {
          DynamicLibrary.open('$build/flutter_windows.dll');
          DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
          break;
        }
      }
    } else if (Platform.isLinux) {
      for (final buildDir in [
        'build/linux/x64/debug/bundle/lib',
        'build/linux/x64/release/bundle/lib',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/libflutter_qjs_plugin.so').existsSync()) {
          DynamicLibrary.open('$build/libflutter_qjs_plugin.so');
          break;
        }
      }
    }
    DynamicLibrary.open(libraryPath);
    return null;
  } catch (error) {
    return '$libraryPath: $error';
  }
}

int _holdNoDeleteHandle(String filePath) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getProcessHeap = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
  final heapAlloc = kernel32
      .lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)
      >('HeapAlloc');
  final heapFree = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('HeapFree');
  final createFileW = kernel32
      .lookupFunction<
        IntPtr Function(
          Pointer<Uint16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');

  final heap = getProcessHeap();
  final units = filePath.codeUnits;
  final memory = heapAlloc(heap, 0, (units.length + 1) * 2);
  if (memory == nullptr) {
    throw StateError('Could not allocate Windows path');
  }
  final pathUnits = memory.cast<Uint16>().asTypedList(units.length + 1);
  pathUnits.setRange(0, units.length, units);
  pathUnits[units.length] = 0;
  final handle = createFileW(
    memory.cast<Uint16>(),
    0x80000000, // GENERIC_READ
    0x00000001 | 0x00000002, // FILE_SHARE_READ | FILE_SHARE_WRITE
    nullptr,
    3, // OPEN_EXISTING
    0x80, // FILE_ATTRIBUTE_NORMAL
    0,
  );
  heapFree(heap, 0, memory);
  if (handle == -1 || handle == 0) {
    throw StateError('CreateFileW failed for $filePath');
  }
  return handle;
}

void _closeWindowsHandle(int handle) {
  DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle')(
    handle,
  );
}

class _TestDavClient extends dav.Client {
  _TestDavClient(this.transport)
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(httpAdapter: transport),
        auth: dav.Auth(user: 'user', pwd: 'pass'),
      );

  final _TestDavTransport transport;
  final List<String> readDirPaths = [];
  List<dav.File> remoteFiles = [];
  Future<List<dav.File>> Function(String path)? onReadDir;

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    readDirPaths.add(path);
    if (onReadDir != null) {
      return onReadDir!(path);
    }
    return List.of(remoteFiles);
  }
}

class _TestDavTransport implements HttpClientAdapter {
  final Map<String, Uint8List> files = {};
  final Map<String, String?> getEtags = {};
  final Map<String, int> getStatusCodes = {};
  final Map<String, Stream<Uint8List>> downloadStreams = {};
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final filename = options.uri.pathSegments.isNotEmpty
        ? options.uri.pathSegments.last
        : '';

    if (options.method == 'GET') {
      final statusCode = getStatusCodes[filename] ?? 200;
      final bytes = files[filename] ?? Uint8List(0);
      final etag = getEtags[filename];
      final stream = downloadStreams[filename];
      if (stream != null) {
        return ResponseBody(stream, statusCode);
      }

      return ResponseBody.fromBytes(
        bytes,
        statusCode,
        headers: {
          if (etag != null) 'etag': [etag],
        },
      );
    }
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _createVeneraArchive({
  List<int>? historyDbBytes,
  List<int>? localFavoriteDbBytes,
  String? appdataJson,
  Map<String, String>? comicSources,
  List<ArchiveFile>? extraFiles,
  bool stored = false,
}) {
  final archive = Archive();
  if (historyDbBytes != null) {
    archive.addFile(
      ArchiveFile('history.db', historyDbBytes.length, historyDbBytes),
    );
  }
  if (localFavoriteDbBytes != null) {
    archive.addFile(
      ArchiveFile(
        'local_favorite.db',
        localFavoriteDbBytes.length,
        localFavoriteDbBytes,
      ),
    );
  }
  if (appdataJson != null) {
    final bytes = utf8.encode(appdataJson);
    archive.addFile(ArchiveFile('appdata.json', bytes.length, bytes));
  }
  if (comicSources != null) {
    for (final e in comicSources.entries) {
      final bytes = utf8.encode(e.value);
      archive.addFile(
        ArchiveFile('comic_source/${e.key}', bytes.length, bytes),
      );
    }
  }
  if (extraFiles != null) {
    for (final f in extraFiles) {
      archive.addFile(f);
    }
  }
  if (stored) {
    for (final file in archive.files) {
      file.compression = CompressionType.none;
    }
  }
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

Uint8List? _createFavoriteDbBytes(
  Directory tempDir, {
  bool includeMissingColumns = false,
}) {
  if (!_sqliteAvailable()) return null;
  final dbFile = File(
    p.join(
      tempDir.path,
      'seed_fav_${DateTime.now().microsecondsSinceEpoch}.db',
    ),
  );
  final db = sqlite3.open(dbFile.path);
  try {
    FavoriteSyncData.ensureFolderMetadataTable(db);
    db.execute('''
      INSERT INTO folder_metadata (folder_id, folder_name, logical_name, order_value)
      VALUES ('legacy-folder-1', 'Comics', 'Comics', 0);
    ''');

    if (includeMissingColumns) {
      // Legacy schema missing display_order, last_update_time, has_new_update, translated_tags
      db.execute('''
        CREATE TABLE "Comics" (
          id TEXT PRIMARY KEY,
          name TEXT,
          author TEXT,
          type INT,
          tags TEXT,
          cover_path TEXT,
          time TEXT
        );
      ''');
      db.execute('''
        INSERT INTO "Comics" (id, name, author, type, tags, cover_path, time)
        VALUES ('comic1', 'Comic One', 'Author A', 1, 'tag1', 'cover.jpg', '2026-01-01');
      ''');
    } else {
      db.execute('''
        CREATE TABLE "Comics" (
          id TEXT PRIMARY KEY,
          title TEXT,
          sub_title TEXT,
          cover TEXT,
          time TEXT,
          tags TEXT,
          author TEXT,
          type INT,
          max_page INT,
          display_order INT
        );
      ''');
      db.execute('''
        INSERT INTO "Comics" (id, title, sub_title, cover, time, tags, author, type, max_page, display_order)
        VALUES ('comic1', 'Comic One', 'Ep 1', 'cover.jpg', '2026-01-01', 'tag1', 'Author A', 1, 100, 1);
      ''');
    }
  } finally {
    db.dispose();
  }
  final bytes = dbFile.readAsBytesSync();
  try {
    dbFile.deleteSync();
  } catch (_) {}
  return bytes;
}

Uint8List? _createHistoryDbBytes(Directory tempDir) {
  if (!_sqliteAvailable()) return null;
  final dbFile = File(
    p.join(
      tempDir.path,
      'seed_hist_${DateTime.now().microsecondsSinceEpoch}.db',
    ),
  );
  final db = sqlite3.open(dbFile.path);
  try {
    HistorySyncData.ensureSchema(db);
    db.execute('''
      INSERT INTO history (id, type, title, subtitle, cover, time, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
      VALUES ('hist1', 1, 'Hist Title', 'Ep 1', 'cover.jpg', 1700000000000, 1, 5, '1,2', 100, 0, 120000);
    ''');
  } finally {
    db.dispose();
  }
  final bytes = dbFile.readAsBytesSync();
  try {
    dbFile.deleteSync();
  } catch (_) {}
  return bytes;
}

Uint8List _createCustomDescriptorArchive({
  required String filename,
  required List<int> content,
  required int descriptorType,
  int? overrideCrc,
}) {
  final nameBytes = utf8.encode(filename);
  final contentBytes = Uint8List.fromList(content);
  final uncompSize = contentBytes.length;
  final compSize = contentBytes.length;
  final crc = overrideCrc ?? getCrc32(contentBytes);

  final builder = BytesBuilder();

  final isBit3 = descriptorType != 5;
  final localFlags = isBit3 ? 0x0008 : 0x0000;
  final localCrc = descriptorType == 6 ? (crc ^ 0x9999) : (isBit3 ? 0 : crc);
  final localComp = descriptorType == 5 ? 0xffffffff : (isBit3 ? 0 : compSize);
  final localUncomp = descriptorType == 5
      ? 0xffffffff
      : (isBit3 ? 0 : uncompSize);

  Uint8List localExtra = Uint8List(0);
  if (descriptorType == 5) {
    final extraData = ByteData(20);
    extraData.setUint16(0, 0x0001, Endian.little);
    extraData.setUint16(2, 16, Endian.little);
    extraData.setUint64(4, 99999, Endian.little);
    extraData.setUint64(12, 99999, Endian.little);
    localExtra = extraData.buffer.asUint8List();
  }

  final localHeader = ByteData(30);
  localHeader.setUint32(0, 0x04034b50, Endian.little);
  localHeader.setUint16(4, 20, Endian.little);
  localHeader.setUint16(6, localFlags, Endian.little);
  localHeader.setUint16(8, 0, Endian.little);
  localHeader.setUint16(10, 0, Endian.little);
  localHeader.setUint16(12, 0, Endian.little);
  localHeader.setUint32(14, localCrc, Endian.little);
  localHeader.setUint32(18, localComp, Endian.little);
  localHeader.setUint32(22, localUncomp, Endian.little);
  localHeader.setUint16(26, nameBytes.length, Endian.little);
  localHeader.setUint16(28, localExtra.length, Endian.little);

  builder.add(localHeader.buffer.asUint8List());
  builder.add(nameBytes);
  if (localExtra.isNotEmpty) {
    builder.add(localExtra);
  }
  builder.add(contentBytes);

  if (isBit3) {
    if (descriptorType == 0 || descriptorType == 6) {
      final desc = ByteData(16);
      desc.setUint32(0, 0x08074b50, Endian.little);
      desc.setUint32(4, crc, Endian.little);
      desc.setUint32(8, compSize, Endian.little);
      desc.setUint32(12, uncompSize, Endian.little);
      builder.add(desc.buffer.asUint8List());
    } else if (descriptorType == 1) {
      final desc = ByteData(24);
      desc.setUint32(0, 0x08074b50, Endian.little);
      desc.setUint32(4, crc, Endian.little);
      desc.setUint64(8, compSize, Endian.little);
      desc.setUint64(16, uncompSize, Endian.little);
      builder.add(desc.buffer.asUint8List());
    } else if (descriptorType == 2) {
      final desc = ByteData(20);
      desc.setUint32(0, crc, Endian.little);
      desc.setUint64(4, compSize, Endian.little);
      desc.setUint64(12, uncompSize, Endian.little);
      builder.add(desc.buffer.asUint8List());
    } else if (descriptorType == 3) {
      final desc = ByteData(12);
      desc.setUint32(0, crc, Endian.little);
      desc.setUint32(4, compSize, Endian.little);
      desc.setUint32(8, uncompSize, Endian.little);
      builder.add(desc.buffer.asUint8List());
    } else if (descriptorType == 4) {
      final desc = ByteData(24);
      desc.setUint32(0, 0x08074b50, Endian.little);
      desc.setUint32(4, crc, Endian.little);
      desc.setUint32(8, 0, Endian.little);
      desc.setUint32(12, 0, Endian.little);
      desc.setUint64(16, 0x12345678, Endian.little);
      builder.add(desc.buffer.asUint8List());
    }
  }

  final centralDirOffset = builder.length;

  final cdHeader = ByteData(46);
  cdHeader.setUint32(0, 0x02014b50, Endian.little);
  cdHeader.setUint16(4, 20, Endian.little);
  cdHeader.setUint16(6, 20, Endian.little);
  cdHeader.setUint16(8, localFlags, Endian.little);
  cdHeader.setUint16(10, 0, Endian.little);
  cdHeader.setUint16(12, 0, Endian.little);
  cdHeader.setUint16(14, 0, Endian.little);
  cdHeader.setUint32(16, crc, Endian.little);
  cdHeader.setUint32(20, compSize, Endian.little);
  cdHeader.setUint32(24, uncompSize, Endian.little);
  cdHeader.setUint16(28, nameBytes.length, Endian.little);
  cdHeader.setUint16(30, 0, Endian.little);
  cdHeader.setUint16(32, 0, Endian.little);
  cdHeader.setUint16(34, 0, Endian.little);
  cdHeader.setUint16(36, 0, Endian.little);
  cdHeader.setUint32(38, 0, Endian.little);
  cdHeader.setUint32(42, 0, Endian.little);
  builder.add(cdHeader.buffer.asUint8List());
  builder.add(nameBytes);

  final centralDirSize = builder.length - centralDirOffset;

  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, 1, Endian.little);
  eocd.setUint16(10, 1, Endian.little);
  eocd.setUint32(12, centralDirSize, Endian.little);
  eocd.setUint32(16, centralDirOffset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);
  builder.add(eocd.buffer.asUint8List());

  return builder.toBytes();
}

void main() {
  final quickJsFailure = _quickJsLoadFailure();
  final quickJsAvailable = quickJsFailure == null;
  final nativeZipFailure = _nativeZipLoadFailure();
  final nativeZipAvailable = nativeZipFailure == null;

  late Directory tempDir;
  late Directory scratchDir;
  late String originalDataPath;
  late SyncPreferencesAdapter preferences;
  late _TestDavTransport transport;
  late _TestDavClient client;

  setUpAll(() {
    JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
    _sqliteAvailable();
    try {
      originalDataPath = App.dataPath;
    } catch (_) {
      originalDataPath = Directory.systemTemp.path;
    }
  });

  tearDownAll(() {
    App.dataPath = originalDataPath;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera-legacy-test-');
    scratchDir = Directory(p.join(tempDir.path, 'scratch'))
      ..createSync(recursive: true);
    App.dataPath = p.join(tempDir.path, 'live_data');
    App.version = '9.0.0';
    Directory(App.dataPath).createSync(recursive: true);

    preferences = SyncPreferencesAdapter(dataPath: App.dataPath);
    transport = _TestDavTransport();
    client = _TestDavClient(transport);
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('LegacySyncReader Snapshot Discovery and Version Filtering', () {
    test(
      'lists only legal direct-root backups in stable numeric order',
      () async {
        client.remoteFiles = [
          dav.File(path: '/8-10.venera', name: '8-10.venera', isDir: false),
          dav.File(path: '/2-10.venera', name: '2-10.venera', isDir: false),
          dav.File(path: '/08-10.venera', name: '08-10.venera', isDir: false),
          dav.File(path: '/10-2.venera', name: '10-2.venera', isDir: false),
          dav.File(name: '31-9.venera', isDir: false),
          dav.File(
            path: '/nested/20-10.venera',
            name: '20-10.venera',
            isDir: false,
          ),
          dav.File(path: '/99-20.venera', name: '99-20.venera', isDir: true),
          dav.File(path: '/bad-30.venera', name: 'bad-30.venera', isDir: false),
          dav.File(
            path: '/40-30.venera.bak',
            name: '40-30.venera.bak',
            isDir: false,
          ),
          dav.File(path: '/100-20.venera', name: '100-20.venera'),
        ];

        final backups = await LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        ).listBackups();

        expect(backups.map((backup) => backup.name), [
          '08-10.venera',
          '8-10.venera',
          '2-10.venera',
          '31-9.venera',
          '10-2.venera',
        ]);
        expect(backups.first.day, 8);
        expect(backups.first.version, 10);
        expect(client.readDirPaths, ['/']);
        expect(transport.requests, isEmpty);
      },
    );

    test(
      'keeps same-day spellings; explicit selection reads an older backup',
      () async {
        final archiveA = _createVeneraArchive(
          appdataJson: '{"settings":{"choice":"leading-zero"}}',
        );
        final archiveB = _createVeneraArchive(
          appdataJson: '{"settings":{"choice":"plain"}}',
        );
        final olderArchive = _createVeneraArchive(
          appdataJson: '{"settings":{"choice":"older-version"}}',
        );
        transport.files['042-7.venera'] = archiveA;
        transport.files['42-7.venera'] = archiveB;
        transport.files['500-6.venera'] = olderArchive;
        client.remoteFiles = [
          dav.File(name: '042-7.venera', isDir: false),
          dav.File(name: '42-7.venera', isDir: false),
          dav.File(name: '500-6.venera', isDir: false),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final automaticSeeds = await reader.readSeeds();

        expect(automaticSeeds, hasLength(2));
        expect(
          automaticSeeds.map((seed) => seed.id),
          containsAll([
            sha256.convert(archiveA).toString(),
            sha256.convert(archiveB).toString(),
          ]),
        );

        final selectedSeeds = await reader.readSeeds(
          backupName: '500-6.venera',
        );
        expect(selectedSeeds, hasLength(1));
        expect(
          selectedSeeds.single.id,
          sha256.convert(olderArchive).toString(),
        );

        final previouslyListed = await reader.listBackups();
        expect(
          previouslyListed.map((backup) => backup.name),
          contains('500-6.venera'),
        );
        client.remoteFiles = [
          dav.File(name: '042-7.venera', isDir: false),
          dav.File(name: '42-7.venera', isDir: false),
        ];
        final getCountBeforeStaleSelection = transport.requests
            .where((request) => request.method == 'GET')
            .length;
        await expectLater(
          reader.readSeeds(backupName: '500-6.venera'),
          throwsA(isA<FormatException>()),
        );
        expect(
          transport.requests.where((request) => request.method == 'GET'),
          hasLength(getCountBeforeStaleSelection),
        );
        await expectLater(
          reader.readSeeds(backupName: '../42-7.venera'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'explicitly selected remote backup reports HTTP 404 instead of falling back',
      () async {
        transport.getStatusCodes['50-2.venera'] = 404;
        transport.files['51-3.venera'] = _createVeneraArchive(
          appdataJson: '{"settings":{"fallback":"must-not-be-read"}}',
        );
        client.remoteFiles = [
          dav.File(name: '50-2.venera', isDir: false),
          dav.File(name: '51-3.venera', isDir: false),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        await expectLater(
          reader.readSeeds(backupName: '50-2.venera'),
          throwsA(isA<StateError>()),
        );
        final getRequests = transport.requests.where(
          (request) => request.method == 'GET',
        );
        expect(getRequests, hasLength(1));
        expect(getRequests.single.uri.pathSegments.last, '50-2.venera');
      },
    );

    test(
      'ignores outdated legacy files when higher version exists, processes only newest version',
      () async {
        final archiveV4 = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'testKey': 'oldVersionValue'},
          }),
        );
        final archiveV5 = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'testKey': 'newestVersionValue'},
          }),
        );

        transport.files['100-3.venera'] = archiveV4;
        transport.files['101-4.venera'] = archiveV4;
        transport.files['102-5.venera'] = archiveV5;

        client.remoteFiles = [
          dav.File(name: '100-3.venera', isDir: false),
          dav.File(name: '101-4.venera', isDir: false),
          dav.File(name: '102-5.venera', isDir: false),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final expectedDigest = sha256
            .convert(archiveV5)
            .toString()
            .toLowerCase();
        expect(seeds.first.id, equals(expectedDigest));
        expect(
          seeds.first.records[syncRecordKey('setting', ['testKey'])],
          equals({'value': 'newestVersionValue'}),
        );
        expect(
          transport.requests.every((request) => request.method == 'GET'),
          isTrue,
          reason:
              'Legacy archives, including predecessors, must never be deleted',
        );
        expect(
          transport.files.keys,
          containsAll(['100-3.venera', '101-4.venera', '102-5.venera']),
        );
      },
    );

    test(
      'same-version cloud collisions retain BOTH snapshots as separate seeds',
      () async {
        final archiveA = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'actor': 'deviceA'},
          }),
        );
        final archiveB = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'actor': 'deviceB'},
          }),
        );

        transport.files['20000-5.venera'] = archiveA;
        transport.files['20001-5.venera'] = archiveB;

        client.remoteFiles = [
          dav.File(name: '20000-5.venera', isDir: false),
          dav.File(name: '20001-5.venera', isDir: false),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(2));
        final idA = sha256.convert(archiveA).toString().toLowerCase();
        final idB = sha256.convert(archiveB).toString().toLowerCase();
        final ids = seeds.map((s) => s.id).toSet();
        expect(ids, contains(idA));
        expect(ids, contains(idB));

        final seedA = seeds.firstWhere((s) => s.id == idA);
        final seedB = seeds.firstWhere((s) => s.id == idB);
        expect(
          seedA.records[syncRecordKey('setting', ['actor'])],
          equals({'value': 'deviceA'}),
        );
        expect(
          seedB.records[syncRecordKey('setting', ['actor'])],
          equals({'value': 'deviceB'}),
        );
      },
    );

    test(
      'returns empty list when root directory has no .venera files',
      () async {
        client.remoteFiles = [
          dav.File(name: 'other.txt', isDir: false),
          dav.File(name: 'subfolder', isDir: true),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();
        expect(seeds, isEmpty);
      },
    );

    test(
      'network error or 401 on listing root directory explicitly throws and aborts',
      () async {
        client.onReadDir = (path) async {
          throw DioException(
            requestOptions: RequestOptions(path: path),
            type: DioExceptionType.badResponse,
            response: Response(
              statusCode: 401,
              requestOptions: RequestOptions(path: path),
            ),
          );
        };

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        // Must throw so coordinator does not mark migration done
        await expectLater(reader.readSeeds(), throwsA(isA<DioException>()));
      },
    );
  });

  group('LegacySyncReader ETag and Directory Metadata Consistency', () {
    test('valid root ZIP without any ETag remains readable', () async {
      final archiveBytes = _createVeneraArchive(
        appdataJson: '{"settings":{"etag":"absent"}}',
      );
      transport.files['100-1.venera'] = archiveBytes;
      client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];

      final seeds = await LegacySyncReader(
        client,
        scratchDir,
        preferences: preferences,
      ).readSeeds();

      expect(seeds.single.id, sha256.convert(archiveBytes).toString());
      expect(transport.requests.single.headers['If-Match'], isNull);
    });

    test(
      'strong PROPFIND ETag with missing GET ETag is NOT rejected (success)',
      () async {
        final archiveBytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'key': 'val'},
          }),
        );
        transport.files['100-1.venera'] = archiveBytes;
        transport.getEtags['100-1.venera'] = null; // GET response lacks ETag

        client.remoteFiles = [
          dav.File(
            name: '100-1.venera',
            isDir: false,
            eTag: '"strong-etag-123"',
          ),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        expect(
          seeds.first.id,
          equals(sha256.convert(archiveBytes).toString().toLowerCase()),
        );
      },
    );

    test(
      'GET providing different strong ETag than PROPFIND throws StateError and aborts',
      () async {
        final archiveBytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'key': 'val'},
          }),
        );
        transport.files['100-1.venera'] = archiveBytes;
        transport.getEtags['100-1.venera'] = '"different-get-etag"';

        client.remoteFiles = [
          dav.File(
            name: '100-1.venera',
            isDir: false,
            eTag: '"original-propfind-etag"',
          ),
        ];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<StateError>()));
      },
    );

    test(
      'post-download directory metadata change throws StateError and aborts',
      () async {
        final archiveBytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'key': 'val'},
          }),
        );
        transport.files['100-1.venera'] = archiveBytes;

        var listCallCount = 0;
        client.onReadDir = (path) async {
          listCallCount++;
          if (listCallCount == 1) {
            return [
              dav.File(
                name: '100-1.venera',
                isDir: false,
                eTag: '"etag-phase-1"',
              ),
            ];
          } else {
            return [
              dav.File(
                name: '100-1.venera',
                isDir: false,
                eTag: '"etag-phase-2-changed"',
              ),
            ];
          }
        };

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<StateError>()));
      },
    );
  });

  test(
    'real loopback DAV redirect without GET ETag retains a valid ZIP',
    () async {
      final archive = _createVeneraArchive(
        appdataJson: '{"settings":{"testKey":"loopback"}}',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final subscription = server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.method == 'PROPFIND') {
          await request.drain<void>();
          request.response
            ..statusCode = 207
            ..headers.contentType = ContentType('application', 'xml')
            ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat>
    <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
  <d:response><d:href>/dav/100-1.venera</d:href><d:propstat>
    <d:prop><d:resourcetype/><d:getcontentlength>${archive.length}</d:getcontentlength>
      <d:getetag>"stable"</d:getetag></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
</d:multistatus>''');
        } else if (request.uri.path == '/dav/100-1.venera') {
          expect(request.headers.value('if-match'), '"stable"');
          request.response
            ..statusCode = 302
            ..headers.set(HttpHeaders.locationHeader, '/payload');
        } else if (request.uri.path == '/payload') {
          request.response
            ..statusCode = 200
            ..add(archive);
        } else {
          request.response.statusCode = 405;
        }
        await request.response.close();
      });
      final networkClient = dav.Client(
        uri: 'http://${server.address.address}:${server.port}/dav/',
        c: dav.WdDio(),
        auth: dav.Auth(user: 'test', pwd: 'test'),
      );
      try {
        final reader = LegacySyncReader(
          networkClient,
          scratchDir,
          preferences: preferences,
        );
        final automaticSeeds = await reader.readSeeds();
        expect(automaticSeeds.single.id, sha256.convert(archive).toString());
        expect(
          automaticSeeds.single.records[syncRecordKey('setting', ['testKey'])],
          {'value': 'loopback'},
        );
        final backups = await reader.listBackups();
        expect(backups.map((backup) => backup.name), ['100-1.venera']);
        final selectedSeeds = await reader.readSeeds(
          backupName: backups.single.name,
        );
        expect(selectedSeeds.single.id, sha256.convert(archive).toString());
        expect(
          selectedSeeds.single.records[syncRecordKey('setting', ['testKey'])],
          {'value': 'loopback'},
        );
        expect(requests.where((r) => r.startsWith('PROPFIND')), hasLength(5));
        expect(requests.where((r) => r == 'GET /payload'), hasLength(2));
        expect(requests.any((r) => r.startsWith('DELETE')), isFalse);
      } finally {
        networkClient.c.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  group('LegacySyncReader Archive Security and Isolation', () {
    test(
      'valid JSON with corrupt stored ZIP payload aborts the complete seed set',
      () async {
        final good = _createVeneraArchive(
          appdataJson: '{"settings":{"testKey":"1"}}',
          stored: true,
        );
        final corrupt = Uint8List.fromList(good);
        final header = ByteData.sublistView(corrupt);
        final payloadOffset =
            30 +
            header.getUint16(26, Endian.little) +
            header.getUint16(28, Endian.little);
        final payload = utf8.decode(
          corrupt.sublist(
            payloadOffset,
            payloadOffset + header.getUint32(18, Endian.little),
          ),
        );
        corrupt[payloadOffset + payload.indexOf('"1"') + 1] = '2'.codeUnitAt(0);
        // Demonstrate structure and JSON remain valid despite a stale CRC.
        final decoded = ZipDecoder().decodeBytes(corrupt);
        expect(jsonDecode(utf8.decode(decoded.single.content)), {
          'settings': {'testKey': '2'},
        });
        transport.files['101-1.venera'] = good;
        transport.files['100-1.venera'] = corrupt;
        client.remoteFiles = [
          dav.File(name: '101-1.venera', isDir: false),
          dav.File(name: '100-1.venera', isDir: false),
        ];
        final live = File(p.join(App.dataPath, 'appdata.json'))
          ..writeAsStringSync('{"settings":{"testKey":"live"}}');
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<FormatException>()),
        );
        expect(live.readAsStringSync(), '{"settings":{"testKey":"live"}}');
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'wrong uncompressed size is rejected even when CRC and JSON are valid',
      () async {
        final bytes = _createVeneraArchive(
          appdataJson: '{"settings":{"testKey":"1"}}',
          stored: true,
        );
        final directory = ZipDirectory()..read(InputMemoryStream(bytes));
        final data = ByteData.sublistView(bytes);
        final size = directory.fileHeaders.single.uncompressedSize;
        data.setUint32(22, size + 1, Endian.little);
        data.setUint32(
          directory.centralDirectoryOffset + 24,
          size + 1,
          Endian.little,
        );
        transport.files['100-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<FormatException>()),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'actual DEFLATE expansion is bounded despite a false small size',
      () async {
        final bytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'testKey': List.filled(100000, 'x').join()},
          }),
        );
        final directory = ZipDirectory()..read(InputMemoryStream(bytes));
        final data = ByteData.sublistView(bytes);
        data.setUint32(22, 1, Endian.little);
        data.setUint32(directory.centralDirectoryOffset + 24, 1, Endian.little);
        transport.files['100-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<FormatException>()),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'symlink metadata is rejected before reading its compressed payload',
      () async {
        final bytes = _createVeneraArchive(appdataJson: '{"settings":{}}');
        final directory = ZipDirectory()..read(InputMemoryStream(bytes));
        final data = ByteData.sublistView(bytes);
        data.setUint16(
          directory.centralDirectoryOffset + 4,
          3 << 8,
          Endian.little,
        );
        data.setUint32(
          directory.centralDirectoryOffset + 38,
          0xa1ff << 16,
          Endian.little,
        );
        transport.files['100-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<FormatException>()),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test('oversized declared member fails before decompression', () async {
      final bytes = _createVeneraArchive(appdataJson: '{"settings":{}}');
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      final data = ByteData.sublistView(bytes);
      const size = 16 * 1024 * 1024 + 1;
      data.setUint32(22, size, Endian.little);
      data.setUint32(
        directory.centralDirectoryOffset + 24,
        size,
        Endian.little,
      );
      transport.files['100-1.venera'] = bytes;
      client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
      await expectLater(
        LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        ).readSeeds(),
        throwsA(isA<FormatException>()),
      );
      expect(scratchDir.listSync(), isEmpty);
    });

    test('post-download network error cannot return a partial seed', () async {
      transport.files['100-1.venera'] = _createVeneraArchive(
        appdataJson: '{"settings":{"testKey":"1"}}',
      );
      var listings = 0;
      client.onReadDir = (_) async {
        if (++listings == 1) {
          return [dav.File(name: '100-1.venera', isDir: false)];
        }
        throw const SocketException('metadata connection interrupted');
      };
      await expectLater(
        LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        ).readSeeds(),
        throwsA(isA<SocketException>()),
      );
      expect(scratchDir.listSync(), isEmpty);
    });

    test(
      'interrupted download throws and cleans scratch without touching live files',
      () async {
        Stream<Uint8List> interrupted() async* {
          yield Uint8List.fromList([0x50, 0x4b]);
          throw const SocketException('download interrupted');
        }

        transport.downloadStreams['100-1.venera'] = interrupted();
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        final live = File(p.join(App.dataPath, 'appdata.json'))
          ..writeAsStringSync('live sentinel');
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(anything),
        );
        expect(live.readAsStringSync(), 'live sentinel');
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    for (final invalid in [
      '[]',
      '{"settings":[]}',
      '{"searchHistory":{}}',
      '{"searchHistory":[1]}',
    ]) {
      test('wrong legacy JSON schema aborts migration: $invalid', () async {
        transport.files['100-1.venera'] = _createVeneraArchive(
          appdataJson: invalid,
        );
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<FormatException>()),
        );
        expect(scratchDir.listSync(), isEmpty);
      });
    }

    test(
      'corrupt isolated SQL cannot return preferences or touch live DB',
      () async {
        if (!_sqliteAvailable()) return;
        transport.files['100-1.venera'] = _createVeneraArchive(
          historyDbBytes: utf8.encode('not a SQLite database'),
          appdataJson: '{"settings":{"testKey":"remote"}}',
        );
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];
        final live = File(p.join(App.dataPath, 'history.db'))
          ..writeAsStringSync('live sentinel');
        await expectLater(
          LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds(),
          throwsA(isA<SqliteException>()),
        );
        expect(live.readAsStringSync(), 'live sentinel');
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'corrupt ZIP archive throws FormatException and does not modify live state',
      () async {
        final corruptBytes = Uint8List.fromList([
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
        ]);
        transport.files['100-1.venera'] = corruptBytes;
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];

        final liveAppdataFile = File(p.join(App.dataPath, 'appdata.json'));
        liveAppdataFile.writeAsStringSync('{"live": "untouched"}');

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));

        // Live state remains untouched
        expect(
          liveAppdataFile.readAsStringSync(),
          equals('{"live": "untouched"}'),
        );
      },
    );

    test(
      'archive containing path traversal entry throws FormatException',
      () async {
        final archive = Archive();
        final content = utf8.encode('malicious');
        archive.addFile(
          ArchiveFile('../../etc/passwd', content.length, content),
        );
        final encoded = ZipEncoder().encode(archive);

        transport.files['100-1.venera'] = Uint8List.fromList(encoded);
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
      },
    );

    test(
      'archive containing non-whitelisted file throws FormatException',
      () async {
        final archive = Archive();
        final content = utf8.encode('echo hello');
        archive.addFile(ArchiveFile('run.sh', content.length, content));
        final encoded = ZipEncoder().encode(archive);

        transport.files['100-1.venera'] = Uint8List.fromList(encoded);
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
      },
    );

    test(
      'scratch directory execution resources are cleaned up even on error',
      () async {
        final corruptBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
        transport.files['100-1.venera'] = corruptBytes;
        client.remoteFiles = [dav.File(name: '100-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        try {
          await reader.readSeeds();
        } catch (_) {}

        final remaining = scratchDir.listSync(recursive: true);
        expect(remaining, isEmpty);
      },
    );
  });

  group(
    'LegacySyncReader Lossless Multi-Domain Conversion and Schema Migration',
    () {
      test(
        'migrates legacy favorite folder missing columns in isolated DB and converts losslessly',
        () async {
          final favBytes = _createFavoriteDbBytes(
            tempDir,
            includeMissingColumns: true,
          );
          final histBytes = _createHistoryDbBytes(tempDir);
          expect(favBytes, isNotNull);
          expect(histBytes, isNotNull);

          final archiveBytes = _createVeneraArchive(
            historyDbBytes: histBytes,
            localFavoriteDbBytes: favBytes,
            appdataJson: jsonEncode({
              'settings': {'themeMode': 'dark'},
              'searchHistory': ['keyword1', 'keyword2'],
            }),
          );

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );
          final seeds = await reader.readSeeds();

          expect(seeds.length, equals(1));
          final seed = seeds.first;
          expect(
            seed.id,
            equals(sha256.convert(archiveBytes).toString().toLowerCase()),
          );

          // Setting domain
          expect(
            seed.records[syncRecordKey('setting', ['themeMode'])],
            equals({'value': 'dark'}),
          );

          // Search domain
          expect(
            seed.records[syncRecordKey('search', ['keyword1'])],
            equals({'order': 0}),
          );
          expect(
            seed.records[syncRecordKey('search', ['keyword2'])],
            equals({'order': 1}),
          );

          // Favorite and history domains (unconditionally asserted when SQLite is available)
          final folderKey = syncRecordKey('folder', ['legacy-folder-1']);
          expect(seed.records.containsKey(folderKey), isTrue);
          expect(seed.records[folderKey]?['name'], equals('Comics'));

          final favKey = syncRecordKey('favorite', [
            'legacy-folder-1',
            'comic1',
            1,
          ]);
          expect(seed.records.containsKey(favKey), isTrue);
          expect(seed.records[favKey]?['title'], equals('Comic One'));

          final histKey = syncRecordKey('history', ['hist1', 1]);
          expect(seed.records.containsKey(histKey), isTrue);
          expect(seed.records[histKey]?['title'], equals('Hist Title'));

          final chapterKey1 = syncRecordKey('historyChapter', [
            'hist1',
            1,
            '1',
          ]);
          final chapterKey2 = syncRecordKey('historyChapter', [
            'hist1',
            1,
            '2',
          ]);
          expect(seed.records.containsKey(chapterKey1), isTrue);
          expect(seed.records.containsKey(chapterKey2), isTrue);

          expect(scratchDir.listSync(), isEmpty);
        },
        skip: _sqliteAvailable() ? false : 'sqlite3 native library unavailable',
      );
    },
  );

  group(
    'LegacySyncReader QuickJS Source Migration',
    () {
      setUp(() {
        if (_ciRequireQuickJs && quickJsFailure != null) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires QuickJS native library, '
            'but it failed to load: $quickJsFailure',
          );
        }
      });

      test(
        'migration preserves logical source names from the exact metadata sidecar',
        () async {
          final physicalName =
              'sync_${sha256.convert(utf8.encode('my_src'))}.js';
          const scriptContent =
              'class Custom extends ComicSource { key = "my_src"; }';
          transport.files['500-1.venera'] = _createVeneraArchive(
            comicSources: {
              physicalName: scriptContent,
              '.sync_source_names.json': jsonEncode({
                'my_src': {
                  'filename': 'custom.js',
                  'revisions': <String, String>{},
                },
              }),
            },
          );
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];
          final seeds = await LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          ).readSeeds();

          expect(seeds.length, equals(1));
          final sourceKey = syncRecordKey('source', ['my_src']);
          expect(seeds.single.records.containsKey(sourceKey), isTrue);
          final script = seeds.single.records[sourceKey]!['script'] as Map;
          expect(script['filename'], equals('custom.js'));
          expect(script['content'], equals(scriptContent));
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'migrates legacy comic source scripts and sessions in isolated QuickJS runtime',
        () async {
          const scriptContent =
              'class Custom extends ComicSource { key = ["my", "src"].join("_"); }';
          const variantScriptContent =
              'class CustomVariant extends ComicSource { key = ["my", "src"].join("_"); version = "2.0"; }';
          final archiveBytes = _createVeneraArchive(
            comicSources: {
              'custom.js': scriptContent,
              'variant.js': variantScriptContent,
              'my_src.data': jsonEncode({'token': 'session_token_123'}),
            },
          );

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );
          final seeds = await reader.readSeeds();

          expect(seeds.length, equals(1));
          final seed = seeds.first;
          expect(
            seed.id,
            equals(sha256.convert(archiveBytes).toString().toLowerCase()),
          );

          // Source and sourceSession domain
          final sourceKey = syncRecordKey('source', ['my_src']);
          expect(seed.records.containsKey(sourceKey), isTrue);
          final script = seed.records[sourceKey]!['script'] as Map;
          expect(
            script['content'],
            anyOf(equals(scriptContent), equals(variantScriptContent)),
          );

          expect(seed.sourceVariants.containsKey(sourceKey), isTrue);
          final variants = seed.sourceVariants[sourceKey]!;
          expect(variants, hasLength(2));
          final variantContents = variants
              .map((v) => v['content'] as String)
              .toSet();
          expect(
            variantContents,
            equals({scriptContent, variantScriptContent}),
          );
          final sessionKey = syncRecordKey('sourceSession', ['my_src']);
          expect(seed.records.containsKey(sessionKey), isTrue);
          expect(
            seed.records[sessionKey],
            equals({
              'data': {'token': 'session_token_123'},
            }),
          );

          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'unresolvable legacy comic source script preserves archive in backup directory and returns partial seed',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'source_backups'));
          final archiveBytes = _createVeneraArchive(
            appdataJson: '{"settings":{"testKey":"preserved"}}',
            comicSources: {'broken.js': '// empty script without key'},
          );

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
          );

          final seeds = await reader.readSeeds();

          expect(seeds.length, equals(1));
          final seed = seeds.first;
          expect(
            seed.records[syncRecordKey('setting', ['testKey'])]?['value'],
            equals('preserved'),
          );
          expect(seed.sourceIssues, isNotEmpty);
          expect(seed.unavailableDomains, contains('source'));
          final issue = seed.sourceIssues.first;
          expect(issue.archiveName, equals('500-1.venera'));
          expect(issue.backupPath, isNotNull);
          expect(File(issue.backupPath!).existsSync(), isTrue);
          expect(
            File(issue.backupPath!).readAsBytesSync(),
            equals(archiveBytes),
          );

          expect(scratchDir.listSync(), isEmpty);
        },
      );
    },
    skip: (_ciRequireQuickJs || quickJsAvailable) ? false : quickJsFailure,
  );

  group(
    'LegacySyncReader Native ZIP64 and Descriptor Integrity',
    () {
      setUp(() {
        if (_ciRequireNativeZip && nativeZipFailure != null) {
          fail(
            'CI_REQUIRE_NATIVE_ZIP=true requires zip_flutter native library, '
            'but it failed to load: $nativeZipFailure',
          );
        }
      });

      test(
        'native zip_flutter generated archive with version20 small entries and ZIP64 descriptor is accepted with exact data and CRC',
        () async {
          final appdataFile = File(p.join(tempDir.path, 'source_appdata.json'))
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'themeMode': 'dark'},
              }),
            );
          final sourceFile = File(p.join(tempDir.path, 'source_native.js'))
            ..writeAsStringSync(
              'class NativeSrc extends ComicSource { key = "my_native_src"; }',
            );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_archive.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.addFile('comic_source/my_native_src.js', sourceFile.path);
          zip.close();

          final nativeBytes = nativeZipFile.readAsBytesSync();
          transport.files['200-1.venera'] = nativeBytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );
          final seeds = await reader.readSeeds();

          expect(seeds.length, equals(1));
          final seed = seeds.first;
          expect(
            seed.id,
            equals(sha256.convert(nativeBytes).toString().toLowerCase()),
          );
          final settingKey = syncRecordKey('setting', ['themeMode']);
          expect(seed.records[settingKey]?['value'], equals('dark'));
          final sourceKey = syncRecordKey('source', ['my_native_src']);
          expect(seed.records.containsKey(sourceKey), isTrue);
          expect(seed.sourceIssues, isEmpty);
          expect(seed.unavailableDomains, isEmpty);
          expect(scratchDir.listSync(), isEmpty);
        },
      );
      test(
        'native zip_flutter generated archive with appdata, source script, and session data is parsed cleanly and migrates without issue',
        () async {
          final appdataFile =
              File(p.join(tempDir.path, 'source_appdata_full.json'))
                ..writeAsStringSync(
                  jsonEncode({
                    'settings': {'themeMode': 'system'},
                  }),
                );
          final sourceFile = File(p.join(tempDir.path, 'source_native_full.js'))
            ..writeAsStringSync(
              'class FullSrc extends ComicSource { key = "full_native_src"; }',
            );
          final sessionFile =
              File(p.join(tempDir.path, 'source_native_full.data'))
                ..writeAsStringSync(
                  jsonEncode({'account': 'user123', 'token': 'abc_tok'}),
                );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_full_archive.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.addFile('comic_source/full_native_src.js', sourceFile.path);
          zip.addFile('comic_source/full_native_src.data', sessionFile.path);
          zip.close();

          final nativeBytes = nativeZipFile.readAsBytesSync();
          transport.files['200-1.venera'] = nativeBytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );
          final seeds = await reader.readSeeds();

          expect(seeds.length, equals(1));
          final seed = seeds.first;
          expect(
            seed.id,
            equals(sha256.convert(nativeBytes).toString().toLowerCase()),
          );
          final settingKey = syncRecordKey('setting', ['themeMode']);
          expect(seed.records[settingKey]?['value'], equals('system'));
          final sourceKey = syncRecordKey('source', ['full_native_src']);
          expect(seed.records.containsKey(sourceKey), isTrue);
          final sessionRecordKey = syncRecordKey('sourceSession', [
            'full_native_src',
          ]);
          expect(seed.records.containsKey(sessionRecordKey), isTrue);
          expect(seed.sourceIssues, isEmpty);
          expect(seed.unavailableDomains, isEmpty);
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'native zip_flutter generated archive with broken script preserves backup, and durable override repairs it on fresh reader',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'native_backups'));
          final overrideDir = Directory(
            p.join(tempDir.path, 'native_overrides'),
          );
          final appdataFile =
              File(p.join(tempDir.path, 'source_appdata_broken.json'))
                ..writeAsStringSync(
                  jsonEncode({
                    'settings': {'theme': 'dark'},
                  }),
                );
          final brokenSourceFile = File(
            p.join(tempDir.path, 'source_broken.js'),
          )..writeAsStringSync('// broken script without key');
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_broken_archive.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.addFile('comic_source/broken.js', brokenSourceFile.path);
          zip.close();

          final nativeBytes = nativeZipFile.readAsBytesSync();
          final archiveHash = sha256
              .convert(nativeBytes)
              .toString()
              .toLowerCase();
          transport.files['200-1.venera'] = nativeBytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader1 = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds1 = await reader1.readSeeds();
          expect(seeds1.length, equals(1));
          expect(seeds1.first.sourceIssues, isNotEmpty);
          final backupFile = File(
            p.join(backupDir.path, '$archiveHash.venera'),
          );
          expect(backupFile.existsSync(), isTrue);
          expect(backupFile.readAsBytesSync(), equals(nativeBytes));

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedNative extends ComicSource { key = "repaired_native"; }',
            expectedKey: 'repaired_native',
          );

          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_scratch_native'),
          )..createSync();
          final reader2 = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds2 = await reader2.readSeeds();
          expect(seeds2.length, equals(1));
          expect(seeds2.first.sourceIssues, isEmpty);
          expect(seeds2.first.unavailableDomains, isEmpty);
          expect(
            seeds2.first.records.containsKey(
              syncRecordKey('source', ['repaired_native']),
            ),
            isTrue,
          );
          expect(backupFile.readAsBytesSync(), equals(nativeBytes));
        },
      );

      test(
        'descriptor corruption: forged uncompressed size in 64-bit descriptor is rejected',
        () async {
          final appdataFile = File(p.join(tempDir.path, 'forged_appdata.json'))
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'themeMode': 'dark'},
              }),
            );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_forged.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.close();

          final bytes = Uint8List.fromList(nativeZipFile.readAsBytesSync());
          final data = ByteData.sublistView(bytes);
          var descOffset = -1;
          for (var i = 0; i <= bytes.length - 24; i++) {
            if (data.getUint32(i, Endian.little) == 0x08074b50) {
              descOffset = i;
              break;
            }
          }
          expect(descOffset, isNot(equals(-1)));
          final originalUncompressedSize = data.getUint64(
            descOffset + 16,
            Endian.little,
          );
          data.setUint64(
            descOffset + 16,
            originalUncompressedSize + 100,
            Endian.little,
          );

          transport.files['200-1.venera'] = bytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'descriptor corruption: CRC mismatch in 64-bit descriptor is rejected',
        () async {
          final appdataFile = File(p.join(tempDir.path, 'bad_crc_appdata.json'))
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'themeMode': 'dark'},
              }),
            );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_bad_crc.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.close();

          final bytes = Uint8List.fromList(nativeZipFile.readAsBytesSync());
          final data = ByteData.sublistView(bytes);
          var descOffset = -1;
          for (var i = 0; i <= bytes.length - 24; i++) {
            if (data.getUint32(i, Endian.little) == 0x08074b50) {
              descOffset = i;
              break;
            }
          }
          expect(descOffset, isNot(equals(-1)));
          final originalCrc = data.getUint32(descOffset + 4, Endian.little);
          data.setUint32(
            descOffset + 4,
            originalCrc ^ 0xabcdef12,
            Endian.little,
          );

          transport.files['200-1.venera'] = bytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'descriptor corruption: forged compressed size in 64-bit descriptor is rejected',
        () async {
          final appdataFile =
              File(p.join(tempDir.path, 'bad_comp_appdata.json'))
                ..writeAsStringSync(
                  jsonEncode({
                    'settings': {'themeMode': 'dark'},
                  }),
                );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_bad_comp.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', appdataFile.path);
          zip.close();

          final bytes = Uint8List.fromList(nativeZipFile.readAsBytesSync());
          final data = ByteData.sublistView(bytes);
          var descOffset = -1;
          for (var i = 0; i <= bytes.length - 24; i++) {
            if (data.getUint32(i, Endian.little) == 0x08074b50) {
              descOffset = i;
              break;
            }
          }
          expect(descOffset, isNot(equals(-1)));
          final originalCompSize = data.getUint64(
            descOffset + 8,
            Endian.little,
          );
          data.setUint64(descOffset + 8, originalCompSize + 50, Endian.little);

          transport.files['200-1.venera'] = bytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test('truncated data descriptor is rejected before extraction', () async {
        final appdataFile = File(p.join(tempDir.path, 'trunc_appdata.json'))
          ..writeAsStringSync(
            jsonEncode({
              'settings': {'themeMode': 'dark'},
            }),
          );
        final nativeZipFile = File(p.join(tempDir.path, 'native_trunc.venera'));

        final zip = ZipFile.open(nativeZipFile.path);
        zip.addFile('appdata.json', appdataFile.path);
        zip.close();

        final originalBytes = nativeZipFile.readAsBytesSync();
        final data = ByteData.sublistView(originalBytes);
        var descOffset = -1;
        for (var i = 0; i <= originalBytes.length - 24; i++) {
          if (data.getUint32(i, Endian.little) == 0x08074b50) {
            descOffset = i;
            break;
          }
        }
        expect(descOffset, isNot(equals(-1)));

        final truncatedBytes = Uint8List.fromList([
          ...originalBytes.sublist(0, descOffset + 8),
          ...originalBytes.sublist(descOffset + 24),
        ]);

        transport.files['200-1.venera'] = truncatedBytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      });

      test(
        'overlapping local entries are rejected independently of descriptor width',
        () async {
          final file1 = File(p.join(tempDir.path, 'entry1.json'))
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'key1': 'value1'},
              }),
            );
          final file2 = File(p.join(tempDir.path, 'entry2.json'))
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'key2': 'value2'},
              }),
            );
          final nativeZipFile = File(
            p.join(tempDir.path, 'native_overlap.venera'),
          );

          final zip = ZipFile.open(nativeZipFile.path);
          zip.addFile('appdata.json', file1.path);
          zip.addFile('syncdata.json', file2.path);
          zip.close();

          final bytes = Uint8List.fromList(nativeZipFile.readAsBytesSync());
          for (var i = 0; i <= bytes.length - 46; i++) {
            if (bytes[i] == 0x50 &&
                bytes[i + 1] == 0x4b &&
                bytes[i + 2] == 0x01 &&
                bytes[i + 3] == 0x02) {
              final fnameLen = ByteData.sublistView(
                bytes,
              ).getUint16(i + 28, Endian.little);
              final name = utf8.decode(
                bytes.sublist(i + 46, i + 46 + fnameLen),
              );
              if (name == 'syncdata.json') {
                ByteData.sublistView(bytes).setUint32(i + 42, 5, Endian.little);
                break;
              }
            }
          }

          transport.files['200-1.venera'] = bytes;
          client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );
    },
    skip: (_ciRequireNativeZip || nativeZipAvailable)
        ? false
        : nativeZipFailure,
  );

  group('LegacySyncReader Verified Source Backup and Partial Migration', () {
    test(
      'invalid comic source preserves verified archive in backup directory and returns partial seed',
      () async {
        final backupDir = Directory(p.join(tempDir.path, 'verified_backups'));
        final archiveBytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'theme': 'system'},
          }),
          comicSources: {'broken.js': '// empty or invalid script without key'},
        );

        transport.files['500-1.venera'] = archiveBytes;
        client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
          verifiedSourceBackupDirectory: backupDir,
        );

        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final seed = seeds.first;
        final settingKey = syncRecordKey('setting', ['theme']);
        expect(seed.records[settingKey]?['value'], equals('system'));

        expect(seed.sourceIssues, isNotEmpty);
        expect(seed.unavailableDomains, contains('source'));
        final issue = seed.sourceIssues.first;
        expect(issue.archiveName, equals('500-1.venera'));
        expect(issue.backupPath, isNotNull);
        expect(File(issue.backupPath!).existsSync(), isTrue);
        expect(File(issue.backupPath!).readAsBytesSync(), equals(archiveBytes));

        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'corrupt ZIP archive throws FormatException and creates no backup',
      () async {
        final backupDir = Directory(p.join(tempDir.path, 'corrupt_backups'));
        final corruptBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

        transport.files['500-1.venera'] = corruptBytes;
        client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
          verifiedSourceBackupDirectory: backupDir,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));

        if (backupDir.existsSync()) {
          expect(backupDir.listSync(), isEmpty);
        }
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'omitted backup directory falls back to durable profile source_backups',
      () async {
        final archiveBytes = _createVeneraArchive(
          appdataJson: jsonEncode({
            'settings': {'theme': 'system'},
          }),
          comicSources: {'broken.js': '// empty or invalid script without key'},
        );

        transport.files['500-1.venera'] = archiveBytes;
        client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final seed = seeds.first;
        expect(seed.sourceIssues, isNotEmpty);
        expect(seed.unavailableDomains, contains('source'));
        final issue = seed.sourceIssues.first;
        expect(issue.backupPath, isNotNull);
        expect(File(issue.backupPath!).existsSync(), isTrue);
        expect(
          p.canonicalize(p.dirname(issue.backupPath!)),
          equals(p.canonicalize(p.join(App.dataPath, 'source_backups'))),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );
  });
  group('LegacySyncReader Descriptor Boundaries and Variants', () {
    test(
      'positive coverage: 32-bit signed descriptor (16 bytes) is accepted',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"32_signed"}}'),
          descriptorType: 0,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final settingKey = syncRecordKey('setting', ['testKey']);
        expect(seeds.first.records[settingKey]?['value'], equals('32_signed'));
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'positive coverage: 64-bit unsigned descriptor (20 bytes) is accepted',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"64_unsigned"}}'),
          descriptorType: 2,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final settingKey = syncRecordKey('setting', ['testKey']);
        expect(
          seeds.first.records[settingKey]?['value'],
          equals('64_unsigned'),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'positive coverage: 32-bit unsigned descriptor (12 bytes) is accepted',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"32_unsigned"}}'),
          descriptorType: 3,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        final seeds = await reader.readSeeds();

        expect(seeds.length, equals(1));
        final settingKey = syncRecordKey('setting', ['testKey']);
        expect(
          seeds.first.records[settingKey]?['value'],
          equals('32_unsigned'),
        );
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'descriptor CRC matching the optional signature is still verified against content',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"crc_match_sig"}}'),
          descriptorType: 3,
          overrideCrc: 0x08074b50,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );
        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'empty-entry descriptor corruption: forged 64-bit descriptor trailing bytes for empty entry are rejected',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode(''),
          descriptorType: 4,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'no-descriptor entry with 0xffffffff size verifies local ZIP64 extra field and rejects mismatch',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"bad_extra"}}'),
          descriptorType: 5,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'bit 3 entry with local nonzero CRC contradicting central header is rejected',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"bad_local_crc"}}'),
          descriptorType: 6,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      },
    );
    test(
      'corrupted descriptor variant causes reader to reject archive and leave scratch clean',
      () async {
        final bytes = _createCustomDescriptorArchive(
          filename: 'appdata.json',
          content: utf8.encode('{"settings":{"testKey":"corrupt_pad"}}'),
          descriptorType: 6,
        );
        transport.files['200-1.venera'] = bytes;
        client.remoteFiles = [dav.File(name: '200-1.venera', isDir: false)];

        final reader = LegacySyncReader(
          client,
          scratchDir,
          preferences: preferences,
        );

        await expectLater(reader.readSeeds(), throwsA(isA<FormatException>()));
        expect(scratchDir.listSync(), isEmpty);
      },
    );
  });

  group(
    'LegacySyncReader Durable Overrides and Process Restart',
    () {
      setUp(() {
        if (_ciRequireQuickJs && quickJsFailure != null) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires QuickJS native library, '
            'but it failed to load: $quickJsFailure',
          );
        }
      });
      test(
        'fresh reader / restart: selected repair survives reader restart, leaves other entries and durable backup unmutated',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'override_backups'))
            ..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'endpoint_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            appdataJson: jsonEncode({
              'settings': {'theme': 'dark'},
            }),
            comicSources: {'broken.js': '// empty script'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader1 = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds1 = await reader1.readSeeds();
          expect(seeds1.single.sourceIssues, isNotEmpty);
          expect(seeds1.single.appliedOverrideFilenames, isEmpty);
          expect(seeds1.single.unavailableDomains, contains('source'));
          final backupFile = File(
            p.join(backupDir.path, '$archiveHash.venera'),
          );
          expect(backupFile.existsSync(), isTrue);
          expect(backupFile.readAsBytesSync(), equals(archiveBytes));

          final registered = await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
            expectedKey: 'repaired_src',
          );
          expect(registered, isTrue);

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          expect(manifestFile.existsSync(), isTrue);
          final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
          expect(manifest['archiveSha256'], equals(archiveHash));
          expect((manifest['entries'] as Map).containsKey('broken.js'), isTrue);

          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_scratch_restart'),
          )..createSync();
          final reader2 = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds2 = await reader2.readSeeds();
          expect(seeds2.single.sourceIssues, isEmpty);
          expect(seeds2.single.unavailableDomains, isEmpty);
          expect(seeds2.single.appliedOverrideFilenames, {'broken.js'});
          expect(
            seeds2.single.records.containsKey(
              syncRecordKey('source', ['repaired_src']),
            ),
            isTrue,
          );
          final settingKey = syncRecordKey('setting', ['theme']);
          expect(seeds2.single.records[settingKey]?['value'], equals('dark'));

          expect(backupFile.readAsBytesSync(), equals(archiveBytes));
        },
      );

      test(
        'fresh reader / restart: session .data override replaces invalid session and resolves issue',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'session_backups'))
            ..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'session_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            comicSources: {
              'custom_src.js':
                  'class CustomSrc extends ComicSource { key = "custom_src"; }',
              'custom_src.data': '{ invalid json ...',
            },
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader1 = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds1 = await reader1.readSeeds();
          expect(seeds1.single.sourceIssues, isNotEmpty);
          expect(
            seeds1.single.sourceIssues.any(
              (i) =>
                  i.reason == 'invalidSession' && i.sourceKey == 'custom_src',
            ),
            isTrue,
          );

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'comic_source/custom_src.data',
            replacementContent: jsonEncode({
              'token': 'secret123',
              'user': 'john',
            }),
            expectedKey: 'custom_src',
          );

          final freshScratch = Directory(
            p.join(tempDir.path, 'session_scratch_restart'),
          )..createSync();
          final reader2 = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds2 = await reader2.readSeeds();
          expect(seeds2.single.sourceIssues, isEmpty);
          expect(seeds2.single.unavailableDomains, isEmpty);
          final sessionKey = syncRecordKey('sourceSession', ['custom_src']);
          expect(seeds2.single.records.containsKey(sessionKey), isTrue);
          expect(
            seeds2.single.records[sessionKey]?['data'],
            equals({'token': 'secret123', 'user': 'john'}),
          );
        },
      );

      test(
        'malicious override: path traversal attempts are rejected at registration',
        () async {
          final overrideDir = Directory(
            p.join(tempDir.path, 'traversal_overrides'),
          )..createSync();
          final dummyHash = 'a' * 64;

          for (final badPath in [
            '../evil.js',
            'comic_source/../../evil.js',
            '/root/evil.js',
            'C:\\evil.js',
            'C:/evil.js',
            'comic_source/subdir/evil.js',
            '..\\evil.js',
            'comic_source\\..\\..\\evil.js',
            'comic_source/evil\u0000.js',
          ]) {
            await expectLater(
              LegacySyncReader.registerLegacyOverride(
                overrideDirectory: overrideDir,
                archiveSha256: dummyHash,
                entryFilename: badPath,
                replacementContent:
                    'class Evil extends ComicSource { key = "evil"; }',
              ),
              throwsA(isA<FormatException>()),
            );
          }
        },
      );

      test(
        'malicious override: invalid archive SHA is rejected at registration',
        () async {
          final overrideDir = Directory(
            p.join(tempDir.path, 'bad_sha_overrides'),
          )..createSync();
          for (final badSha in ['not_a_sha', '1234', 'a' * 63, 'g' * 64]) {
            await expectLater(
              LegacySyncReader.registerLegacyOverride(
                overrideDirectory: overrideDir,
                archiveSha256: badSha,
                entryFilename: 'test.js',
                replacementContent:
                    'class T extends ComicSource { key = "t"; }',
              ),
              throwsA(isA<FormatException>()),
            );
          }
        },
      );

      test(
        'malicious override: key mismatch between replacement script and expectedKey is rejected at registration',
        () async {
          final overrideDir = Directory(
            p.join(tempDir.path, 'key_mismatch_overrides'),
          )..createSync();
          final dummyHash = 'b' * 64;

          await expectLater(
            LegacySyncReader.registerLegacyOverride(
              overrideDirectory: overrideDir,
              archiveSha256: dummyHash,
              entryFilename: 'test.js',
              replacementContent:
                  'class T extends ComicSource { key = "actual_key"; }',
              expectedKey: 'expected_different_key',
            ),
            throwsA(isA<FormatException>()),
          );
        },
      );

      test(
        'malicious override: replacement exceeding text budget is rejected at registration',
        () async {
          final overrideDir = Directory(
            p.join(tempDir.path, 'budget_overrides'),
          )..createSync();
          final dummyHash = 'c' * 64;
          final hugeContent = ' ' * (16 * 1024 * 1024 + 1);

          await expectLater(
            LegacySyncReader.registerLegacyOverride(
              overrideDirectory: overrideDir,
              archiveSha256: dummyHash,
              entryFilename: 'huge.js',
              replacementContent: hugeContent,
            ),
            throwsA(isA<FormatException>()),
          );
        },
      );

      test(
        'malicious override: invalid session JSON does not leak payload in error message',
        () async {
          final overrideDir = Directory(
            p.join(tempDir.path, 'session_leak_overrides'),
          )..createSync();
          final dummyHash = 'd' * 64;
          const secretToken = 'TOP_SECRET_AUTH_COOKIE_VALUE_NEVER_LEAK';
          final brokenPayload = '{"auth": "$secretToken", syntax_error';

          try {
            await LegacySyncReader.registerLegacyOverride(
              overrideDirectory: overrideDir,
              archiveSha256: dummyHash,
              entryFilename: 'my_src.data',
              replacementContent: brokenPayload,
              expectedKey: 'my_src',
            );
            fail('Should have thrown FormatException');
          } on FormatException catch (e) {
            expect(e.message.contains(secretToken), isFalse);
            expect(e.message, contains('Invalid session JSON'));
          }
        },
      );

      test(
        'malicious override on disk: forged manifest pointing to new unrelated file throws FormatException on read',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'unrelated_backups'))
            ..createSync();
          final overrideDir = Directory(
            p.join(tempDir.path, 'unrelated_overrides'),
          )..createSync();
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// empty script'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entries = Map<String, dynamic>.from(manifest['entries'] as Map);
          final evilSha = sha256
              .convert(
                utf8.encode('class Evil extends ComicSource { key = "evil"; }'),
              )
              .toString()
              .toLowerCase();
          entries['evil_unrelated.js'] = {
            'filename': 'evil_unrelated.js',
            'entryPath': 'comic_source/evil_unrelated.js',
            'contentSha256': evilSha,
            'type': 'script',
            'expectedKey': 'evil',
            'relativeFilePath': 'files/$evilSha',
          };
          manifest['entries'] = entries;
          manifestFile.writeAsStringSync(jsonEncode(manifest));
          File(p.join(overrideDir.path, archiveHash, 'files', evilSha))
            ..writeAsStringSync(
              'class Evil extends ComicSource { key = "evil"; }',
            );

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'malicious override on disk: forged manifest with path traversal relativeFilePath throws FormatException on read',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'traversal_disk_backups'),
          )..createSync();
          final overrideDir = Directory(
            p.join(tempDir.path, 'traversal_disk_overrides'),
          )..createSync();
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// empty script'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entries = Map<String, dynamic>.from(manifest['entries'] as Map);
          entries['broken.js']['relativeFilePath'] = '../outside.js';
          manifest['entries'] = entries;
          manifestFile.writeAsStringSync(jsonEncode(manifest));

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'malicious override on disk: tampered replacement content hash mismatch throws FormatException on read',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'tamper_hash_backups'),
          )..createSync();
          final overrideDir = Directory(
            p.join(tempDir.path, 'tamper_hash_overrides'),
          )..createSync();
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// empty script'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entry = manifest['entries']['broken.js'] as Map;
          final relPath = entry['relativeFilePath'] as String;
          final replFile = File(p.join(overrideDir.path, archiveHash, relPath));
          replFile.writeAsStringSync(
            'class Tampered extends ComicSource { key = "tampered"; }',
          );
          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'malicious override on disk: forged expectedKey mismatching script probed key throws FormatException on read',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'tamper_key_backups'),
          )..createSync();
          final overrideDir = Directory(
            p.join(tempDir.path, 'tamper_key_overrides'),
          )..createSync();
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// empty script'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entries = Map<String, dynamic>.from(manifest['entries'] as Map);
          entries['broken.js']['expectedKey'] = 'different_key';
          manifest['entries'] = entries;
          manifestFile.writeAsStringSync(jsonEncode(manifest));

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'malicious override on disk: forged session key mismatching filename throws FormatException on read',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'session_tamper_backups'),
          )..createSync();
          final overrideDir = Directory(
            p.join(tempDir.path, 'session_tamper_overrides'),
          )..createSync();
          final archiveBytes = _createVeneraArchive(
            comicSources: {
              'my_src.js':
                  'class MySrc extends ComicSource { key = "my_src"; }',
              'my_src.data': '{"token": "old"}',
            },
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'my_src.data',
            replacementContent: '{"token": "new"}',
            expectedKey: 'my_src',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entries = Map<String, dynamic>.from(manifest['entries'] as Map);
          entries['my_src.data']['expectedKey'] = 'forged_mismatched_key';
          manifest['entries'] = entries;
          manifestFile.writeAsStringSync(jsonEncode(manifest));

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );

          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );
      test(
        'parenthesized legacy basenames komiic(0).js and jm(0).js repair after restart',
        () async {
          final backupDir = Directory(p.join(tempDir.path, 'alias_backups'))
            ..createSync(recursive: true);
          final overrideDir = Directory(p.join(tempDir.path, 'alias_overrides'))
            ..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            comicSources: {
              'komiic(0).js': '// empty or broken komiic script',
              'jm(0).js': '// empty or broken jm script',
            },
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader1 = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds1 = await reader1.readSeeds();
          expect(seeds1.single.sourceIssues, hasLength(2));
          expect(
            seeds1.single.sourceIssues.map((i) => i.filename),
            containsAll(['komiic(0).js', 'jm(0).js']),
          );

          final ok = await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'comic_source/komiic(0).js',
            replacementContent:
                'class Komiic extends ComicSource { key = "komiic"; }',
            expectedKey: 'komiic',
          );
          expect(ok, isTrue);
          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'jm(0).js',
            replacementContent: 'class Jm extends ComicSource { key = "jm"; }',
            expectedKey: 'jm',
          );

          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_alias_scratch'),
          )..createSync();
          final reader2 = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds2 = await reader2.readSeeds();
          expect(seeds2.single.sourceIssues, isEmpty);
          expect(seeds2.single.unavailableDomains, isEmpty);
          expect(
            seeds2.single.records.containsKey(
              syncRecordKey('source', ['komiic']),
            ),
            isTrue,
          );
          expect(
            seeds2.single.records.containsKey(syncRecordKey('source', ['jm'])),
            isTrue,
          );
        },
      );

      test(
        'first publication retries from a durable empty genesis after pointer interruption',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'genesis_retry_backups'),
          )..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'genesis_retry_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// broken original'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();
          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final initialReader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final initialSeeds = await initialReader.readSeeds();
          expect(initialSeeds.single.sourceIssues, isNotEmpty);
          final backupFile = File(
            p.join(backupDir.path, '$archiveHash.venera'),
          );
          expect(backupFile.readAsBytesSync(), equals(archiveBytes));

          // Model a crash after atomic bootstrap publication but before the first
          // repair pointer commit. Genesis is initialized state, not completion.
          final archiveOverrideDir = Directory(
            p.join(overrideDir.path, archiveHash),
          )..createSync();
          final filesDir = Directory(p.join(archiveOverrideDir.path, 'files'))
            ..createSync();
          final genesisManifestFile = File(
            p.join(archiveOverrideDir.path, 'manifest.json'),
          );
          final genesisRaw = jsonEncode({
            'archiveSha256': archiveHash,
            'entries': <String, Object?>{},
            'state': 'genesis',
          });
          genesisManifestFile.writeAsStringSync(genesisRaw, flush: true);

          final genesisScratch = Directory(
            p.join(tempDir.path, 'fresh_genesis_scratch'),
          )..createSync();
          final genesisReader = LegacySyncReader(
            client,
            genesisScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final genesisSeeds = await genesisReader.readSeeds();
          expect(
            genesisSeeds.single.sourceIssues.any(
              (issue) => issue.filename == 'broken.js',
            ),
            isTrue,
          );
          expect(genesisSeeds.single.unavailableDomains, contains('source'));

          const repairedContent =
              'class Recovered extends ComicSource { key = "recovered"; }';
          final repairedSha = sha256
              .convert(utf8.encode(repairedContent))
              .toString();
          final repairedFile = File(p.join(filesDir.path, repairedSha));
          if (Platform.isWindows) {
            final handle = _holdNoDeleteHandle(genesisManifestFile.path);
            try {
              await expectLater(
                LegacySyncReader.registerLegacyOverride(
                  overrideDirectory: overrideDir,
                  archiveSha256: archiveHash,
                  entryFilename: 'broken.js',
                  replacementContent: repairedContent,
                  expectedKey: 'recovered',
                ),
                throwsA(isA<FileSystemException>()),
              );
              expect(
                genesisManifestFile.readAsStringSync(),
                equals(genesisRaw),
              );
              expect(repairedFile.readAsStringSync(), equals(repairedContent));
            } finally {
              _closeWindowsHandle(handle);
            }
          }

          // Retry validates/reuses the immutable blob, then commits the pointer.
          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent: repairedContent,
            expectedKey: 'recovered',
          );
          final committedManifest =
              jsonDecode(genesisManifestFile.readAsStringSync()) as Map;
          expect(committedManifest.containsKey('state'), isFalse);
          expect(
            (committedManifest['entries'] as Map).containsKey('broken.js'),
            isTrue,
          );

          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_genesis_retry_scratch'),
          )..createSync();
          final freshReader = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final recoveredSeeds = await freshReader.readSeeds();
          expect(recoveredSeeds.single.sourceIssues, isEmpty);
          expect(
            recoveredSeeds.single.records.containsKey(
              syncRecordKey('source', ['recovered']),
            ),
            isTrue,
          );
          expect(backupFile.readAsBytesSync(), equals(archiveBytes));
        },
      );

      test(
        'locked second manifest commit preserves prior repair after fresh-reader restart',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'locked_commit_backups'),
          )..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'locked_commit_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            comicSources: {
              'broken1.js': '// broken original one',
              'broken2.js': '// broken original two',
            },
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();
          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final initialReader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          expect(
            (await initialReader.readSeeds()).single.sourceIssues,
            hasLength(2),
          );

          const firstRepair =
              'class FirstRepair extends ComicSource { key = "first_repair"; }';
          const secondRepair =
              'class SecondRepair extends ComicSource { key = "second_repair"; }';
          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken1.js',
            replacementContent: firstRepair,
            expectedKey: 'first_repair',
          );

          final archiveOverrideDir = Directory(
            p.join(overrideDir.path, archiveHash),
          );
          final manifestFile = File(
            p.join(archiveOverrideDir.path, 'manifest.json'),
          );
          final lastCommittedManifest = manifestFile.readAsStringSync();
          final firstSha = sha256.convert(utf8.encode(firstRepair)).toString();
          final secondSha = sha256
              .convert(utf8.encode(secondRepair))
              .toString();
          final firstFile = File(
            p.join(archiveOverrideDir.path, 'files', firstSha),
          );
          expect(firstFile.readAsStringSync(), equals(firstRepair));

          final handle = _holdNoDeleteHandle(manifestFile.path);
          try {
            await expectLater(
              LegacySyncReader.registerLegacyOverride(
                overrideDirectory: overrideDir,
                archiveSha256: archiveHash,
                entryFilename: 'broken2.js',
                replacementContent: secondRepair,
                expectedKey: 'second_repair',
              ),
              throwsA(isA<FileSystemException>()),
            );
            expect(
              manifestFile.readAsStringSync(),
              equals(lastCommittedManifest),
            );
            expect(firstFile.readAsStringSync(), equals(firstRepair));
            expect(
              File(
                p.join(archiveOverrideDir.path, 'files', secondSha),
              ).readAsStringSync(),
              equals(secondRepair),
            );
          } finally {
            _closeWindowsHandle(handle);
          }

          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_locked_commit_scratch'),
          )..createSync();
          final freshReader = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds = await freshReader.readSeeds();
          expect(
            seeds.single.sourceIssues.map((issue) => issue.filename),
            contains('broken2.js'),
          );
          expect(
            seeds.single.sourceIssues.any(
              (issue) => issue.filename == 'broken1.js',
            ),
            isFalse,
          );
          expect(
            seeds.single.records.containsKey(
              syncRecordKey('source', ['first_repair']),
            ),
            isTrue,
          );
          expect(
            File(
              p.join(backupDir.path, '$archiveHash.venera'),
            ).readAsBytesSync(),
            equals(archiveBytes),
          );
        },
        skip: !Platform.isWindows
            ? 'Windows file sharing semantics are required'
            : (_ciRequireQuickJs || quickJsAvailable)
            ? false
            : quickJsFailure,
      );
      test(
        'missing pointer in an existing override directory fails closed',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'missing_pointer_backups'),
          )..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'missing_pointer_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// broken original'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();
          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final initialReader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          expect(
            (await initialReader.readSeeds()).single.sourceIssues,
            isNotEmpty,
          );
          const repair = 'class Repair extends ComicSource { key = "repair"; }';
          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent: repair,
            expectedKey: 'repair',
          );

          final archiveOverrideDir = Directory(
            p.join(overrideDir.path, archiveHash),
          );
          final manifestFile = File(
            p.join(archiveOverrideDir.path, 'manifest.json'),
          );
          final repairSha = sha256.convert(utf8.encode(repair)).toString();
          final repairFile = File(
            p.join(archiveOverrideDir.path, 'files', repairSha),
          );
          manifestFile.deleteSync();

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          await expectLater(
            LegacySyncReader.registerLegacyOverride(
              overrideDirectory: overrideDir,
              archiveSha256: archiveHash,
              entryFilename: 'another.js',
              replacementContent:
                  'class Another extends ComicSource { key = "another"; }',
            ),
            throwsA(isA<FormatException>()),
          );
          expect(manifestFile.existsSync(), isFalse);
          expect(repairFile.readAsStringSync(), equals(repair));
          expect(
            File(
              p.join(backupDir.path, '$archiveHash.venera'),
            ).readAsBytesSync(),
            equals(archiveBytes),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );

      test(
        'second-repair failure leaves first committed repair intact and usable across fresh reader restart',
        () async {
          final backupDir = Directory(
            p.join(tempDir.path, 'second_repair_backups'),
          )..createSync(recursive: true);
          final overrideDir = Directory(
            p.join(tempDir.path, 'second_repair_overrides'),
          )..createSync(recursive: true);
          final archiveBytes = _createVeneraArchive(
            appdataJson: jsonEncode({
              'settings': {'theme': 'system'},
            }),
            comicSources: {
              'broken1.js': '// empty 1',
              'broken2.js': '// empty 2',
            },
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();

          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          final reader1 = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds1 = await reader1.readSeeds();
          expect(seeds1.single.sourceIssues.length, equals(2));
          final backupFile = File(
            p.join(backupDir.path, '$archiveHash.venera'),
          );
          expect(backupFile.existsSync(), isTrue);
          expect(backupFile.readAsBytesSync(), equals(archiveBytes));

          // 1. Commit first valid repair for broken1.js
          const v1Content = 'class Src1 extends ComicSource { key = "src1"; }';
          final v1Sha = sha256
              .convert(utf8.encode(v1Content))
              .toString()
              .toLowerCase();
          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken1.js',
            replacementContent: v1Content,
            expectedKey: 'src1',
          );

          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          expect(manifestFile.existsSync(), isTrue);
          final v1ManifestRaw = manifestFile.readAsStringSync();
          final v1File = File(
            p.join(overrideDir.path, archiveHash, 'files', v1Sha),
          );
          expect(v1File.existsSync(), isTrue);
          expect(v1File.readAsStringSync(), equals(v1Content));

          // 2. Corrupt manifest before second repair attempt
          const corruptManifestRaw = 'corrupted json payload {';
          manifestFile.writeAsStringSync(corruptManifestRaw);
          const v2Content = 'class Src2 extends ComicSource { key = "src2"; }';
          final v2Sha = sha256.convert(utf8.encode(v2Content)).toString();

          // Attempt second repair on broken2.js: must fail without touching v1File
          await expectLater(
            LegacySyncReader.registerLegacyOverride(
              overrideDirectory: overrideDir,
              archiveSha256: archiveHash,
              entryFilename: 'broken2.js',
              replacementContent: v2Content,
              expectedKey: 'src2',
            ),
            throwsA(isA<FormatException>()),
          );

          // Failed registration leaves both the pointer and immutable blob set as-is.
          expect(manifestFile.readAsStringSync(), equals(corruptManifestRaw));
          expect(v1File.existsSync(), isTrue);
          expect(v1File.readAsStringSync(), equals(v1Content));
          expect(
            File(
              p.join(overrideDir.path, archiveHash, 'files', v2Sha),
            ).existsSync(),
            isFalse,
          );
          expect(
            Directory(
              p.join(overrideDir.path, archiveHash, 'files'),
            ).listSync().map((entity) => p.basename(entity.path)),
            unorderedEquals([v1Sha]),
          );

          // Restore committed manifest to simulate recovery
          manifestFile.writeAsStringSync(v1ManifestRaw);

          // Fresh reader / restart: first repair is cleanly applied and available
          final freshScratch = Directory(
            p.join(tempDir.path, 'fresh_second_repair_scratch'),
          )..createSync();
          final reader2 = LegacySyncReader(
            client,
            freshScratch,
            preferences: preferences,
            verifiedSourceBackupDirectory: backupDir,
            legacyOverrideDirectory: overrideDir,
          );
          final seeds2 = await reader2.readSeeds();
          expect(
            seeds2.single.sourceIssues.any((i) => i.filename == 'broken1.js'),
            isFalse,
          );
          expect(
            seeds2.single.sourceIssues.any((i) => i.filename == 'broken2.js'),
            isTrue,
          );
          expect(
            seeds2.single.records.containsKey(
              syncRecordKey('source', ['src1']),
            ),
            isTrue,
          );

          // True immutable original archive proof: backup bytes never mutated
          expect(backupFile.readAsBytesSync(), equals(archiveBytes));
        },
      );

      test(
        'public register and replay reject path relocation across comic_source boundary',
        () async {
          final overrideDir = Directory(p.join(tempDir.path, 'reloc_overrides'))
            ..createSync();
          final dummyHash = 'e' * 64;

          // Register rejects non-comic_source paths
          for (final badPath in [
            'database/test.js',
            'other/test.js',
            'appdata.json',
            'comic_source/nested/sub.js',
          ]) {
            await expectLater(
              LegacySyncReader.registerLegacyOverride(
                overrideDirectory: overrideDir,
                archiveSha256: dummyHash,
                entryFilename: badPath,
                replacementContent:
                    'class T extends ComicSource { key = "t"; }',
              ),
              throwsA(isA<FormatException>()),
            );
          }

          // Replay rejects forged entryPath
          final archiveBytes = _createVeneraArchive(
            comicSources: {'broken.js': '// broken'},
          );
          final archiveHash = sha256
              .convert(archiveBytes)
              .toString()
              .toLowerCase();
          transport.files['500-1.venera'] = archiveBytes;
          client.remoteFiles = [dav.File(name: '500-1.venera', isDir: false)];

          await LegacySyncReader.registerLegacyOverride(
            overrideDirectory: overrideDir,
            archiveSha256: archiveHash,
            entryFilename: 'broken.js',
            replacementContent:
                'class RepairedSrc extends ComicSource { key = "repaired_src"; }',
          );

          // Forged entryPath in manifest
          final manifestFile = File(
            p.join(overrideDir.path, archiveHash, 'manifest.json'),
          );
          final manifest =
              jsonDecode(manifestFile.readAsStringSync())
                  as Map<String, dynamic>;
          final entries = Map<String, dynamic>.from(manifest['entries'] as Map);
          entries['broken.js']['entryPath'] = 'other_dir/broken.js';
          manifest['entries'] = entries;
          manifestFile.writeAsStringSync(jsonEncode(manifest));

          final reader = LegacySyncReader(
            client,
            scratchDir,
            preferences: preferences,
            legacyOverrideDirectory: overrideDir,
          );
          await expectLater(
            reader.readSeeds(),
            throwsA(isA<FormatException>()),
          );
          expect(scratchDir.listSync(), isEmpty);
        },
      );
    },
    skip: (_ciRequireQuickJs || quickJsAvailable) ? false : quickJsFailure,
  );
}
