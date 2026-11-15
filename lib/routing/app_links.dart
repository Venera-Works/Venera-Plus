import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';

import 'pending_app_links.dart';

StreamSubscription<Uri>? _subscription;
final _pending = PendingAppLinks((uri) async {
  return _openAppLink(uri, rootNavigator: true) !=
      _AppLinkResult.navigationUnavailable;
}, (error, stack) => Log.error('App links', error, stack));

enum _AppLinkResult { opened, unsupported, navigationUnavailable }

void setAppLinkNavigationReady(bool ready) => _pending.setReady(ready);

void handleLinks() {
  _subscription ??= AppLinks().uriLinkStream.listen(
    _pending.add,
    onError: (Object error, StackTrace stack) =>
        Log.error('App links', error, stack),
  );
}

Future<bool> handleAppLink(Uri uri, {bool rootNavigator = false}) async {
  return _openAppLink(uri, rootNavigator: rootNavigator) ==
      _AppLinkResult.opened;
}

_AppLinkResult _openAppLink(Uri uri, {required bool rootNavigator}) {
  final target = comicLinkTarget(uri);
  for (final source in ComicSource.all()) {
    final handler = source.linkHandler;
    if (handler == null ||
        !handler.domains.any(
          (domain) => domain.toLowerCase() == uri.host.toLowerCase(),
        )) {
      continue;
    }
    final String? id;
    try {
      id = handler.linkToId(target.uri.toString());
    } catch (error, stack) {
      Log.error('App links (${source.key})', error, stack);
      continue;
    }
    final comicId = id;
    if (comicId == null || comicId.isEmpty) continue;
    // 系统链接必须显示在根阅读器之上；页内评论链接仍由调用方收起根弹层。
    final context = rootNavigator
        ? App.rootNavigatorKey.currentContext
        : App.mainNavigatorKey?.currentContext;
    if (context == null || !context.mounted) {
      return _AppLinkResult.navigationUnavailable;
    }
    unawaited(
      context.to(
        () => ComicPage(
          id: comicId,
          sourceKey: source.key,
          initialReaderPage: target.page,
        ),
      ),
    );
    return _AppLinkResult.opened;
  }
  return _AppLinkResult.unsupported;
}
