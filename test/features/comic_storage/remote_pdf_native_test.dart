import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final modulePath = _existingPdfiumModule();

  group(
    'remote PDF with native PDFium',
    () {
      late Directory cacheDirectory;
      late _PdfFixture fixture;
      String? previousModulePath;
      String? previousCachePath;

      setUpAll(() {
        previousModulePath = Pdfrx.pdfiumModulePath;
        previousCachePath = Pdfrx.cacheDirectoryPath;
        cacheDirectory = Directory.systemTemp.createTempSync(
          'venera-remote-pdf-native-',
        );
        Pdfrx.pdfiumModulePath = modulePath;
        Pdfrx.cacheDirectoryPath = cacheDirectory.path;
        fixture = _pdfFixture();
      });

      tearDownAll(() {
        Pdfrx.pdfiumModulePath = previousModulePath;
        Pdfrx.cacheDirectoryPath = previousCachePath;
        cacheDirectory.deleteSync(recursive: true);
      });

      test(
        'reads bookmarks and renders the actual differently sized second page',
        () async {
          final reader = _RangeReader(fixture.bytes);
          final index = await RemotePdfReader.inspect(
            size: fixture.bytes.length,
            read: reader.read,
            sourceName: 'Native comic.pdf',
          );

          expect(index.pageCount, 3);
          expect(index.metadata!.title, 'Native comic');
          expect(index.metadata!.chapters!.map((chapter) => chapter.toJson()), [
            {'title': 'Opening', 'start': 1, 'end': 1},
            {'title': 'Second chapter', 'start': 2, 'end': 3},
          ]);

          final jpeg = await RemotePdfReader.renderPage(
            size: fixture.bytes.length,
            read: reader.read,
            sourceName: 'Native comic.pdf',
            pageNumber: 2,
            expectedPageCount: index.pageCount,
          );
          expect(jpeg.take(2), [0xff, 0xd8]);
          final rendered = image.decodeJpg(jpeg)!;
          // Page 1 is 100 x 100 pt. Page 2 is 240 x 120 pt: placeholders
          // copied from page 1 must not determine the second page's dimensions.
          expect(rendered.width, 720);
          expect(rendered.height, 360);
          final yellow = rendered.getPixel(180, 180);
          expect(yellow.r, greaterThan(240));
          expect(yellow.g, greaterThan(240));
          expect(yellow.b, lessThan(15));
          final blue = rendered.getPixel(540, 180);
          expect(blue.r, lessThan(15));
          expect(blue.g, lessThan(15));
          expect(blue.b, greaterThan(240));
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );

      test(
        'uses bounded ranges without fetching an unselected page image',
        () async {
          final reader = _RangeReader(fixture.bytes);
          await RemotePdfReader.inspect(
            size: fixture.bytes.length,
            read: reader.read,
            sourceName: 'Native comic.pdf',
          );
          _expectBoundedReads(reader.calls, fixture);
          reader.calls.clear();

          final jpeg = await RemotePdfReader.renderPage(
            size: fixture.bytes.length,
            read: reader.read,
            sourceName: 'Native comic.pdf',
            pageNumber: 2,
            expectedPageCount: 3,
          );
          expect(jpeg.take(2), [0xff, 0xd8]);
          _expectBoundedReads(reader.calls, fixture);
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );
    },
    skip: modulePath == null
        ? 'No existing native PDFium library is available on this platform.'
        : false,
  );
}

String? _existingPdfiumModule() {
  final library = Platform.isWindows
      ? 'pdfium.dll'
      : Platform.isLinux
      ? 'libpdfium.so'
      : Platform.isMacOS
      ? 'libpdfium.dylib'
      : null;
  if (library == null) return null;
  final candidates = [
    'build/native_assets/${Platform.operatingSystem}/$library',
    if (Platform.isWindows)
      '.dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_7811/win-x64/pdfium.dll',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

void _expectBoundedReads(List<(int, int)> calls, _PdfFixture fixture) {
  expect(calls, isNotEmpty);
  expect(calls.any((call) => call.$1 > 0), isTrue);
  for (final (offset, length) in calls) {
    expect(offset, greaterThanOrEqualTo(0));
    expect(length, inInclusiveRange(1, 2 * 1024 * 1024));
    expect(offset + length, lessThanOrEqualTo(fixture.bytes.length));
    expect((offset, length), isNot((0, fixture.bytes.length)));
    final (unusedOffset, unusedLength) = fixture.unusedPagePayload;
    expect(
      offset < unusedOffset + unusedLength && offset + length > unusedOffset,
      isFalse,
      reason: 'Range ($offset, $length) fetched page 3 image bytes',
    );
  }
}

class _RangeReader {
  _RangeReader(this.bytes);

  final Uint8List bytes;
  final calls = <(int, int)>[];

  Future<Uint8List> read(int offset, int length) async {
    calls.add((offset, length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

class _PdfFixture {
  const _PdfFixture(this.bytes, this.unusedPagePayload);

  final Uint8List bytes;
  final (int, int) unusedPagePayload;
}

_PdfFixture _pdfFixture() {
  final output = BytesBuilder(copy: false);
  final offsets = List<int>.filled(13, 0);

  void text(String value) => output.add(ascii.encode(value));

  void object(int id, String body) {
    offsets[id] = output.length;
    text('$id 0 obj\n$body\nendobj\n');
  }

  (int, int) stream(int id, String dictionary, Uint8List bytes) {
    offsets[id] = output.length;
    text('$id 0 obj\n<< $dictionary /Length ${bytes.length} >>\nstream\n');
    final offset = output.length;
    output.add(bytes);
    text('\nendstream\nendobj\n');
    return (offset, bytes.length);
  }

  text('%PDF-1.7\n');
  output.add([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  object(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] '
    '/Resources << >> /Contents 6 0 R >>',
  );
  object(
    4,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] '
    '/Resources << >> /Contents 7 0 R >>',
  );
  object(
    5,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 256 256] '
    '/Resources << /XObject << /Unused 8 0 R >> >> /Contents 11 0 R >>',
  );
  stream(
    6,
    '',
    Uint8List.fromList(ascii.encode('q 1 0 0 rg 0 0 100 100 re f Q')),
  );
  stream(
    7,
    '',
    Uint8List.fromList(
      ascii.encode('q 0 0 1 rg 0 0 240 120 re f 1 1 0 rg 0 0 120 120 re f Q'),
    ),
  );
  object(9, '<< /Type /Outlines /First 10 0 R /Last 12 0 R /Count 2 >>');
  object(
    10,
    '<< /Title (Opening) /Parent 9 0 R /Next 12 0 R /Dest [3 0 R /Fit] >>',
  );
  object(
    12,
    '<< /Title (Second chapter) /Parent 9 0 R /Prev 10 0 R '
    '/Dest [4 0 R /Fit] >>',
  );
  stream(
    11,
    '',
    Uint8List.fromList(ascii.encode('q 256 0 0 256 0 0 cm /Unused Do Q')),
  );

  // Keep the unused image away from both document structures and the trailer.
  // The fixture's xref offsets let PDFium seek across these gaps directly.
  final padding = Uint8List(2 * 1024 * 1024)
    ..fillRange(0, 2 * 1024 * 1024, 0x20);
  output.add(padding);
  final unusedImage = Uint8List(1024 * 2048 * 3)
    ..fillRange(0, 1024 * 2048 * 3, 0x80);
  final unusedPayload = stream(
    8,
    '/Type /XObject /Subtype /Image /Width 1024 /Height 2048 '
    '/ColorSpace /DeviceRGB /BitsPerComponent 8',
    unusedImage,
  );
  output.add(padding);
  final xrefOffset = output.length;
  text('xref\n0 13\n0000000000 65535 f \n');
  for (var id = 1; id < offsets.length; id++) {
    text('${offsets[id].toString().padLeft(10, '0')} 00000 n \n');
  }
  text('trailer\n<< /Size 13 /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n');
  return _PdfFixture(output.takeBytes(), unusedPayload);
}
