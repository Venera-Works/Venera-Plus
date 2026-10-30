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
    'inspects outlines only without rendering pages and extracts chapter metadata',
    () async {
      final document = _Document(
        pageCount: 3,
        outline: [_bookmark('One', 1), _bookmark('Two', 3)],
      );
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            cancelToken,
          }) async {
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
      expect(document.renderedPages, isEmpty);
      expect(document.disposed, isTrue);
    },
  );

  test(
    'validates outline destinations, keeps hierarchy and includes the unbookmarked beginning',
    () async {
      final document = _Document(
        pageCount: 6,
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
        final document = _Document(pageCount: 2, outline: outline);
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

  test('preserves caller zone during range reading', () async {
    const size = 6 * 1024 * 1024;
    final calls = <(int, int)>[];
    const zoneKey = #foreground;
    final document = _Document(pageCount: 1);
    RemotePdfReader.debugOpenDocument =
        ({
          required read,
          required size,
          required sourceName,
          cancelToken,
        }) async {
          final data = await Zone.root.run(() => read(0, 1024));
          expect(data.length, 1024);
          return document;
        };
    await runZoned(
      () => RemotePdfReader.inspect(
        size: size,
        sourceName: 'book.pdf',
        read: (offset, length) async {
          expect(Zone.current[zoneKey], 'page');
          calls.add((offset, length));
          return Uint8List(length);
        },
      ),
      zoneValues: {zoneKey: 'page'},
    );
    expect(calls, [(0, 1024)]);
    expect(document.disposed, isTrue);
  });

  test('rethrows original range error and stack trace', () async {
    final failure = StateError('server range failure');
    final stack = StackTrace.fromString('original remote range stack');
    late ZipRangeRead capturedRead;
    final document = _Document(
      pageCount: 1,
      onOutline: () async => await capturedRead(0, 8),
    );
    RemotePdfReader.debugOpenDocument =
        ({
          required read,
          required size,
          required sourceName,
          cancelToken,
        }) async {
          capturedRead = read;
          return document;
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
    expect(document.disposed, isTrue);
  });

  test('detects short responses and invalid byte ranges', () async {
    for (final isShort in [true, false]) {
      late ZipRangeRead capturedRead;
      final document = _Document(
        pageCount: 1,
        onOutline: () async {
          if (isShort) {
            await capturedRead(0, 8);
          } else {
            await capturedRead(99, 8);
          }
        },
      );
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            cancelToken,
          }) async {
            capturedRead = read;
            return document;
          };
      await expectLater(
        RemotePdfReader.inspect(
          size: 100,
          sourceName: 'book.pdf',
          read: (offset, length) async =>
              isShort ? Uint8List(length - 1) : Uint8List(length),
        ),
        throwsFormatException,
      );
      expect(document.disposed, isTrue);
    }
  });

  test(
    'propagates range failures that occur during outline or rendering',
    () async {
      for (final stage in ['outline', 'render']) {
        final failure = StateError('read failed at $stage');
        late ZipRangeRead capturedRead;
        final document = _Document(
          pageCount: 1,
          onOutline: stage == 'outline'
              ? () async => await capturedRead(0, 8)
              : null,
          onRender: stage == 'render'
              ? (_) async => await capturedRead(0, 8)
              : null,
        );
        RemotePdfReader.debugOpenDocument =
            ({
              required read,
              required size,
              required sourceName,
              cancelToken,
            }) async {
              capturedRead = read;
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
      }
    },
  );

  test(
    'cancels active rendering but does not dispose the document until backend work ends',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final token = CancelToken();
      final document = _Document(
        pageCount: 1,
        onRender: (_) async {
          started.complete();
          await gate.future;
        },
      );
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
      expect(document.disposed, isFalse);
      gate.complete();
      await checked;
      expect(document.disposed, isTrue);
    },
  );

  test(
    'does not open for cancelled work and ignores cancel after completion',
    () async {
      var opens = 0;
      final document = _Document(pageCount: 1);
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            cancelToken,
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
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(opens, 0);

      await expectLater(
        RemotePdfReader.renderPage(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
          pageNumber: 1,
          cancelToken: cancelled,
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
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
      expect(document.disposed, isTrue);
    },
  );

  test(
    'uses a separate document per operation and releases invalid documents',
    () async {
      final documents = <_Document>[];
      RemotePdfReader.debugOpenDocument =
          ({
            required read,
            required size,
            required sourceName,
            cancelToken,
          }) async {
            final document = _Document(pageCount: 1);
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
        _Document(pageCount: 0),
        _Document(pageCount: 1, encrypted: true),
      ]) {
        _open(document);
        await expectLater(
          RemotePdfReader.renderPage(
            size: 100,
            read: _noRead,
            sourceName: 'book.pdf',
            pageNumber: 1,
          ),
          throwsFormatException,
        );
        expect(document.disposed, isTrue);
      }

      await expectLater(
        () => RemotePdfReader.renderPage(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
          pageNumber: 0,
        ),
        throwsFormatException,
      );

      final bounded = _Document(pageCount: 2);
      _open(bounded);
      await expectLater(
        RemotePdfReader.renderPage(
          size: 100,
          read: _noRead,
          sourceName: 'book.pdf',
          pageNumber: 3,
        ),
        throwsFormatException,
      );
      expect(bounded.disposed, isTrue);

      final changed = _Document(pageCount: 2);
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

  test('cleanup failure does not overwrite original operation error', () async {
    final operationFailure = StateError('render failed');
    final cleanupFailure = StateError('dispose failed');
    final document = _Document(
      pageCount: 1,
      onRender: (_) async => throw operationFailure,
      onDispose: () async => throw cleanupFailure,
    );
    _open(document);
    await expectLater(
      RemotePdfReader.renderPage(
        size: 100,
        read: _noRead,
        sourceName: 'book.pdf',
        pageNumber: 1,
      ),
      throwsA(same(operationFailure)),
    );
    expect(document.disposed, isTrue);

    final outlineFailure = StateError('outline failed');
    final inspectDoc = _Document(
      pageCount: 1,
      onOutline: () async => throw outlineFailure,
      onDispose: () async => throw cleanupFailure,
    );
    _open(inspectDoc);
    await expectLater(
      RemotePdfReader.inspect(size: 100, read: _noRead, sourceName: 'book.pdf'),
      throwsA(same(outlineFailure)),
    );
    expect(inspectDoc.disposed, isTrue);
  });
}

Future<Uint8List> _noRead(int offset, int length) async =>
    throw StateError('Unexpected PDF read');

void _open(_Document document) {
  RemotePdfReader.debugOpenDocument =
      ({
        required read,
        required size,
        required sourceName,
        cancelToken,
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

final _tinyJpeg = Uint8List.fromList(
  image.encodeJpg(image.Image(width: 12, height: 6)),
);

class _Document extends Fake implements RemotePdfDocument {
  _Document({
    this.pageCount = 1,
    this.outline = const [],
    this.encrypted = false,
    this.onOutline,
    this.onRender,
    this.onDispose,
  });

  @override
  final int pageCount;
  final List<PdfOutlineNode> outline;
  final bool encrypted;
  final Future<void> Function()? onOutline;
  final Future<void> Function(int pageNumber)? onRender;
  final Future<void> Function()? onDispose;
  final renderedPages = <int>[];
  bool disposed = false;

  @override
  bool get isEncrypted => encrypted;

  @override
  Future<List<PdfOutlineNode>> loadOutline() async {
    await onOutline?.call();
    return outline;
  }

  @override
  Future<Uint8List> renderPage(int pageNumber) async {
    renderedPages.add(pageNumber);
    await onRender?.call(pageNumber);
    return _tinyJpeg;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await onDispose?.call();
  }
}
