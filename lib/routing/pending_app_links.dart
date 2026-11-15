import 'dart:async';
import 'dart:collection';

/// 导航就绪后依次处理链接；返回 false 的链接保留到下一次就绪通知。
class PendingAppLinks {
  PendingAppLinks(this.open, this.onError);

  final Future<bool> Function(Uri) open;
  final void Function(Object, StackTrace) onError;
  final _pending = Queue<Uri>();
  bool _ready = false;
  bool _opening = false;
  int _readinessVersion = 0;

  void add(Uri uri) {
    _pending.add(uri);
    unawaited(_drain());
  }

  void setReady(bool ready) {
    _ready = ready;
    _readinessVersion++;
    if (ready) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_opening) return;
    _opening = true;
    try {
      while (_ready && _pending.isNotEmpty) {
        final readinessVersion = _readinessVersion;
        try {
          if (!await open(_pending.first)) {
            // 异步处理期间可能已重新挂载，不能覆盖较新的就绪通知。
            if (readinessVersion == _readinessVersion) _ready = false;
            continue;
          }
        } catch (error, stack) {
          onError(error, stack);
        }
        _pending.removeFirst();
      }
    } finally {
      _opening = false;
    }
  }
}

/// 仅从已知图库路径中提取页码，其他链接的漫画 ID 和路径保持原样。
({Uri uri, int? page}) comicLinkTarget(Uri uri) {
  final parts = uri.pathSegments.toList();
  if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
  final host = uri.host.toLowerCase();
  final knownPage =
      parts.isNotEmpty &&
      parts.first == 'g' &&
      ((host == 'nhentai.net' && parts.length == 3) ||
          ((host == 'e-hentai.org' || host == 'exhentai.org') &&
              parts.length == 4 &&
              parts[2].isNotEmpty));
  if (!knownPage) return (uri: uri, page: null);
  final id = int.tryParse(parts[1]);
  final page = int.tryParse(parts.last);
  if (id == null || id < 1 || page == null || page < 1) {
    return (uri: uri, page: null);
  }
  return (
    uri: uri.replace(pathSegments: [...parts.take(parts.length - 1), '']),
    page: page,
  );
}
