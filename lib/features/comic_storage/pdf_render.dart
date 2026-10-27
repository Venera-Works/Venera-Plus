import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as image;

const double _pdfRenderScale = 3;
const int _pdfRenderMaxEdge = 3000;

class PdfRenderSize {
  const PdfRenderSize(this.width, this.height);
  final int width;
  final int height;
}

class PdfPageRenderException implements Exception {
  const PdfPageRenderException(this.page);
  final int page;

  @override
  String toString() => 'Failed to render PDF page $page';
}

PdfRenderSize calculatePdfRenderSize(
  double width,
  double height, {
  double scale = _pdfRenderScale,
  int maxEdge = _pdfRenderMaxEdge,
}) {
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    throw const FormatException('PDF page has an invalid size');
  }
  final longestEdge = math.max(width, height);
  final actualScale = math.min(scale, maxEdge / longestEdge);
  return PdfRenderSize(
    math.max(1, (width * actualScale).round()),
    math.max(1, (height * actualScale).round()),
  );
}

/// Only pixels cross the isolate boundary; native PDF objects stay with pdfrx.
Future<Uint8List> encodePdfPageJpeg({
  required Uint8List pixels,
  required int width,
  required int height,
}) => compute(_encodePdfPage, (
  pixels: pixels,
  width: width,
  height: height,
), debugLabel: 'PDF JPEG encoding');

Uint8List _encodePdfPage(({Uint8List pixels, int width, int height}) page) {
  final decoded = image.Image.fromBytes(
    width: page.width,
    height: page.height,
    bytes: page.pixels.buffer,
    bytesOffset: page.pixels.offsetInBytes,
    order: image.ChannelOrder.bgra,
  );
  return image.encodeJpg(decoded, quality: 92);
}
