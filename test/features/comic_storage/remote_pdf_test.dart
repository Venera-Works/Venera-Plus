import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => RemotePdfReader.debugOpenDocument = null);

  test(
    'opens progressively without full-file memory caching and only inspects outlines',
    () async {
      final document = _Document(
        [_Page(), _Page(loaded: false), _Page(loaded: false)],
        outline: [_bookmark('One', 1), _bookmark('Two', 3)],
      );
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            expect(useProgressiveLoading, isTrue);
            expect(maxSizeToCacheOnMemory, 0);
            expect(size, 5000000);
            expect(sourceName, '/library/book.pdf');
            return document;
          };
      final result = await RemotePdfReader.inspect(
        size: 5000000,
        read: _noRead,
        sourceName: '/library/book.pdf',
      );
      expect(result.pageCount, 3);
      expect(result.metadata!.title, 'book');
      expect(result.metadata!.author, '');
      expect(result.metadata!.chapters!.map((chapter) => chapter.toJson()), [
        {'title': 'One', 'start': 1, 'end': 2},
        {'title': 'Two', 'start': 3, 'end': 3},
      ]);
      expect(document.progressivePages, isEmpty);
      expect(document.pages.cast<_Page>().map((page) => page.renderCount), [
        0,
        0,
        0,
      ]);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'validates outline destinations, keeps hierarchy and includes the unbookmarked beginning',
    () async {
      final document = _Document(
        List.generate(6, (_) => _Page()),
        outline: [
          _bookmark('', 1),
          _bookmark('Invalid', 0),
          _bookmark('Outside', 7),
          _bookmark(
            'Volume',
            null,
            children: [_bookmark('One', 3), _bookmark('Two', 5)],
          ),
          _bookmark('Duplicate', 3),
        ],
      );
      _open(document);
      final result = await RemotePdfReader.inspect(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        fallbackTitle: '前言',
      );
      expect(result.metadata!.chapters!.map((chapter) => chapter.toJson()), [
        {'title': '前言', 'start': 1, 'end': 2},
        {'title': 'Volume/One', 'start': 3, 'end': 4},
        {'title': 'Volume/Two', 'start': 5, 'end': 6},
      ]);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'does not invent embedded metadata when there are fewer than two bookmark pages',
    () async {
      for (final outline in [
        <PdfOutlineNode>[],
        [_bookmark('Only', 2), _bookmark('Same page', 2)],
      ]) {
        final document = _Document([_Page(), _Page()], outline: outline);
        _open(document);
        final result = await RemotePdfReader.inspect(
          size: 100,
          read: _noRead,
          sourceName: 'Filename.pdf',
        );
        expect(result.pageCount, 2);
        expect(result.metadata, isNull);
        expect(document.disposed, isTrue);
      }
    },
  );

  test(
    'fills only the requested bytes, splits long native reads and preserves caller zone',
    () async {
      const size = 6 * 1024 * 1024;
      final calls = <(int, int)>[];
      const zoneKey = #foreground;
      final document = _Document([_Page()]);
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            const requested = 5 * 1024 * 1024 + 17;
            final buffer = Uint8List(requested + 3)
              ..fillRange(0, requested + 3, 0xaa);
            final actual = await Zone.root.run(
              () => read(buffer, 7, requested),
            );
            expect(actual, requested);
            for (final index in [0, 1, 2097145, 4194297, requested - 1]) {
              expect(buffer[index], (7 + index) % 251);
            }
            expect(buffer.sublist(requested), [0xaa, 0xaa, 0xaa]);
            return document;
          };
      await runZoned(
        () => RemotePdfReader.inspect(
          size: size,
          sourceName: 'book.pdf',
          read: (offset, length) async {
            expect(Zone.current[zoneKey], 'page');
            expect(length, lessThanOrEqualTo(2 * 1024 * 1024));
            expect(offset % (256 * 1024), 0);
            expect(offset + length, lessThanOrEqualTo(size));
            calls.add((offset, length));
            return Uint8List.fromList(
              List.generate(length, (index) => (offset + index) % 251),
            );
          },
        ),
        zoneValues: {zoneKey: 'page'},
      );
      expect(calls, hasLength(3));
      expect(calls.first, (0, 2 * 1024 * 1024));
      expect(document.disposed, isTrue);
    },
  );

  test(
    'returns zero to the native bridge and rethrows the original range error and stack',
    () async {
      final failure = StateError('server range failure');
      final stack = StackTrace.fromString('original remote range stack');
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            expect(await read(Uint8List(8), 0, 8), 0);
            throw const PdfPasswordException('native bridge hid range failure');
          };
      try {
        await RemotePdfReader.inspect(
          size: 100,
          sourceName: 'book.pdf',
          read: (offset, length) async =>
              Error.throwWithStackTrace(failure, stack),
        );
        fail('Expected original range error');
      } catch (error, actualStack) {
        expect(error, same(failure));
        expect(actualStack.toString(), contains('original remote range stack'));
      }
    },
  );

  test(
    'detects short responses and invalid native ranges without leaking through the callback',
    () async {
      for (final invalidRange in [false, true]) {
        final document = _Document([_Page()]);
        var rangeCalls = 0;
        RemotePdfReader.debugOpenDocument =
            ({
              required read,
              required size,
              required sourceName,
              required useProgressiveLoading,
              required maxSizeToCacheOnMemory,
            }) async {
              expect(await read(Uint8List(8), invalidRange ? 99 : 0, 8), 0);
              return document;
            };
        await expectLater(
          RemotePdfReader.inspect(
            size: 100,
            sourceName: 'book.pdf',
            read: (offset, length) async {
              rangeCalls++;
              return Uint8List(length - 1);
            },
          ),
          throwsFormatException,
        );
        expect(rangeCalls, invalidRange ? 0 : 1);
        expect(document.disposed, isTrue);
      }
    },
  );

  test(
    'uses a neutral open error when PDFium reports password failure',
    () async {
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            throw const PdfPasswordException('open failed');
          };
      await expectLater(
        RemotePdfReader.inspect(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'PDF could not be opened or requires a password',
          ),
        ),
      );
    },
  );

  test(
    'renders the real target page size after bounded progressive loading and returns JPEG',
    () async {
      final first = _Page();
      final replacement = _Page(width: 4, height: 2);
      final target = _Page(loaded: false, replacement: replacement);
      final untouched = _Page(loaded: false);
      final document = _Document([first, target, untouched]);
      _open(document);
      final bytes = await RemotePdfReader.renderPage(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        pageNumber: 2,
        expectedPageCount: 3,
      );
      final decoded = image.decodeJpg(bytes)!;
      expect(decoded.width, 12);
      expect(decoded.height, 6);
      expect(document.progressivePages, [1, 2]);
      expect(first.renderCount, 0);
      expect(target.renderCount, 0);
      expect(untouched.renderCount, 0);
      expect(replacement.renderCount, 1);
      expect(replacement.lastWidth, 12);
      expect(replacement.lastHeight, 6);
      expect(replacement.rendered!.disposed, isTrue);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'propagates range failures that occur during progressive loading, outline or rendering',
    () async {
      for (final stage in ['progressive', 'outline', 'render']) {
        final failure = StateError('read failed at $stage');
        late RemotePdfCustomRead nativeRead;
        Future<void> failRead() async {
          expect(await nativeRead(Uint8List(8), 0, 8), 0);
        }

        final page = _Page(
          loaded: stage != 'progressive',
          onRender: stage == 'render' ? failRead : null,
        );
        final document = _Document(
          [page],
          onOutline: stage == 'outline' ? failRead : null,
          onProgressive: stage == 'progressive' ? failRead : null,
        );
        RemotePdfReader.debugOpenDocument =
            ({
              required read,
              required size,
              required sourceName,
              required useProgressiveLoading,
              required maxSizeToCacheOnMemory,
            }) async {
              nativeRead = read;
              return document;
            };
        final request = stage == 'outline'
            ? RemotePdfReader.inspect(
                size: 100,
                read: (offset, length) async => throw failure,
                sourceName: 'book.pdf',
              )
            : RemotePdfReader.renderPage(
                size: 100,
                read: (offset, length) async => throw failure,
                sourceName: 'book.pdf',
                pageNumber: 1,
              );
        await expectLater(request, throwsA(same(failure)));
        expect(document.disposed, isTrue);
        if (stage == 'render') expect(page.rendered!.disposed, isTrue);
      }
    },
  );

  test(
    'cancels active rendering but does not dispose the document until native work ends',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final token = CancelToken();
      final page = _Page(
        onRender: () async {
          started.complete();
          await gate.future;
        },
      );
      final document = _Document([page]);
      _open(document);
      final request = RemotePdfReader.renderPage(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        pageNumber: 1,
        cancelToken: token,
      );
      final checked = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      token.cancel('no readers');
      await Future<void>.delayed(Duration.zero);
      expect(page.cancellation.isCanceled, isTrue);
      expect(document.disposed, isFalse);
      gate.complete();
      await checked;
      expect(page.rendered!.disposed, isTrue);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'does not open for cancelled work and disconnects native cancel after completion',
    () async {
      var opens = 0;
      final page = _Page();
      final document = _Document([page]);
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            opens++;
            return document;
          };
      final cancelled = CancelToken()..cancel('already done');
      await expectLater(
        RemotePdfReader.inspect(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
          cancelToken: cancelled,
        ),
        throwsA(same(cancelled.cancelError)),
      );
      expect(opens, 0);
      final live = CancelToken();
      await RemotePdfReader.renderPage(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        pageNumber: 1,
        cancelToken: live,
      );
      live.cancel('after completed');
      await Future<void>.delayed(Duration.zero);
      expect(page.cancellation.isCanceled, isFalse);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'uses a separate document per operation and releases invalid or failed pages',
    () async {
      final documents = <_Document>[];
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            required useProgressiveLoading,
            required maxSizeToCacheOnMemory,
          }) async {
            final document = _Document([_Page()]);
            documents.add(document);
            return document;
          };
      await RemotePdfReader.inspect(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
      );
      await RemotePdfReader.renderPage(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        pageNumber: 1,
      );
      expect(documents.length, 2);
      expect(documents.every((document) => document.disposed), isTrue);
      for (final document in [
        _Document([]),
        _Document([_Page(width: double.nan)]),
        _Document([_Page(returnsNull: true)]),
        _Document([_Page()], encrypted: true),
      ]) {
        _open(document);
        await expectLater(
          RemotePdfReader.renderPage(
            size: 100,
            read: _noRead,
            sourceName: 'book.pdf',
            pageNumber: 1,
          ),
          throwsA(anyOf(isA<FormatException>(), isA<PdfPageRenderException>())),
        );
        expect(document.disposed, isTrue);
      }
      final changed = _Document([_Page(), _Page()]);
      _open(changed);
      await expectLater(
        RemotePdfReader.renderPage(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
          pageNumber: 1,
          expectedPageCount: 3,
        ),
        throwsFormatException,
      );
      expect(changed.disposed, isTrue);
    },
  );
}

Future<Uint8List> _noRead(int offset, int length) async =>
    throw StateError('Unexpected PDF read');

void _open(_Document document) {
  RemotePdfReader.debugOpenDocument =
      ({
        required read,
        required size,
        required sourceName,
        required useProgressiveLoading,
        required maxSizeToCacheOnMemory,
      }) async => document;
}

PdfOutlineNode _bookmark(
  String title,
  int? page, {
  List<PdfOutlineNode> children = const [],
}) => PdfOutlineNode(
  title: title,
  dest: page == null ? null : PdfDest(page, PdfDestCommand.fit, null),
  children: children,
);

class _Document extends Fake implements PdfDocument {
  _Document(
    List<_Page> pages, {
    this.outline = const [],
    this.encrypted = false,
    this.onOutline,
    this.onProgressive,
  }) : pages = List<PdfPage>.from(pages);
  @override
  final List<PdfPage> pages;
  final List<PdfOutlineNode> outline;
  final bool encrypted;
  final Future<void> Function()? onOutline;
  final Future<void> Function()? onProgressive;
  final progressivePages = <int>[];
  bool disposed = false;
  @override
  bool get isEncrypted => encrypted;
  @override
  Future<List<PdfOutlineNode>> loadOutline() async {
    await onOutline?.call();
    return outline;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {
    expect(loadUnitDuration, Duration.zero);
    await onProgressive?.call();
    for (var i = 0; i < pages.length; i++) {
      progressivePages.add(i + 1);
      final page = pages[i] as _Page;
      pages[i] = page.replacement ?? page;
      (pages[i] as _Page).loaded = true;
      if (onPageLoadProgress != null &&
          !await onPageLoadProgress(i + 1, pages.length, data)) {
        break;
      }
    }
  }
}

class _Page extends Fake implements PdfPage {
  _Page({
    this.width = 2,
    this.height = 3,
    this.loaded = true,
    this.replacement,
    this.onRender,
    this.returnsNull = false,
  });
  @override
  final double width;
  @override
  final double height;
  bool loaded;
  final _Page? replacement;
  final Future<void> Function()? onRender;
  final bool returnsNull;
  int renderCount = 0;
  double? lastWidth;
  double? lastHeight;
  _Image? rendered;
  final cancellation = _Cancellation();
  @override
  bool get isLoaded => loaded;
  @override
  PdfPageRenderCancellationToken createCancellationToken() => cancellation;
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = 0,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    renderCount++;
    lastWidth = fullWidth;
    lastHeight = fullHeight;
    expect(cancellationToken, same(cancellation));
    await onRender?.call();
    if (returnsNull) return null;
    return rendered = _Image(fullWidth!.toInt(), fullHeight!.toInt());
  }
}

class _Cancellation implements PdfPageRenderCancellationToken {
  @override
  bool isCanceled = false;
  @override
  void cancel() {
    isCanceled = true;
  }
}

class _Image extends Fake implements PdfImage {
  _Image(this.width, this.height)
    : pixels = Uint8List(width * height * 4)
        ..fillRange(0, width * height * 4, 255);
  @override
  final int width;
  @override
  final int height;
  @override
  final Uint8List pixels;
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
  }
}
