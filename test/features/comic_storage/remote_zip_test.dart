import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

void main() {
  test(
    'HTTP ranges index only the footer/directory and read one entry',
    () async {
      final fixture = _zip([
        _Spec('1.jpg', utf8.encode('first page')),
        _Spec('2.jpg', List.filled(180000, 0x7f)),
        _Spec('3.jpg', utf8.encode('third page')),
        _Spec('metadata.json', utf8.encode('{}')),
      ], commentLength: 0xffff);
      final calls = <(int, int)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        final range = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        if (range == null) {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          final start = int.parse(range.group(1)!);
          final end = int.parse(range.group(2)!);
          calls.add((start, end - start + 1));
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${fixture.bytes.length}',
          );
          request.response.add(fixture.bytes.sublist(start, end + 1));
        }
        await request.response.close();
      });
      final client = HttpClient();
      Future<Uint8List> read(int offset, int length) async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/comic.cbz'),
        );
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$offset-${offset + length - 1}',
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.partialContent);
        final result = BytesBuilder(copy: false);
        await for (final chunk in response) {
          result.add(chunk);
        }
        return result.takeBytes();
      }

      try {
        final index = await RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: read,
        );
        expect(calls, [
          (fixture.bytes.length - 65633, 65633),
          (fixture.centralOffset, fixture.centralSize),
        ]);
        expect(index.entries.map((entry) => entry.name), [
          '1.jpg',
          '2.jpg',
          '3.jpg',
          'metadata.json',
        ]);
        calls.clear();
        final page = await index.readEntry(index.entries.first, read);
        expect(utf8.decode(page), 'first page');
        expect(calls, [
          (fixture.localOffsets.first, 30),
          (fixture.dataOffsets.first, fixture.compressedSizes.first),
        ]);
        expect(
          calls.any((call) => call.$1 == fixture.localOffsets[1]),
          isFalse,
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );

  test(
    'reads Store, Deflate, empty entries and archive metadata after JSON restore',
    () async {
      const metadata = ComicMetaData(
        title: '测试漫画',
        author: '作者',
        tags: ['冒险'],
        chapters: [ComicChapter(title: '第一章', start: 1, end: 2)],
      );
      final contents = [
        utf8.encode('stored page'),
        utf8.encode(List.filled(2000, 'compressed page').join()),
        <int>[],
        <int>[],
        utf8.encode(jsonEncode(metadata.toJson())),
      ];
      final fixture = _zip([
        _Spec('1.jpg', contents[0]),
        _Spec('2.jpg', contents[1], method: 8),
        _Spec('empty', contents[2]),
        _Spec('empty.deflated', contents[3], method: 8),
        _Spec('metadata.json', contents[4], method: 8),
      ]);
      final reader = _Reader(fixture.bytes);
      final original = await RemoteZipIndex.read(
        fileSize: fixture.bytes.length,
        read: reader.read,
      );
      final index = RemoteZipIndex.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(index.toJson(), original.toJson());
      expect(index.fileSize, fixture.bytes.length);
      expect(index.entries[1].compressionMethod, 8);
      expect(index.entries[1].uncompressedSize, contents[1].length);
      expect(index.entries[1].compressedSize, fixture.compressedSizes[1]);
      expect(index.entries[1].crc32, archive.getCrc32(contents[1]));
      expect(index.entries[1].flags, 0x800);
      for (var i = 0; i < contents.length; i++) {
        expect(
          await index.readEntry(index.entries[i], reader.read),
          contents[i],
        );
      }
      final parsed = ComicMetaData.fromJson(
        jsonDecode(
          utf8.decode(await index.readEntry(index.entries.last, reader.read)),
        ),
      );
      expect(parsed.toJson(), metadata.toJson());
      expect(() => index.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'decodes UTF8, GBK, Unicode path extra and canonical directories',
    () async {
      final legacyName = latin1.encode('legacy.jpg');
      final unicodeName = utf8.encode('书名/封面.jpg');
      final unicodeExtra = _extra(0x7075, [
        1,
        ..._integer(archive.getCrc32(legacyName), 4),
        ...unicodeName,
      ]);
      final fixture = _zip([
        _Spec('章节/第一页.jpg', [1]),
        _Spec(
          '第二页.jpg',
          [2],
          nameBytes: const GbkCodec().encode('第二页.jpg'),
          flags: 0,
        ),
        _Spec('legacy.jpg', [3], flags: 0, extra: unicodeExtra),
        _Spec('./Book\\pages//1.jpg', [4]),
        _Spec('Book\\pages\\', []),
        _Spec('DOS directory', [], attributes: 0x10),
        _Spec('Unix directory', [], attributes: 0x4000 << 16),
      ]);
      final reader = _Reader(fixture.bytes);
      final index = await RemoteZipIndex.read(
        fileSize: fixture.bytes.length,
        read: reader.read,
      );
      expect(index.entries.map((entry) => entry.name), [
        '章节/第一页.jpg',
        '第二页.jpg',
        '书名/封面.jpg',
        'Book/pages/1.jpg',
        'Book/pages/',
        'DOS directory/',
        'Unix directory/',
      ]);
      expect(index.entries.map((entry) => entry.isDirectory), [
        false,
        false,
        false,
        false,
        true,
        true,
        true,
      ]);
      expect(await index.readEntry(index.entries[2], reader.read), [3]);
    },
  );

  test(
    'reads ZIP64 fields and descriptors without fetching a descriptor',
    () async {
      for (final signature in [false, true]) {
        final fixture = _zip(
          [
            _Spec('1.jpg', utf8.encode('stored descriptor'), descriptor: true),
            _Spec(
              '2.jpg',
              utf8.encode('deflated descriptor'),
              method: 8,
              descriptor: true,
              zip64: true,
            ),
          ],
          zip64End: true,
          descriptorSignature: signature,
        );
        final reader = _Reader(fixture.bytes);
        final index = await RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: reader.read,
        );
        reader.calls.clear();
        expect(
          utf8.decode(await index.readEntry(index.entries[1], reader.read)),
          'deflated descriptor',
        );
        expect(reader.calls, [
          (fixture.localOffsets[1], 30),
          (fixture.dataOffsets[1], fixture.compressedSizes[1]),
        ]);
        expect(
          utf8.decode(await index.readEntry(index.entries[0], reader.read)),
          'stored descriptor',
        );
      }
    },
  );

  test('reads ZIP64 local size sentinels without a descriptor', () async {
    final fixture = _zip([
      _Spec('page.jpg', [1, 2, 3], zip64: true),
    ]);
    final reader = _Reader(fixture.bytes);
    final index = await RemoteZipIndex.read(
      fileSize: fixture.bytes.length,
      read: reader.read,
    );
    expect(await index.readEntry(index.entries.single, reader.read), [1, 2, 3]);
  });

  test(
    'fetches only the fixed ZIP64 end fields outside the footer window',
    () async {
      final fixture = _zip(
        [
          _Spec('page.jpg', [1, 2, 3], zip64: true),
        ],
        zip64End: true,
        zip64ExtensionLength: 70000,
        commentLength: 0xffff,
      );
      final reader = _Reader(fixture.bytes);
      final index = await RemoteZipIndex.read(
        fileSize: fixture.bytes.length,
        read: reader.read,
      );
      expect(reader.calls, [
        (fixture.bytes.length - 65633, 65633),
        (fixture.zip64Offset!, 56),
        (fixture.centralOffset, fixture.centralSize),
      ]);
      expect(await index.readEntry(index.entries.single, reader.read), [
        1,
        2,
        3,
      ]);
    },
  );

  test('accepts an empty ZIP archive', () async {
    final fixture = _zip([]);
    final reader = _Reader(fixture.bytes);
    final index = await RemoteZipIndex.read(
      fileSize: fixture.bytes.length,
      read: reader.read,
    );
    expect(index.entries, isEmpty);
    expect(RemoteZipIndex.fromJson(index.toJson()).entries, isEmpty);
  });

  test(
    'rejects CRC mismatch and declared deflate lengths in both directions',
    () async {
      for (final spec in [
        _Spec('crc.jpg', [1, 2, 3], crc: 0),
        _Spec('short.jpg', List.filled(2000, 1), method: 8, declaredSize: 1999),
        _Spec('long.jpg', List.filled(2000, 1), method: 8, declaredSize: 2001),
      ]) {
        final fixture = _zip([spec]);
        final reader = _Reader(fixture.bytes);
        final index = await RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: reader.read,
        );
        await expectLater(
          index.readEntry(index.entries.single, reader.read),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects unsafe archive paths before exposing the index', () async {
    for (final name in [
      '../1.jpg',
      '/1.jpg',
      'C:\\1.jpg',
      '\\\\server\\1.jpg',
      'book/../1.jpg',
      'bad\u0000.jpg',
      'name:stream.jpg',
      '.',
    ]) {
      final fixture = _zip([
        _Spec(name, [1]),
      ]);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: _Reader(fixture.bytes).read,
        ),
        throwsFormatException,
        reason: name,
      );
    }
  });

  test(
    'rejects encrypted entries, split archives and unsupported compression',
    () async {
      for (final spec in [
        _Spec('encrypted.jpg', [1], flags: 1),
        _Spec('strong-encrypted.jpg', [1], flags: 0x40),
        _Spec('masked.jpg', [1], flags: 0x2000),
        _Spec('bzip2.jpg', [1], method: 12),
        _Spec('aes.jpg', [1], method: 99),
        _Spec('split.jpg', [1], disk: 1),
      ]) {
        final fixture = _zip([spec]);
        await expectLater(
          RemoteZipIndex.read(
            fileSize: fixture.bytes.length,
            read: _Reader(fixture.bytes).read,
          ),
          throwsUnsupportedError,
        );
      }
      final fixture = _zip([
        _Spec('page.jpg', [1]),
      ]);
      ByteData.sublistView(
        fixture.bytes,
      ).setUint16(fixture.bytes.length - 22 + 4, 1, Endian.little);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: _Reader(fixture.bytes).read,
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'rejects oversized unsigned ZIP64 offsets instead of wrapping',
    () async {
      final fixture = _zip([
        _Spec('page.jpg', [1], zip64: true),
      ], zip64End: true);
      final data = ByteData.sublistView(fixture.bytes);
      final offsetHigh =
          fixture.centralOffset +
          46 +
          utf8.encode('page.jpg').length +
          4 +
          16 +
          4;
      data.setUint32(offsetHigh, 0x200000, Endian.little);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: _Reader(fixture.bytes).read,
        ),
        throwsUnsupportedError,
      );
      data.setUint32(offsetHigh, 0x80000000, Endian.little);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: _Reader(fixture.bytes).read,
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'rejects truncated ranges, corrupt directory offsets and local payload ranges',
    () async {
      final fixture = _zip([
        _Spec('page.jpg', [1, 2, 3]),
      ]);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: fixture.bytes.length,
          read: (offset, length) async => Uint8List(length - 1),
        ),
        throwsFormatException,
      );
      final reader = _Reader(fixture.bytes);
      final index = await RemoteZipIndex.read(
        fileSize: fixture.bytes.length,
        read: reader.read,
      );
      final data = ByteData.sublistView(fixture.bytes);
      data.setUint16(26, 0xffff, Endian.little);
      reader.calls.clear();
      await expectLater(
        index.readEntry(index.entries.single, reader.read),
        throwsFormatException,
      );
      expect(reader.calls, [(0, 30)]);
      data.setUint32(
        fixture.bytes.length - 22 + 16,
        fixture.bytes.length,
        Endian.little,
      );
      await expectLater(
        RemoteZipIndex.read(fileSize: fixture.bytes.length, read: reader.read),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects malformed extra fields and missing ZIP64 entry fields',
    () async {
      final malformed = _zip([
        _Spec('page.jpg', [1], extra: [1, 0, 8, 0, 0]),
      ]);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: malformed.bytes.length,
          read: _Reader(malformed.bytes).read,
        ),
        throwsFormatException,
      );
      final missing = _zip([
        _Spec('page.jpg', [1]),
      ]);
      ByteData.sublistView(
        missing.bytes,
      ).setUint32(missing.centralOffset + 20, 0xffffffff, Endian.little);
      await expectLater(
        RemoteZipIndex.read(
          fileSize: missing.bytes.length,
          read: _Reader(missing.bytes).read,
        ),
        throwsFormatException,
      );
    },
  );

  test('validates cached index fields and entry membership', () async {
    final fixture = _zip([
      _Spec('page.jpg', [1]),
    ]);
    final reader = _Reader(fixture.bytes);
    final index = await RemoteZipIndex.read(
      fileSize: fixture.bytes.length,
      read: reader.read,
    );
    final invalidEntry = index.entries.single.toJson()
      ..['localHeaderOffset'] = -1;
    expect(() => RemoteZipEntry.fromJson(invalidEntry), throwsFormatException);
    final unsafeEntry = index.entries.single.toJson()..['name'] = '../page.jpg';
    expect(() => RemoteZipEntry.fromJson(unsafeEntry), throwsFormatException);
    final invalidIndex = index.toJson()
      ..['centralDirectoryOffset'] = fixture.bytes.length;
    expect(() => RemoteZipIndex.fromJson(invalidIndex), throwsFormatException);
    await expectLater(
      index.readEntry(
        RemoteZipEntry.fromJson(index.entries.single.toJson()),
        reader.read,
      ),
      throwsArgumentError,
    );
  });
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  final calls = <(int, int)>[];

  Future<Uint8List> read(int offset, int length) async {
    calls.add((offset, length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

class _Spec {
  _Spec(
    this.name,
    this.bytes, {
    this.method = 0,
    this.flags = 0x800,
    this.nameBytes,
    this.extra = const [],
    this.descriptor = false,
    this.zip64 = false,
    this.attributes = 0,
    this.disk = 0,
    this.crc,
    this.declaredSize,
  });

  final String name;
  final List<int> bytes;
  final int method;
  final int flags;
  final List<int>? nameBytes;
  final List<int> extra;
  final bool descriptor;
  final bool zip64;
  final int attributes;
  final int disk;
  final int? crc;
  final int? declaredSize;
}

class _Fixture {
  _Fixture(
    this.bytes,
    this.centralOffset,
    this.centralSize,
    this.localOffsets,
    this.dataOffsets,
    this.compressedSizes,
    this.zip64Offset,
  );
  final Uint8List bytes;
  final int centralOffset;
  final int centralSize;
  final List<int> localOffsets;
  final List<int> dataOffsets;
  final List<int> compressedSizes;
  final int? zip64Offset;
}

_Fixture _zip(
  List<_Spec> specs, {
  int commentLength = 0,
  bool zip64End = false,
  int zip64ExtensionLength = 0,
  bool descriptorSignature = true,
}) {
  final output = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  final localOffsets = <int>[];
  final dataOffsets = <int>[];
  final compressedSizes = <int>[];
  for (final spec in specs) {
    final name = spec.nameBytes ?? utf8.encode(spec.name);
    final compressed = spec.method == 8
        ? ZLibCodec(raw: true).encode(spec.bytes)
        : spec.bytes;
    final crc = spec.crc ?? archive.getCrc32(spec.bytes);
    final size = spec.declaredSize ?? spec.bytes.length;
    final flags = spec.flags | (spec.descriptor ? 8 : 0);
    final localOffset = output.length;
    localOffsets.add(localOffset);
    compressedSizes.add(compressed.length);
    final localExtra = spec.zip64
        ? _extra(1, [..._integer(size, 8), ..._integer(compressed.length, 8)])
        : <int>[];
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, spec.zip64 ? 45 : 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, spec.method, Endian.little)
      ..setUint32(14, spec.descriptor ? 0 : crc, Endian.little)
      ..setUint32(
        18,
        spec.zip64
            ? 0xffffffff
            : spec.descriptor
            ? 0
            : compressed.length,
        Endian.little,
      )
      ..setUint32(
        22,
        spec.zip64
            ? 0xffffffff
            : spec.descriptor
            ? 0
            : size,
        Endian.little,
      )
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, localExtra.length, Endian.little);
    output.add(local.buffer.asUint8List());
    output.add(name);
    output.add(localExtra);
    dataOffsets.add(output.length);
    output.add(compressed);
    if (spec.descriptor) {
      if (descriptorSignature) output.add(_integer(0x08074b50, 4));
      output.add(_integer(crc, 4));
      output.add(_integer(compressed.length, spec.zip64 ? 8 : 4));
      output.add(_integer(size, spec.zip64 ? 8 : 4));
    }
    final centralExtra = <int>[
      if (spec.zip64)
        ..._extra(1, [
          ..._integer(size, 8),
          ..._integer(compressed.length, 8),
          ..._integer(localOffset, 8),
          ..._integer(spec.disk, 4),
        ]),
      ...spec.extra,
    ];
    final central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 45, Endian.little)
      ..setUint16(6, spec.zip64 ? 45 : 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, spec.method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(
        20,
        spec.zip64 ? 0xffffffff : compressed.length,
        Endian.little,
      )
      ..setUint32(24, spec.zip64 ? 0xffffffff : size, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint16(30, centralExtra.length, Endian.little)
      ..setUint16(34, spec.zip64 ? 0xffff : spec.disk, Endian.little)
      ..setUint32(38, spec.attributes, Endian.little)
      ..setUint32(42, spec.zip64 ? 0xffffffff : localOffset, Endian.little);
    directory.add(central.buffer.asUint8List());
    directory.add(name);
    directory.add(centralExtra);
  }
  final centralOffset = output.length;
  final centralSize = directory.length;
  output.add(directory.takeBytes());
  int? zip64Offset;
  if (zip64End) {
    zip64Offset = output.length;
    final record = ByteData(56)
      ..setUint32(0, 0x06064b50, Endian.little)
      ..setUint64(4, 44 + zip64ExtensionLength, Endian.little)
      ..setUint16(12, 45, Endian.little)
      ..setUint16(14, 45, Endian.little)
      ..setUint64(24, specs.length, Endian.little)
      ..setUint64(32, specs.length, Endian.little)
      ..setUint64(40, centralSize, Endian.little)
      ..setUint64(48, centralOffset, Endian.little);
    output.add(record.buffer.asUint8List());
    output.add(Uint8List(zip64ExtensionLength));
    final locator = ByteData(20)
      ..setUint32(0, 0x07064b50, Endian.little)
      ..setUint64(8, zip64Offset, Endian.little)
      ..setUint32(16, 1, Endian.little);
    output.add(locator.buffer.asUint8List());
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, zip64End ? 0xffff : specs.length, Endian.little)
    ..setUint16(10, zip64End ? 0xffff : specs.length, Endian.little)
    ..setUint32(12, zip64End ? 0xffffffff : centralSize, Endian.little)
    ..setUint32(16, zip64End ? 0xffffffff : centralOffset, Endian.little)
    ..setUint16(20, commentLength, Endian.little);
  output.add(end.buffer.asUint8List());
  output.add(List.filled(commentLength, 0x20));
  return _Fixture(
    output.takeBytes(),
    centralOffset,
    centralSize,
    localOffsets,
    dataOffsets,
    compressedSizes,
    zip64Offset,
  );
}

List<int> _extra(int id, List<int> bytes) => [
  ..._integer(id, 2),
  ..._integer(bytes.length, 2),
  ...bytes,
];

List<int> _integer(int value, int length) =>
    List.generate(length, (index) => value >> (index * 8) & 0xff);
