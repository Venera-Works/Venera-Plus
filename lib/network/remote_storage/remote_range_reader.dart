import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:venera_plus/network/app_dio.dart';

import 'remote_file_store.dart';

/// Reads exact, bounded byte ranges from a remote file.
class RemoteRangeReader {
  RemoteRangeReader({
    required this.size,
    required Future<RemoteLink> Function() link,
    Dio? dio,
  }) : _link = link,
       _dio = dio ?? AppDio() {
    if (size < 0) throw RangeError.value(size, 'size');
  }

  final int size;
  final Future<RemoteLink> Function() _link;
  final Dio _dio;
  Future<RemoteLink>? _linkFuture;
  // Pin validators from download responses; directory metadata may come from
  // another service with different ETags and modification times.
  String? _eTag;
  // HTTP Last-Modified has second precision.
  int? _modifiedAt;

  Future<Uint8List> read(
    int offset,
    int length, {
    CancelToken? cancelToken,
  }) async {
    if (offset < 0 || offset > size) {
      throw RangeError.range(offset, 0, size, 'offset');
    }
    if (length < 0 || length > size - offset) {
      throw RangeError.range(length, 0, size - offset, 'length');
    }
    _checkCancelled(cancelToken);
    if (length == 0) return Uint8List(0);

    var refreshed = false;
    while (true) {
      final currentLink = await _resolveLink(cancelToken);
      _checkCancelled(cancelToken);
      final requestToken = CancelToken();
      var active = true;
      final tokenReference = WeakReference(requestToken);
      cancelToken?.whenCancel.then((error) {
        final token = tokenReference.target;
        if (active && token != null && !token.isCancelled) {
          token.cancel(error.error);
        }
      });
      final headers = <String, dynamic>{...currentLink.headers};
      headers.removeWhere(
        (name, _) => const {
          'range',
          'accept-encoding',
          'if-range',
          'if-match',
          'if-unmodified-since',
        }.contains(name.toLowerCase()),
      );
      headers['Range'] = 'bytes=$offset-${offset + length - 1}';
      headers['Accept-Encoding'] = 'identity';
      if (_eTag != null) {
        headers['If-Match'] = _eTag;
      } else if (_modifiedAt != null) {
        headers['If-Unmodified-Since'] = HttpDate.format(
          DateTime.fromMillisecondsSinceEpoch(_modifiedAt! * 1000, isUtc: true),
        );
      }

      StreamIterator<Uint8List>? body;
      try {
        final response = await _dio.get<ResponseBody>(
          currentLink.url,
          cancelToken: requestToken,
          options: Options(
            headers: headers,
            responseType: ResponseType.stream,
            // Dio otherwise starts consuming even a rejected 200 response.
            validateStatus: (status) => status == 206,
            receiveDataWhenStatusError: false,
          ),
        );
        if (response.data == null) {
          throw const RemoteStorageException(
            'The range response has no body',
            code: 'invalid_range_response',
          );
        }
        body = StreamIterator(response.data!.stream);
        _validateResponse(response.headers, offset, length);
        final result = Uint8List(length);
        var received = 0;
        while (await body.moveNext()) {
          _checkCancelled(cancelToken);
          final chunk = body.current;
          if (chunk.length > length - received) {
            throw const RemoteStorageException(
              'The range response exceeds the requested length',
              code: 'invalid_range_response',
            );
          }
          result.setRange(received, received + chunk.length, chunk);
          received += chunk.length;
        }
        active = false;
        _checkCancelled(cancelToken);
        if (received != length) {
          throw const RemoteStorageException(
            'The range response is truncated',
            code: 'invalid_range_response',
          );
        }
        return result;
      } on DioException catch (error) {
        _checkCancelled(cancelToken);
        if (CancelToken.isCancel(error)) rethrow;
        final status = error.response?.statusCode;
        if ((status == 401 || status == 403) && !refreshed) {
          refreshed = true;
          _linkFuture = null;
          continue;
        }
        if (status == 200) {
          throw RemoteStorageException(
            'The server does not support bounded range reads',
            code: 'range_not_supported',
            cause: error,
          );
        }
        if (status == 412 || status == 416) {
          throw RemoteStorageException(
            'The remote file changed; reopen the archive',
            code: 'remote_file_changed',
            cause: error,
          );
        }
        if (status != null) {
          throw RemoteStorageException(
            'The range request failed (HTTP $status)',
            code: '$status',
            cause: error,
          );
        }
        rethrow;
      } finally {
        // A fully consumed response has already finished normally. Abort only
        // incomplete/rejected responses, and detach the caller's late cancels.
        if (active) {
          active = false;
          if (!requestToken.isCancelled) {
            requestToken.cancel('Range read aborted');
          }
        }
        await body?.cancel();
      }
    }
  }

  Future<RemoteLink> _resolveLink(CancelToken? cancelToken) async {
    final pending = _linkFuture ??= _link();
    try {
      if (cancelToken == null) return await pending;
      return await Future.any([
        pending,
        cancelToken.whenCancel.then<RemoteLink>((error) => throw error),
      ]);
    } catch (_) {
      if (identical(_linkFuture, pending) && cancelToken?.isCancelled != true) {
        _linkFuture = null;
      }
      rethrow;
    }
  }

  void _validateResponse(Headers headers, int offset, int length) {
    final range = _header(headers, 'content-range');
    final match = range == null
        ? null
        : RegExp(
            r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
            caseSensitive: false,
          ).firstMatch(range);
    if (match == null ||
        int.tryParse(match[1]!) != offset ||
        int.tryParse(match[2]!) != offset + length - 1) {
      throw const RemoteStorageException(
        'The server returned an invalid Content-Range',
        code: 'invalid_range_response',
      );
    }
    if (int.tryParse(match[3]!) != size) {
      throw const RemoteStorageException(
        'The remote file size changed; reopen the archive',
        code: 'remote_file_changed',
      );
    }
    final contentLength = _header(headers, 'content-length');
    if (contentLength != null && int.tryParse(contentLength) != length) {
      throw const RemoteStorageException(
        'The range Content-Length does not match the request',
        code: 'invalid_range_response',
      );
    }
    final encoding = _header(headers, 'content-encoding');
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw const RemoteStorageException(
        'The server encoded the byte range',
        code: 'invalid_range_response',
      );
    }

    final responseETag = _strongETag(_header(headers, 'etag'));
    if (_eTag != null && responseETag != null) {
      if (responseETag != _eTag) _fileChanged();
      return;
    }
    final modified = _header(headers, 'last-modified');
    int? responseModifiedAt;
    if (modified != null) {
      try {
        responseModifiedAt =
            HttpDate.parse(modified).millisecondsSinceEpoch ~/ 1000;
      } on Exception {
        throw const RemoteStorageException(
          'The server returned an invalid Last-Modified',
          code: 'invalid_range_response',
        );
      }
    }
    if (_modifiedAt != null &&
        responseModifiedAt != null &&
        _modifiedAt != responseModifiedAt) {
      _fileChanged();
    }
    _eTag ??= responseETag;
    _modifiedAt ??= responseModifiedAt;
  }

  static String? _header(Headers headers, String name) {
    final values = headers[name];
    if (values == null) return null;
    if (values.length != 1 || values.single.trim().isEmpty) {
      throw RemoteStorageException(
        'The server returned an invalid $name header',
        code: 'invalid_range_response',
      );
    }
    return values.single.trim();
  }

  static String? _strongETag(String? value) {
    final tag = value?.trim();
    return tag != null && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(tag)
        ? tag
        : null;
  }

  static Never _fileChanged() => throw const RemoteStorageException(
    'The remote file changed; reopen the archive',
    code: 'remote_file_changed',
  );

  static void _checkCancelled(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
  }
}
