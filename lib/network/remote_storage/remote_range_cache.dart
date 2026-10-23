import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'remote_read_scheduler.dart';

/// A byte budget shared by the archives of one account. Keys include the file
/// version; only validated, bounded range responses enter this cache.
class RemoteRangeCache {
  RemoteRangeCache({this.maxBytes = 16 * 1024 * 1024});

  static const maxRangeBytes = 2 * 1024 * 1024;
  final int maxBytes;
  final _ranges = <_Range, Uint8List>{};
  final _pending = <_PendingRange>[];
  int _bytes = 0;

  Future<Uint8List> read(
    String key,
    int offset,
    int length, {
    required Future<Uint8List> Function(
      CancelToken cancelToken,
      RemoteReadContext context,
    )
    load,
    CancelToken? cancelToken,
    RemoteReadContext? context,
  }) async {
    _checkCancelled(cancelToken);
    final range = _Range(key, offset, length);
    for (final cached in _ranges.keys.toList().reversed) {
      if (!cached.contains(range)) continue;
      final bytes = _ranges.remove(cached)!;
      _ranges[cached] = bytes;
      return _slice(bytes, offset - cached.offset, length);
    }

    final priority = context ?? RemoteReadContext.current;
    var pending = _pending
        .where(
          (item) => !item.cancelToken.isCancelled && item.range.contains(range),
        )
        .firstOrNull;
    if (pending == null) {
      pending = _PendingRange(range, priority);
      _pending.add(pending);
      final request = pending;
      request.future =
          Future<Uint8List>.sync(
                () => load(request.cancelToken, request.context),
              )
              .then((bytes) {
                _checkCancelled(request.cancelToken);
                if (length <= maxRangeBytes && length <= maxBytes) {
                  while (_bytes + length > maxBytes && _ranges.isNotEmpty) {
                    _bytes -= _ranges.remove(_ranges.keys.first)!.length;
                  }
                  _ranges[range] = bytes;
                  _bytes += bytes.length;
                }
                return bytes;
              })
              .whenComplete(() {
                request.finished = true;
                _pending.remove(request);
              });
    } else {
      pending.context.promote(priority.priority);
    }

    final request = pending;
    request.waiters++;
    try {
      final bytes = cancelToken == null
          ? await request.future
          : await Future.any<Uint8List>([
              request.future,
              cancelToken.whenCancel.then<Uint8List>((error) => throw error),
            ]);
      _checkCancelled(cancelToken);
      return _slice(bytes, offset - request.range.offset, length);
    } finally {
      request.waiters--;
      if (request.waiters == 0 && !request.finished) {
        request.cancelToken.cancel('No readers are waiting for this range');
      }
    }
  }

  void invalidate(String key) {
    for (final range
        in _ranges.keys.where((range) => range.key == key).toList()) {
      _bytes -= _ranges.remove(range)!.length;
    }
    for (final request in _pending.where(
      (request) => request.range.key == key,
    )) {
      request.cancelToken.cancel('Remote archive version changed');
    }
  }

  static Uint8List _slice(Uint8List bytes, int offset, int length) =>
      Uint8List.fromList(Uint8List.sublistView(bytes, offset, offset + length));

  static void _checkCancelled(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
  }
}

class _Range {
  _Range(this.key, this.offset, this.length);
  final String key;
  final int offset;
  final int length;

  bool contains(_Range other) =>
      key == other.key &&
      offset <= other.offset &&
      length >= other.offset - offset + other.length;
}

class _PendingRange {
  _PendingRange(this.range, this.context);
  final _Range range;
  final RemoteReadContext context;
  final cancelToken = CancelToken();
  late final Future<Uint8List> future;
  int waiters = 0;
  bool finished = false;
}
