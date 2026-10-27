import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/local_comics/download_retry.dart';

void main() {
  test('only unavailable network images can be skipped', () {
    DioException response(int status) {
      final request = RequestOptions(path: 'https://example.invalid/image');
      return DioException(
        requestOptions: request,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: request, statusCode: status),
      );
    }

    expect(canSkipUnavailableDownloadImage(response(404)), isTrue);
    expect(canSkipUnavailableDownloadImage(response(410)), isTrue);
    expect(
      canSkipUnavailableDownloadImage(const SocketException('offline')),
      isTrue,
    );
    expect(canSkipUnavailableDownloadImage(response(401)), isFalse);
    expect(canSkipUnavailableDownloadImage(response(403)), isFalse);
    expect(
      canSkipUnavailableDownloadImage(const TlsException('certificate')),
      isFalse,
    );
    expect(
      canSkipUnavailableDownloadImage(const FileSystemException('write')),
      isFalse,
    );
    expect(canSkipUnavailableDownloadImage(const DownloadCancelled()), isFalse);
  });

  testWidgets(
    'connectivity hints shorten backoff without resetting its budget',
    (tester) async {
      var attempts = 0;
      Object? failure;
      final retry = DownloadRetry(
        isActive: () => true,
        onWaitingChanged: () {},
      );
      final done = retry
          .run<void>(() async {
            attempts++;
            throw const SocketException('offline');
          })
          .catchError((Object error) {
            failure = error;
          });
      await tester.pump();
      for (var i = 0; i < DownloadRetry.delays.length; i++) {
        expect(retry.isWaiting, isTrue);
        retry.wake();
        await tester.pump();
      }
      await done;
      expect(attempts, 7);
      expect(failure, isA<SocketException>());
      expect(retry.isWaiting, isFalse);
      retry.cancel();
    },
  );

  testWidgets(
    'pause cancels a pending retry without starting another request',
    (tester) async {
      var attempts = 0;
      var active = true;
      final retry = DownloadRetry(
        isActive: () => active,
        onWaitingChanged: () {},
      );
      final done = retry.run<void>(() async {
        attempts++;
        throw const SocketException('offline');
      });
      final expectation = expectLater(done, throwsA(isA<DownloadCancelled>()));
      await tester.pump();
      active = false;
      retry.cancel();
      await tester.pump(const Duration(minutes: 2));
      await expectation;
      expect(attempts, 1);
      expect(retry.isWaiting, isFalse);
    },
  );
}
