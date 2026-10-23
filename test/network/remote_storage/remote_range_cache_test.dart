import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  test(
    'reuses contained ranges, isolates versions and evicts to byte budget',
    () async {
      final cache = RemoteRangeCache(maxBytes: 12);
      var loads = 0;
      Future<Uint8List> read(String key, int offset, int length) => cache.read(
        key,
        offset,
        length,
        load: (_, _) async {
          loads++;
          return Uint8List.fromList(List.generate(length, (i) => offset + i));
        },
      );
      final first = await read('v1', 0, 8);
      first[3] = 99;
      expect(await read('v1', 3, 2), [3, 4]);
      expect(loads, 1);
      await read('v2', 0, 8);
      expect(loads, 2);
      await read('v1', 0, 8);
      expect(loads, 3);
      cache.invalidate('v1');
      await read('v1', 0, 8);
      expect(loads, 4);
    },
  );

  test(
    'merges pending containing reads and promotes the shared request',
    () async {
      final cache = RemoteRangeCache();
      final bytes = Completer<Uint8List>();
      final priority = RemoteReadContext(priority: RemoteReadPriority.preload);
      final cancelled = CancelToken();
      var loads = 0;
      Future<Uint8List> load(CancelToken token, RemoteReadContext context) {
        loads++;
        expect(context, same(priority));
        return bytes.future;
      }

      final first = cache.read(
        'file',
        0,
        8,
        load: load,
        cancelToken: cancelled,
        context: priority,
      );
      final second = cache.read('file', 2, 3, load: load);
      expect(priority.priority, RemoteReadPriority.foreground);
      final firstError = expectLater(
        first,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      cancelled.cancel();
      await firstError;
      bytes.complete(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]));
      expect(await second, [2, 3, 4]);
      expect(loads, 1);
    },
  );

  test(
    'cancels queued network work only after the last reader leaves',
    () async {
      final cache = RemoteRangeCache();
      final callers = [CancelToken(), CancelToken()];
      late CancelToken transport;
      final bytes = Completer<Uint8List>();
      final reads = callers
          .map(
            (caller) => cache.read(
              'file',
              0,
              3,
              cancelToken: caller,
              load: (token, _) {
                transport = token;
                token.whenCancel.then((error) => bytes.completeError(error));
                return bytes.future;
              },
            ),
          )
          .toList();
      final errors = reads
          .map((read) => expectLater(read, throwsA(isA<DioException>())))
          .toList();
      callers.first.cancel();
      await errors.first;
      expect(transport.isCancelled, isFalse);
      callers.last.cancel();
      await errors.last;
      await Future<void>.value();
      expect(transport.isCancelled, isTrue);
    },
  );

  test('failed reads are retried instead of cached', () async {
    final cache = RemoteRangeCache();
    var loads = 0;
    Future<Uint8List> read() => cache.read(
      'file',
      0,
      3,
      load: (_, _) async {
        if (loads++ == 0) throw StateError('request failed');
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    await expectLater(read(), throwsStateError);
    expect(await read(), [1, 2, 3]);
    expect(loads, 2);
  });

  test('oversized ranges are delivered without retaining them', () async {
    final cache = RemoteRangeCache();
    var loads = 0;
    Future<Uint8List> read() => cache.read(
      'file',
      0,
      RemoteRangeCache.maxRangeBytes + 1,
      load: (_, _) async {
        loads++;
        return Uint8List(RemoteRangeCache.maxRangeBytes + 1);
      },
    );
    await read();
    await read();
    expect(loads, 2);
  });
}
