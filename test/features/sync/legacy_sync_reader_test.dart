import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _TestDavClient extends dav.Client {
  _TestDavClient(this.transport)
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(httpAdapter: transport),
        auth: dav.Auth(user: 'user', pwd: 'pass'),
      );

  final _TestDavTransport transport;
  List<dav.File> remoteFiles = [];
  Future<List<dav.File>> Function(String path)? onReadDir;

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
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

void main() {
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
        final seeds = await LegacySyncReader(
          networkClient,
          scratchDir,
          preferences: preferences,
        ).readSeeds();
        expect(seeds.single.id, sha256.convert(archive).toString());
        expect(seeds.single.records[syncRecordKey('setting', ['testKey'])], {
          'value': 'loopback',
        });
        expect(requests.where((r) => r.startsWith('PROPFIND')), hasLength(2));
        expect(requests, contains('GET /payload'));
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

  group('LegacySyncReader Lossless Multi-Domain Conversion and Schema Migration', () {
    test(
      'migration preserves logical source names from the exact metadata sidecar',
      () async {
        final physicalName = 'sync_${sha256.convert(utf8.encode('my_src'))}.js';
        transport.files['500-1.venera'] = _createVeneraArchive(
          comicSources: {
            physicalName:
                'class Custom extends ComicSource { key = "my_src"; }',
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
        final script =
            seeds.single.records[syncRecordKey('source', ['my_src'])]!['script']
                as Map;
        expect(script['filename'], 'custom.js');
        expect(scratchDir.listSync(), isEmpty);
      },
    );

    test(
      'migrates legacy favorite folder missing columns in isolated DB and converts losslessly',
      () async {
        // Create favorite DB with legacy schema missing display_order, last_update_time, has_new_update
        final favBytes = _createFavoriteDbBytes(
          tempDir,
          includeMissingColumns: true,
        );
        final histBytes = _createHistoryDbBytes(tempDir);

        final archiveBytes = _createVeneraArchive(
          historyDbBytes: histBytes,
          localFavoriteDbBytes: favBytes,
          appdataJson: jsonEncode({
            'settings': {'themeMode': 'dark'},
            'searchHistory': ['keyword1', 'keyword2'],
          }),
          comicSources: {
            'custom.js': 'class Custom extends ComicSource { key = "my_src"; }',
            'my_src.data': '{"token":"session_token_123"}',
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

        // Source and sourceSession domain
        expect(seed.records[syncRecordKey('source', ['my_src'])], isNotNull);
        expect(
          seed.records[syncRecordKey('sourceSession', ['my_src'])],
          equals({
            'data': {'token': 'session_token_123'},
          }),
        );

        // If SQLite was available, verify favorite and history domains
        if (favBytes != null) {
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
        }

        if (histBytes != null) {
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
        }
      },
    );
  });
}
