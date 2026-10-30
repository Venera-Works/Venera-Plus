import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import 'archive_metadata.dart';
import 'comic_file_rules.dart';
import 'pdf_render.dart';
import 'remote_zip.dart';

typedef RemotePdfDocumentOpener =
    Future<RemotePdfDocument> Function({
      required ZipRangeRead read,
      required int size,
      required String sourceName,
      CancelToken? cancelToken,
    });

abstract interface class RemotePdfDocument {
  int get pageCount;
  bool get isEncrypted;
  Future<List<PdfOutlineNode>> loadOutline();
  Future<Uint8List> renderPage(int pageNumber);
  Future<void> dispose();
}

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
    action: (document) async {
      final count = document.pageCount;
      final outline = await document.loadOutline();
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
      action: (document) async {
        if (expectedPageCount != null &&
            document.pageCount != expectedPageCount) {
          throw const FormatException('PDF page count changed');
        }
        if (pageNumber > document.pageCount) {
          throw const FormatException(
            'PDF page number is outside the document',
          );
        }
        return document.renderPage(pageNumber);
      },
    );
  }

  static Future<T> _withDocument<T>({
    required int size,
    required ZipRangeRead read,
    required String sourceName,
    required CancelToken? cancelToken,
    required Future<T> Function(RemotePdfDocument document) action,
  }) async {
    // FPDF_FILEACCESS uses unsigned long, which is 32 bits on Windows.
    final maxSize = sizeOf<UnsignedLong>() == 4 ? 0xffffffff : 0x1fffffffffffff;
    if (size <= 0 || size > maxSize) {
      throw const FormatException('Invalid PDF file size');
    }
    final operation = _PdfOperation(size, read, cancelToken);
    operation.throwIfCancelled();
    RemotePdfDocument? document;
    T? result;
    Object? failure;
    StackTrace? failureStack;
    try {
      document = await (debugOpenDocument ?? _NativePdfDocument.open)(
        read: operation.readRange,
        size: size,
        sourceName: sourceName,
        cancelToken: cancelToken,
      );
      operation.throwIfCancelled();
      if (document.isEncrypted) {
        throw const FormatException('Encrypted PDF files are not supported');
      }
      if (document.pageCount <= 0) {
        throw const FormatException('PDF contains no pages');
      }
      result = await action(document);
      operation.throwIfCancelled();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Await every native call before releasing its document and callbacks.
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
    if (failure is PdfPasswordException) {
      throw const FormatException('PDF document is unreadable or encrypted');
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    operation.throwIfCancelled();
    return result as T;
  }
}

class _PdfOperation {
  _PdfOperation(this.size, this.read, this.cancelToken)
    : callerZone = Zone.current;

  final int size;
  final ZipRangeRead read;
  final CancelToken? cancelToken;
  final Zone callerZone;

  void throwIfCancelled() => _throwIfCancelled(cancelToken);

  Future<Uint8List> readRange(int offset, int length) async {
    throwIfCancelled();
    if (offset < 0 || length <= 0 || offset > size || length > size - offset) {
      throw const FormatException('PDF byte range is outside the document');
    }
    final bytes = await callerZone.run(() => read(offset, length));
    throwIfCancelled();
    if (bytes.length != length) {
      throw const FormatException(
        'PDF range response has an unexpected length',
      );
    }
    return bytes;
  }
}

void _throwIfCancelled(CancelToken? token) {
  final error = token?.cancelError;
  if (error != null) Error.throwWithStackTrace(error, error.stackTrace);
}

const _pdfWindow = 256 * 1024;
const _pdfMaxRead = 2 * 1024 * 1024;
typedef _PdfRange = (int offset, int length);
typedef _PdfStep<T> = ({T? value, List<_PdfRange> missing});

class _NativePdfDocument implements RemotePdfDocument {
  _NativePdfDocument(this.id, this.read, this.cancelToken);

  final int id;
  final ZipRangeRead read;
  final CancelToken? cancelToken;
  @override
  late final int pageCount;
  @override
  late final bool isEncrypted;

  static Future<RemotePdfDocument> open({
    required ZipRangeRead read,
    required int size,
    required String sourceName,
    CancelToken? cancelToken,
  }) async {
    await pdfrxFlutterInitialize();
    _throwIfCancelled(cancelToken);
    final id = await PdfrxEntryFunctions.instance.compute(
      _createNativePdf,
      size,
    );
    final document = _NativePdfDocument(id, read, cancelToken);
    try {
      final info = await document._untilReady(_openNativePdf, id);
      document.pageCount = info.$1;
      document.isEncrypted = info.$2;
      return document;
    } catch (error, stack) {
      try {
        await document.dispose();
      } finally {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  Future<T> _untilReady<P, T>(_PdfStep<T> Function(P) action, P params) async {
    while (true) {
      _throwIfCancelled(cancelToken);
      final step = await PdfrxEntryFunctions.instance.compute(action, params);
      _throwIfCancelled(cancelToken);
      if (step.value != null) return step.value as T;
      if (step.missing.isEmpty) {
        throw const FormatException('PDF data is incomplete or corrupted');
      }
      for (final (offset, length) in step.missing) {
        final bytes = await read(offset, length);
        _throwIfCancelled(cancelToken);
        await PdfrxEntryFunctions.instance.compute(_storeNativePdfRange, (
          id,
          offset,
          bytes,
        ));
      }
    }
  }

  @override
  Future<List<PdfOutlineNode>> loadOutline() =>
      _untilReady(_outlineNativePdf, id);

  @override
  Future<Uint8List> renderPage(int pageNumber) async {
    final dimensions = await _untilReady(_loadNativePdfPage, (id, pageNumber));
    final size = calculatePdfRenderSize(dimensions.$1, dimensions.$2);
    final pixels = malloc<Uint8>(size.width * size.height * 4);
    try {
      _throwIfCancelled(cancelToken);
      await _untilReady(_renderNativePdfPage, (
        id: id,
        buffer: pixels.address,
        width: size.width,
        height: size.height,
      ));
      _throwIfCancelled(cancelToken);
      return await encodePdfPageJpeg(
        pixels: pixels.asTypedList(size.width * size.height * 4),
        width: size.width,
        height: size.height,
      );
    } finally {
      malloc.free(pixels);
    }
  }

  @override
  Future<void> dispose() =>
      PdfrxEntryFunctions.instance.compute(_disposeNativePdf, id);
}

// These objects live only on pdfrx's existing serialized PDFium worker.
final _nativePdfs = <int, _NativePdfState>{};
final _remotePdfium = pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

int _createNativePdf(int size) {
  final state = _NativePdfState(size);
  final id = state.availability.address;
  _nativePdfs[id] = state;
  return id;
}

void _disposeNativePdf(int id) => _nativePdfs.remove(id)!.dispose();

void _storeNativePdfRange((int, int, Uint8List) params) {
  final (id, offset, bytes) = params;
  final state = _nativePdfs[id]!;
  for (var at = 0; at < bytes.length; at += _pdfWindow) {
    state.blocks[(offset + at) ~/ _pdfWindow] = Uint8List.sublistView(
      bytes,
      at,
      math.min(at + _pdfWindow, bytes.length),
    );
  }
}

_PdfStep<(int, bool)> _openNativePdf(int id) {
  final state = _nativePdfs[id]!;
  final api = state.api;
  if (state.document == nullptr) {
    final status = api.FPDFAvail_IsDocAvail(state.availability, state.hints);
    if (status == pdfium.PDF_DATA_ERROR) {
      throw const FormatException('PDF document data is corrupted');
    }
    if (status != pdfium.PDF_DATA_AVAIL) return state.step(null);
    state.document = api.FPDFAvail_GetDocument(state.availability, nullptr);
    if (state.document == nullptr) {
      if (state.pending.isNotEmpty) return state.step(null);
      throw const FormatException('PDF document is unreadable or encrypted');
    }
  }
  return state.step((
    api.FPDF_GetPageCount(state.document),
    api.FPDF_GetSecurityHandlerRevision(state.document) >= 0,
  ));
}

_PdfStep<List<PdfOutlineNode>> _outlineNativePdf(int id) {
  final state = _nativePdfs[id]!;
  final api = state.api;
  final seen = <int>{};
  final outline = using((arena) {
    List<PdfOutlineNode> siblings(pdfium.FPDF_BOOKMARK bookmark) {
      final nodes = <PdfOutlineNode>[];
      while (bookmark != nullptr && seen.add(bookmark.address)) {
        final length = api.FPDFBookmark_GetTitle(bookmark, nullptr, 0);
        final buffer = arena<Uint16>(math.max(1, length ~/ 2));
        api.FPDFBookmark_GetTitle(bookmark, buffer.cast(), length);
        final dest = api.FPDFBookmark_GetDest(state.document, bookmark);
        final page = dest == nullptr
            ? -1
            : api.FPDFDest_GetDestPageIndex(state.document, dest);
        nodes.add(
          PdfOutlineNode(
            title: length <= 2 ? '' : buffer.cast<Utf16>().toDartString(),
            dest: page < 0
                ? null
                : PdfDest(page + 1, PdfDestCommand.unknown, null),
            children: siblings(
              api.FPDFBookmark_GetFirstChild(state.document, bookmark),
            ),
          ),
        );
        bookmark = api.FPDFBookmark_GetNextSibling(state.document, bookmark);
      }
      return nodes;
    }

    return siblings(api.FPDFBookmark_GetFirstChild(state.document, nullptr));
  });
  // Bookmarks have no IsOutlineAvail API. Unavailable indirect objects are
  // retried after fetching the missing ranges; partial outlines are discarded.
  return state.step(outline);
}

_PdfStep<(double, double)> _loadNativePdfPage((int, int) params) {
  final (id, number) = params;
  final state = _nativePdfs[id]!;
  final api = state.api;
  final formStatus = api.FPDFAvail_IsFormAvail(state.availability, state.hints);
  if (formStatus == pdfium.PDF_FORM_ERROR) {
    throw const FormatException('PDF form data is corrupted');
  }
  if (formStatus == pdfium.PDF_FORM_NOTAVAIL) return state.step(null);
  final pageStatus = api.FPDFAvail_IsPageAvail(
    state.availability,
    number - 1,
    state.hints,
  );
  if (pageStatus == pdfium.PDF_DATA_ERROR) {
    throw const FormatException('PDF page data is corrupted');
  }
  if (pageStatus != pdfium.PDF_DATA_AVAIL) return state.step(null);
  state.formInfo ??= calloc<pdfium.FPDF_FORMFILLINFO>()..ref.version = 1;
  if (state.form == nullptr) {
    state.form = api.FPDFDOC_InitFormFillEnvironment(
      state.document,
      state.formInfo!,
    );
  }
  if (state.page == nullptr) {
    state.page = api.FPDF_LoadPage(state.document, number - 1);
  }
  if (state.page == nullptr) {
    if (state.pending.isNotEmpty) return state.step(null);
    throw PdfPageRenderException(number);
  }
  return state.step((
    api.FPDF_GetPageWidthF(state.page),
    api.FPDF_GetPageHeightF(state.page),
  ));
}

_PdfStep<bool> _renderNativePdfPage(
  ({int id, int buffer, int width, int height}) params,
) {
  final state = _nativePdfs[params.id]!;
  final api = state.api;
  final bitmap = api.FPDFBitmap_CreateEx(
    params.width,
    params.height,
    pdfium.FPDFBitmap_BGRA,
    Pointer<Void>.fromAddress(params.buffer),
    params.width * 4,
  );
  if (bitmap == nullptr) {
    throw const PdfException('PDF bitmap could not be created');
  }
  try {
    api.FPDFBitmap_FillRect(
      bitmap,
      0,
      0,
      params.width,
      params.height,
      0xffffffff,
    );
    api.FPDF_RenderPageBitmap(
      bitmap,
      state.page,
      0,
      0,
      params.width,
      params.height,
      0,
      pdfium.FPDF_ANNOT,
    );
    if (state.form != nullptr) {
      api.FPDF_FFLDraw(
        state.form,
        bitmap,
        state.page,
        0,
        0,
        params.width,
        params.height,
        0,
        0,
      );
    }
    return state.step(true);
  } finally {
    api.FPDFBitmap_Destroy(bitmap);
  }
}

class _NativePdfState {
  _NativePdfState(this.size) {
    access.ref
      ..m_FileLen = size
      ..m_GetBlock = getBlock.nativeFunction;
    fileAvail.ref
      ..version = 1
      ..IsDataAvail = isDataAvail.nativeFunction;
    hints.ref
      ..version = 1
      ..AddSegment = addSegment.nativeFunction;
    availability = api.FPDFAvail_Create(fileAvail, access);
    if (availability == nullptr) {
      dispose();
      throw const FormatException('PDF availability could not be initialized');
    }
  }

  final int size;
  final api = _remotePdfium;
  final access = calloc<pdfium.FPDF_FILEACCESS>();
  final fileAvail = calloc<pdfium.FX_FILEAVAIL>();
  final hints = calloc<pdfium.FX_DOWNLOADHINTS>();
  final blocks = <int, Uint8List>{};
  final pending = <int>{};
  bool requiresFullDownload = false;
  pdfium.FPDF_AVAIL availability = nullptr;
  pdfium.FPDF_DOCUMENT document = nullptr;
  pdfium.FPDF_PAGE page = nullptr;
  pdfium.FPDF_FORMHANDLE form = nullptr;
  Pointer<pdfium.FPDF_FORMFILLINFO>? formInfo;

  late final getBlock =
      NativeCallable<
        Int Function(
          Pointer<Void>,
          UnsignedLong,
          Pointer<UnsignedChar>,
          UnsignedLong,
        )
      >.isolateLocal(_getBlock, exceptionalReturn: 0);
  late final isDataAvail =
      NativeCallable<
        Int Function(Pointer<pdfium.FX_FILEAVAIL>, Size, Size)
      >.isolateLocal(_isDataAvail, exceptionalReturn: 0);
  late final addSegment =
      NativeCallable<
        Void Function(Pointer<pdfium.FX_DOWNLOADHINTS>, Size, Size)
      >.isolateLocal(_addSegment);

  int _isDataAvail(Pointer<pdfium.FX_FILEAVAIL> _, int offset, int length) {
    if (offset < 0 || length < 0 || offset > size || length > size - offset) {
      return 0;
    }
    if (length == 0) return 1;
    var available = true;
    final end = offset + length;
    for (var block = offset ~/ _pdfWindow; block * _pdfWindow < end; block++) {
      if (!blocks.containsKey(block)) {
        pending.add(block);
        available = false;
      }
    }
    return available ? 1 : 0;
  }

  void _addSegment(Pointer<pdfium.FX_DOWNLOADHINTS> _, int offset, int length) {
    // PDFium's damaged-xref repair requests the whole file. Preserve the cloud
    // reader's explicit failure instead of silently downloading it in chunks.
    if (offset == 0 && length >= size && size > _pdfWindow) {
      requiresFullDownload = true;
    }
    _isDataAvail(nullptr, offset, math.min(length, size - offset));
  }

  int _getBlock(
    Pointer<Void> _,
    int offset,
    Pointer<UnsignedChar> buffer,
    int length,
  ) {
    if (_isDataAvail(nullptr, offset, length) == 0) return 0;
    final output = buffer.cast<Uint8>().asTypedList(length);
    var copied = 0;
    while (copied < length) {
      final at = offset + copied;
      final block = blocks[at ~/ _pdfWindow]!;
      final start = at % _pdfWindow;
      final count = math.min(length - copied, block.length - start);
      output.setRange(copied, copied + count, block, start);
      copied += count;
    }
    return 1;
  }

  _PdfStep<T> step<T>(T? value) {
    if (requiresFullDownload) {
      throw const FormatException(
        'PDF requires a full download to repair its index',
      );
    }
    final sorted = pending.toList()..sort();
    pending.clear();
    final missing = <_PdfRange>[];
    for (final block in sorted) {
      if (blocks.containsKey(block)) continue;
      final start = block * _pdfWindow;
      final end = math.min(start + _pdfWindow, size);
      if (missing.isNotEmpty &&
          missing.last.$1 + missing.last.$2 == start &&
          end - missing.last.$1 <= _pdfMaxRead) {
        final previous = missing.removeLast();
        missing.add((previous.$1, end - previous.$1));
      } else {
        missing.add((start, end - start));
      }
    }
    return (value: missing.isEmpty ? value : null, missing: missing);
  }

  void dispose() {
    if (page != nullptr) api.FPDF_ClosePage(page);
    if (form != nullptr) api.FPDFDOC_ExitFormFillEnvironment(form);
    if (document != nullptr) api.FPDF_CloseDocument(document);
    if (availability != nullptr) api.FPDFAvail_Destroy(availability);
    getBlock.close();
    isDataAvail.close();
    addSegment.close();
    if (formInfo != null) calloc.free(formInfo!);
    calloc.free(access);
    calloc.free(fileAvail);
    calloc.free(hints);
    blocks.clear();
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
