import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:enough_convert/enough_convert.dart';

/// Reads exactly [length] bytes at the absolute archive [offset].
typedef ZipRangeRead = Future<Uint8List> Function(int offset, int length);

// Keep offsets exact when an index is serialized or used on the web.
const _maxZipInteger = 0x1fffffffffffff;
const _zipFooterWindow = 0xffff + 22 + 20 + 56;

class RemoteZipEntry {
  const RemoteZipEntry._({
    required this.name,
    required this.flags,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  factory RemoteZipEntry.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String) {
      throw const FormatException('ZIP entry name must be a string');
    }
    final entry = RemoteZipEntry._(
      name: _normalizeName(name),
      flags: _jsonInteger(json, 'flags', max: 0xffff),
      compressionMethod: _jsonInteger(json, 'compressionMethod', max: 0xffff),
      crc32: _jsonInteger(json, 'crc32', max: 0xffffffff),
      compressedSize: _jsonInteger(json, 'compressedSize'),
      uncompressedSize: _jsonInteger(json, 'uncompressedSize'),
      localHeaderOffset: _jsonInteger(json, 'localHeaderOffset'),
    );
    entry._validate();
    return entry;
  }

  /// A safe, relative path using `/`, with a trailing `/` for directories.
  final String name;
  final int flags;
  final int compressionMethod;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  bool get isDirectory => name.endsWith('/');

  Map<String, dynamic> toJson() => {
    'name': name,
    'flags': flags,
    'compressionMethod': compressionMethod,
    'crc32': crc32,
    'compressedSize': compressedSize,
    'uncompressedSize': uncompressedSize,
    'localHeaderOffset': localHeaderOffset,
  };

  void _validate() {
    if (flags & 0x2041 != 0) {
      throw UnsupportedError('Encrypted ZIP entries are not supported');
    }
    if (compressionMethod != 0 && compressionMethod != 8) {
      throw UnsupportedError(
        'ZIP compression method $compressionMethod is not supported',
      );
    }
    if (compressionMethod == 0 && compressedSize != uncompressedSize) {
      throw const FormatException('Stored ZIP entry has inconsistent sizes');
    }
  }
}

/// A central-directory index. Creating it never traverses local file headers.
class RemoteZipIndex {
  RemoteZipIndex._(
    this.fileSize,
    this._centralDirectoryOffset,
    List<RemoteZipEntry> entries,
  ) : entries = List.unmodifiable(entries) {
    for (final entry in entries) {
      _checkRange(entry.localHeaderOffset, 30, _centralDirectoryOffset);
      _checkRange(
        entry.localHeaderOffset + 30,
        entry.compressedSize,
        _centralDirectoryOffset,
      );
    }
  }

  factory RemoteZipIndex.fromJson(Map<String, dynamic> json) {
    final size = _jsonInteger(json, 'fileSize');
    final centralOffset = _jsonInteger(json, 'centralDirectoryOffset');
    final items = json['entries'];
    if (size < 22 || centralOffset > size - 22 || items is! List) {
      throw const FormatException('Invalid ZIP index');
    }
    final entries = items.map((item) {
      if (item is! Map) {
        throw const FormatException('ZIP index entries must be objects');
      }
      return RemoteZipEntry.fromJson(Map<String, dynamic>.from(item));
    }).toList();
    return RemoteZipIndex._(size, centralOffset, entries);
  }

  final int fileSize;
  final int _centralDirectoryOffset;
  final List<RemoteZipEntry> entries;

  Map<String, dynamic> toJson() => {
    'fileSize': fileSize,
    'centralDirectoryOffset': _centralDirectoryOffset,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  static Future<RemoteZipIndex> read({
    required int fileSize,
    required ZipRangeRead read,
  }) async {
    if (fileSize < 22 || fileSize > _maxZipInteger) {
      throw const FormatException('Invalid ZIP file size');
    }
    final tailSize = fileSize < _zipFooterWindow ? fileSize : _zipFooterWindow;
    final tailOffset = fileSize - tailSize;
    final tail = await _readExact(read, tailOffset, tailSize, fileSize);
    final footer = ByteData.sublistView(tail);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(footer, i) == 0x06054b50 &&
          i + 22 + _u16(footer, i + 20) == tail.length) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw const FormatException('ZIP end record was not found');
    }
    if (_u16(footer, end + 4) != 0 || _u16(footer, end + 6) != 0) {
      throw UnsupportedError('Split ZIP archives are not supported');
    }
    var count = _u16(footer, end + 10);
    var directorySize = _u32(footer, end + 12);
    var directoryOffset = _u32(footer, end + 16);
    var directoryLimit = tailOffset + end;
    final needsZip64 =
        count == 0xffff ||
        _u16(footer, end + 8) == 0xffff ||
        directorySize == 0xffffffff ||
        directoryOffset == 0xffffffff;
    final locator = end - 20;
    if (locator >= 0 && _u32(footer, locator) == 0x07064b50) {
      if (_u32(footer, locator + 4) != 0 || _u32(footer, locator + 16) != 1) {
        throw UnsupportedError('Split ZIP64 archives are not supported');
      }
      final recordOffset = _u64(footer, locator + 8);
      final locatorOffset = tailOffset + locator;
      _checkRange(recordOffset, 56, locatorOffset);
      final recordBytes = recordOffset >= tailOffset
          ? Uint8List.sublistView(
              tail,
              recordOffset - tailOffset,
              recordOffset - tailOffset + 56,
            )
          : await _readExact(read, recordOffset, 56, locatorOffset);
      final record = ByteData.sublistView(recordBytes);
      if (_u32(record, 0) != 0x06064b50) {
        throw const FormatException('Invalid ZIP64 end record');
      }
      final recordSize = _u64(record, 4);
      if (recordSize < 44 || recordSize != locatorOffset - recordOffset - 12) {
        throw const FormatException('Invalid ZIP64 end record size');
      }
      if (_u32(record, 16) != 0 ||
          _u32(record, 20) != 0 ||
          _u64(record, 24) != _u64(record, 32)) {
        throw UnsupportedError('Split ZIP64 archives are not supported');
      }
      count = _u64(record, 32);
      directorySize = _u64(record, 40);
      directoryOffset = _u64(record, 48);
      directoryLimit = recordOffset;
    } else if (needsZip64) {
      throw const FormatException('ZIP64 end locator was not found');
    } else if (_u16(footer, end + 8) != count) {
      throw UnsupportedError('Split ZIP archives are not supported');
    }
    _checkRange(directoryOffset, directorySize, directoryLimit);
    if (count > directorySize ~/ 46) {
      throw const FormatException('ZIP entry count exceeds directory size');
    }
    final directory = directoryOffset >= tailOffset
        ? Uint8List.sublistView(
            tail,
            directoryOffset - tailOffset,
            directoryOffset - tailOffset + directorySize,
          )
        : await _readExact(read, directoryOffset, directorySize, fileSize);
    final entries = _readDirectory(directory, count);
    return RemoteZipIndex._(fileSize, directoryOffset, entries);
  }

  /// Reads only this entry's fixed local header and compressed payload.
  /// Data descriptors need no extra request: central-directory sizes are final.
  Future<Uint8List> readEntry(RemoteZipEntry entry, ZipRangeRead read) async {
    if (!entries.contains(entry)) {
      throw ArgumentError.value(
        entry,
        'entry',
        'Entry is not in this ZIP index',
      );
    }
    final headerBytes = await _readExact(
      read,
      entry.localHeaderOffset,
      30,
      _centralDirectoryOffset,
    );
    final header = ByteData.sublistView(headerBytes);
    if (_u32(header, 0) != 0x04034b50 ||
        _u16(header, 6) != entry.flags ||
        _u16(header, 8) != entry.compressionMethod) {
      throw const FormatException('ZIP local header does not match directory');
    }
    if (entry.flags & 8 == 0) {
      final localCompressedSize = _u32(header, 18);
      final localSize = _u32(header, 22);
      if (_u32(header, 14) != entry.crc32 ||
          localCompressedSize != 0xffffffff &&
              localCompressedSize != entry.compressedSize ||
          localSize != 0xffffffff && localSize != entry.uncompressedSize) {
        throw const FormatException('ZIP local sizes or CRC do not match');
      }
    }
    final dataOffset =
        entry.localHeaderOffset + 30 + _u16(header, 26) + _u16(header, 28);
    final compressed = await _readExact(
      read,
      dataOffset,
      entry.compressedSize,
      _centralDirectoryOffset,
    );
    return _decodeEntry(
      compressed,
      entry.compressionMethod,
      entry.uncompressedSize,
      entry.crc32,
    );
  }
}

// This closure only captures bytes and integers, never a network callback or
// the index. Isolate.run also transfers the resulting byte buffer on return.
Future<Uint8List> _decodeEntry(
  Uint8List compressed,
  int compressionMethod,
  int uncompressedSize,
  int crc32,
) => Isolate.run(() {
  Uint8List result;
  if (compressionMethod == 0) {
    result = compressed;
  } else {
    try {
      final output = _EntryOutput(uncompressedSize);
      result = archive.Inflate(compressed, output: output).getBytes();
    } catch (error) {
      throw FormatException('Invalid ZIP deflate data: $error');
    }
  }
  if (result.length != uncompressedSize) {
    throw const FormatException('ZIP entry decompressed length does not match');
  }
  if (archive.getCrc32(result) != crc32) {
    throw const FormatException('ZIP entry CRC does not match');
  }
  return result;
});

List<RemoteZipEntry> _readDirectory(Uint8List bytes, int count) {
  final data = ByteData.sublistView(bytes);
  final entries = <RemoteZipEntry>[];
  var offset = 0;
  for (var i = 0; i < count; i++) {
    _checkRange(offset, 46, bytes.length);
    if (_u32(data, offset) != 0x02014b50) {
      throw const FormatException('Invalid ZIP central directory entry');
    }
    final nameLength = _u16(data, offset + 28);
    final extraLength = _u16(data, offset + 30);
    final commentLength = _u16(data, offset + 32);
    final length = 46 + nameLength + extraLength + commentLength;
    _checkRange(offset, length, bytes.length);
    final rawName = Uint8List.sublistView(
      bytes,
      offset + 46,
      offset + 46 + nameLength,
    );
    final extra = Uint8List.sublistView(
      bytes,
      offset + 46 + nameLength,
      offset + 46 + nameLength + extraLength,
    );
    var size = _u32(data, offset + 24);
    var compressedSize = _u32(data, offset + 20);
    var localOffset = _u32(data, offset + 42);
    var disk = _u16(data, offset + 34);
    final flags = _u16(data, offset + 8);
    String? unicodeName;
    var foundZip64 = false;
    for (final field in _extraFields(extra)) {
      if (field.$1 == 1) {
        foundZip64 = true;
        final zip64 = ByteData.sublistView(field.$2);
        var cursor = 0;
        int next64() {
          _checkRange(cursor, 8, zip64.lengthInBytes);
          final value = _u64(zip64, cursor);
          cursor += 8;
          return value;
        }

        if (size == 0xffffffff) size = next64();
        if (compressedSize == 0xffffffff) compressedSize = next64();
        if (localOffset == 0xffffffff) localOffset = next64();
        if (disk == 0xffff) {
          _checkRange(cursor, 4, zip64.lengthInBytes);
          disk = _u32(zip64, cursor);
        }
      } else if (field.$1 == 0x7075 && field.$2.length >= 5) {
        final unicode = field.$2;
        if (unicode[0] == 1 &&
            _u32(ByteData.sublistView(unicode), 1) ==
                archive.getCrc32(rawName)) {
          unicodeName = utf8.decode(unicode.sublist(5));
        }
      }
    }
    if (!foundZip64 &&
        (size == 0xffffffff ||
            compressedSize == 0xffffffff ||
            localOffset == 0xffffffff ||
            disk == 0xffff)) {
      throw const FormatException('ZIP64 entry extra field was not found');
    }
    if (disk != 0) {
      throw UnsupportedError('Split ZIP archives are not supported');
    }
    var name = _normalizeName(
      flags & 0x800 != 0
          ? utf8.decode(rawName)
          : unicodeName ?? _decodeLegacyName(rawName),
    );
    final attributes = _u32(data, offset + 38);
    if ((attributes & 0x10 != 0 || attributes >> 16 & 0xf000 == 0x4000) &&
        !name.endsWith('/')) {
      name = '$name/';
    }
    final entry = RemoteZipEntry._(
      name: name,
      flags: flags,
      compressionMethod: _u16(data, offset + 10),
      crc32: _u32(data, offset + 16),
      compressedSize: compressedSize,
      uncompressedSize: size,
      localHeaderOffset: localOffset,
    );
    entry._validate();
    entries.add(entry);
    offset += length;
  }
  // The optional central-directory digital signature follows all entries.
  if (offset != bytes.length &&
      (offset + 6 > bytes.length ||
          _u32(data, offset) != 0x05054b50 ||
          offset + 6 + _u16(data, offset + 4) != bytes.length)) {
    throw const FormatException('ZIP central directory length does not match');
  }
  return entries;
}

Iterable<(int, Uint8List)> _extraFields(Uint8List bytes) sync* {
  final data = ByteData.sublistView(bytes);
  var offset = 0;
  while (offset < bytes.length) {
    _checkRange(offset, 4, bytes.length);
    final id = _u16(data, offset);
    final length = _u16(data, offset + 2);
    offset += 4;
    _checkRange(offset, length, bytes.length);
    yield (id, Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
  }
}

String _decodeLegacyName(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    try {
      return const GbkCodec().decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}

String _normalizeName(String name) {
  final path = name.replaceAll('\\', '/');
  if (path.startsWith('/') || path.contains('\u0000') || path.contains(':')) {
    throw const FormatException('ZIP entry path must be a safe relative path');
  }
  final parts = path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.isEmpty || parts.contains('..')) {
    throw const FormatException('ZIP entry path is empty or escapes its root');
  }
  return '${parts.join('/')}${path.endsWith('/') ? '/' : ''}';
}

int _jsonInteger(
  Map<String, dynamic> json,
  String key, {
  int max = _maxZipInteger,
}) {
  final value = json[key];
  if (value is! int || value < 0 || value > max) {
    throw FormatException('ZIP index $key must be an integer from 0 to $max');
  }
  return value;
}

void _checkRange(int offset, int length, int limit) {
  if (offset < 0 || length < 0 || offset > limit || length > limit - offset) {
    throw const FormatException('ZIP byte range is outside the archive');
  }
}

Future<Uint8List> _readExact(
  ZipRangeRead read,
  int offset,
  int length,
  int limit,
) async {
  _checkRange(offset, length, limit);
  if (length == 0) return Uint8List(0);
  final bytes = await read(offset, length);
  if (bytes.length != length) {
    throw const FormatException('ZIP range response has an unexpected length');
  }
  return bytes;
}

int _u16(ByteData data, int offset) => data.getUint16(offset, Endian.little);
int _u32(ByteData data, int offset) => data.getUint32(offset, Endian.little);
int _u64(ByteData data, int offset) {
  final high = _u32(data, offset + 4);
  if (high > 0x1fffff) {
    throw UnsupportedError('ZIP64 value exceeds the exact integer range');
  }
  return high * 0x100000000 + _u32(data, offset);
}

/// Stop malformed deflate streams before they exceed the declared entry size.
class _EntryOutput extends archive.OutputMemoryStream {
  _EntryOutput(this.limit) : super(size: limit < 32768 ? limit : 32768);

  final int limit;

  void _checkLength(int count) {
    if (count > limit - length) {
      throw const FormatException('ZIP entry exceeds its decompressed size');
    }
  }

  @override
  void writeByte(int value) {
    _checkLength(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _checkLength(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(archive.InputStream stream) {
    _checkLength(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _checkLength(count);
    super.writeBackReference(distance, count);
  }
}
