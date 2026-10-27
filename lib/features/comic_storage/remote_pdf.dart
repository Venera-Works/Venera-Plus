import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pdfrx/pdfrx.dart';

import 'archive_metadata.dart';
import 'comic_file_rules.dart';
import 'pdf_render.dart';
import 'remote_zip.dart';

typedef RemotePdfCustomRead =
    Future<int> Function(Uint8List buffer, int position, int size);
typedef RemotePdfDocumentOpener =
    Future<PdfDocument> Function({
      required RemotePdfCustomRead read,
      required int size,
      required String sourceName,
      required bool useProgressiveLoading,
      required int maxSizeToCacheOnMemory,
    });

class RemotePdfIndex {
  const RemotePdfIndex({required this.pageCount, this.metadata});
  final int pageCount;

  /// Null without usable chapters: filename fallback must not mask scraping.
  final ComicMetaData? metadata;
}

abstract final class RemotePdfReader {
  @visibleForTesting
  static RemotePdfDocumentOpener? debugOpenDocument;

  static Future<RemotePdfIndex> inspect({
    required int size,
    required ZipRangeRead read,
    required String sourceName,
    String? fallbackTitle,
    CancelToken? cancelToken,
  }) => _withDocument(
    size: size,
    read: read,
    sourceName: sourceName,
    cancelToken: cancelToken,
    action: (document, operation) async {
      final count = document.pages.length;
      final outline = await document.loadOutline();
      operation.throwIfFailed();
      final title = fallbackTitle?.trim().isNotEmpty == true
          ? fallbackTitle!
          : comicFileStem(sourceName).isNotEmpty
          ? comicFileStem(sourceName)
          : 'PDF';
      final chapters = _outlineChapters(outline, count, title);
      return RemotePdfIndex(
        pageCount: count,
        metadata: chapters == null
            ? null
            : ComicMetaData(
                title: title,
                author: '',
                tags: const [],
                chapters: chapters,
              ),
      );
    },
  );

  static Future<Uint8List> renderPage({
    required int size,
    required ZipRangeRead read,
    required String sourceName,
    required int pageNumber,
    int? expectedPageCount,
    CancelToken? cancelToken,
  }) {
    if (pageNumber < 1) {
      throw const FormatException('PDF page number must be positive');
    }
    return _withDocument(
      size: size,
      read: read,
      sourceName: sourceName,
      cancelToken: cancelToken,
      action: (document, operation) async {
        if (expectedPageCount != null &&
            document.pages.length != expectedPageCount) {
          throw const FormatException('PDF page count changed');
        }
        if (pageNumber > document.pages.length) {
          throw const FormatException(
            'PDF page number is outside the document',
          );
        }
        if (!document.pages[pageNumber - 1].isLoaded) {
          // pdfrx_engine 0.4.5 reloadPages([n]) overwrites slot 0, leaving n a
          // placeholder. Progress only to the requested page instead.
          await document.loadPagesProgressively<void>(
            onPageLoadProgress: (loaded, total, _) =>
                !operation.hasFailed && loaded < pageNumber,
            loadUnitDuration: Duration.zero,
          );
          operation.throwIfFailed();
        }
        final page = document.pages[pageNumber - 1];
        if (!page.isLoaded) {
          throw const FormatException('PDF page could not be loaded');
        }
        final renderSize = calculatePdfRenderSize(page.width, page.height);
        final nativeCancel = page.createCancellationToken();
        operation.renderCancellation.token = nativeCancel;
        operation.throwIfFailed();
        final rendered = await page.render(
          fullWidth: renderSize.width.toDouble(),
          fullHeight: renderSize.height.toDouble(),
          cancellationToken: nativeCancel,
        );
        operation.renderCancellation.token = null;
        try {
          operation.throwIfFailed();
          if (rendered == null) throw PdfPageRenderException(pageNumber);
          final result = await encodePdfPageJpeg(
            pixels: rendered.pixels,
            width: rendered.width,
            height: rendered.height,
          );
          operation.throwIfFailed();
          return result;
        } finally {
          operation.renderCancellation.token = null;
          rendered?.dispose();
        }
      },
    );
  }

  static Future<T> _withDocument<T>({
    required int size,
    required ZipRangeRead read,
    required String sourceName,
    required CancelToken? cancelToken,
    required Future<T> Function(PdfDocument document, _PdfOperation operation)
    action,
  }) async {
    if (size <= 0 || size > 0x1fffffffffffff) {
      throw const FormatException('Invalid PDF file size');
    }
    final operation = _PdfOperation(size, read, cancelToken);
    operation.throwIfFailed();
    PdfDocument? document;
    T? result;
    Object? failure;
    StackTrace? failureStack;
    try {
      document = await (debugOpenDocument ?? _openDocument)(
        read: operation.readNative,
        size: size,
        sourceName: sourceName,
        useProgressiveLoading: true,
        maxSizeToCacheOnMemory: 0,
      );
      operation.throwIfFailed();
      if (document.isEncrypted) {
        throw const FormatException('Encrypted PDF files are not supported');
      }
      if (document.pages.isEmpty) {
        throw const FormatException('PDF contains no pages');
      }
      result = await action(document, operation);
      operation.throwIfFailed();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // No early Future.any return: the renderer has finished before closing.
      operation.renderCancellation.token = null;
      if (document != null) {
        try {
          await document.dispose();
        } catch (error, stack) {
          if (failure == null) {
            failure = error;
            failureStack = stack;
          }
        }
      }
    }
    operation.throwIfFailed();
    if (failure is PdfPasswordException) {
      // This engine also reports malformed/native-open failures as password errors.
      throw const FormatException(
        'PDF could not be opened or requires a password',
      );
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    return result as T;
  }
}

Future<PdfDocument> _openDocument({
  required RemotePdfCustomRead read,
  required int size,
  required String sourceName,
  required bool useProgressiveLoading,
  required int maxSizeToCacheOnMemory,
}) async {
  await pdfrxFlutterInitialize();
  return PdfDocument.openCustom(
    read: read,
    fileSize: size,
    sourceName: sourceName,
    passwordProvider: () => null,
    useProgressiveLoading: useProgressiveLoading,
    maxSizeToCacheOnMemory: maxSizeToCacheOnMemory,
  );
}

class _RenderCancellation {
  PdfPageRenderCancellationToken? token;
}

// The future callback retains only this cleared link, never a document or read.
void _bindCancellation(CancelToken? token, _RenderCancellation link) {
  token?.whenCancel.then((_) => link.token?.cancel());
}

class _PdfOperation {
  _PdfOperation(this.size, this.read, this.cancelToken)
    : callerZone = Zone.current {
    _bindCancellation(cancelToken, renderCancellation);
  }

  final int size;
  final ZipRangeRead read;
  final CancelToken? cancelToken;
  final Zone callerZone;
  final renderCancellation = _RenderCancellation();
  Object? _readFailure;
  StackTrace? _readFailureStack;

  bool get hasFailed =>
      _readFailure != null || cancelToken?.isCancelled == true;

  void throwIfFailed() {
    if (_readFailure != null) {
      Error.throwWithStackTrace(_readFailure!, _readFailureStack!);
    }
    final cancelled = cancelToken?.cancelError;
    if (cancelled != null) {
      Error.throwWithStackTrace(cancelled, cancelled.stackTrace);
    }
  }

  Future<int> readNative(Uint8List buffer, int position, int length) async {
    try {
      throwIfFailed();
      if (position < 0 ||
          length < 0 ||
          length > buffer.length ||
          position > size ||
          length > size - position) {
        throw const FormatException('PDF byte range is outside the document');
      }
      const window = 256 * 1024;
      const maxRead = 2 * 1024 * 1024;
      var copied = 0;
      while (copied < length) {
        throwIfFailed();
        final current = position + copied;
        final start = current ~/ window * window;
        final room = maxRead - (current - start);
        final count = length - copied < room ? length - copied : room;
        final roundedEnd = (current + count + window - 1) ~/ window * window;
        final end = roundedEnd < size ? roundedEnd : size;
        final bytes = await callerZone.run(() => read(start, end - start));
        throwIfFailed();
        if (bytes.length != end - start) {
          throw const FormatException(
            'PDF range response has an unexpected length',
          );
        }
        buffer.setRange(copied, copied + count, bytes, current - start);
        copied += count;
      }
      return length;
    } catch (error, stack) {
      _readFailure ??= error;
      _readFailureStack ??= stack;
      // The native bridge treats any nonzero result (including -1) as success.
      // Report failure without throwing through the NativeCallable listener.
      return 0;
    }
  }
}

List<ComicChapter>? _outlineChapters(
  List<PdfOutlineNode> outline,
  int count,
  String fallbackTitle,
) {
  final markers = <int, String>{};
  void visit(List<PdfOutlineNode> nodes, String parent) {
    for (final node in nodes) {
      final title = node.title.trim();
      final label = parent.isEmpty
          ? title
          : title.isEmpty
          ? parent
          : '$parent/$title';
      final page = node.dest?.pageNumber;
      if (title.isNotEmpty && page != null && page >= 1 && page <= count) {
        markers.putIfAbsent(page, () => label);
      }
      visit(node.children, label);
    }
  }

  visit(outline, '');
  if (markers.length < 2) return null;
  final starts = markers.keys.toList()..sort();
  final chapters = <ComicChapter>[
    if (starts.first > 1)
      ComicChapter(title: fallbackTitle, start: 1, end: starts.first - 1),
    for (var i = 0; i < starts.length; i++)
      ComicChapter(
        title: markers[starts[i]]!,
        start: starts[i],
        end: i + 1 < starts.length ? starts[i + 1] - 1 : count,
      ),
  ];
  return chapters;
}
