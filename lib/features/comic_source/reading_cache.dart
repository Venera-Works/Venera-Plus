import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';

import 'models.dart';
import 'source.dart';

/// Persistent metadata used when resuming a scripted source. Built-in sources
/// retain their own snapshot caches and refresh rules.
extension ComicSourceReadingCache on ComicSource {
  String _readingCacheKey(String kind, String id, [String? chapter]) {
    final identity = jsonEncode([
      key,
      version,
      url,
      data['account'],
      data['settings'],
    ]);
    return jsonEncode([
      'reader-metadata-v1',
      sha256.convert(utf8.encode(identity)).toString(),
      kind,
      id,
      chapter,
    ]);
  }

  Future<T?> _readReadingCache<T>(
    String key,
    T Function(dynamic) decode,
  ) async {
    try {
      final file = await CacheManager().findCache(key);
      if (file != null) return decode(jsonDecode(await file.readAsString()));
    } catch (error, stack) {
      Log.warning('Reader metadata cache', '$error\n$stack');
    }
    return null;
  }

  Future<void> _writeReadingCache(String key, Object value) async {
    try {
      await CacheManager().writeCache(key, utf8.encode(jsonEncode(value)));
    } catch (error, stack) {
      Log.warning('Reader metadata cache', '$error\n$stack');
    }
  }

  Future<Res<ComicDetails>> loadComicInfoForReading(
    String id, {
    bool refresh = false,
  }) async {
    if (filePath.isEmpty) return loadComicInfo!(id);
    final cached = await _readReadingCache(
      _readingCacheKey('info', id),
      (value) => ComicDetails.fromJson(Map<String, dynamic>.from(value)),
    );
    if (!refresh && cached != null) return Res(cached);
    final result = await loadComicInfo!(id);
    if (result.success) {
      final comic = result.data;
      try {
        // Reopening details alone does not mean chapter contents changed.
        if (cached != null &&
            (cached.updateTime != comic.updateTime ||
                cached.maxPage != comic.maxPage)) {
          for (final chapter in <String?>{null, ...?comic.chapters?.ids}) {
            await CacheManager().delete(_readingCacheKey('pages', id, chapter));
          }
        }
        await _writeReadingCache(_readingCacheKey('info', id), {
          ...comic.toJson(),
          'subtitle': comic.subTitle,
          'maxPage': comic.maxPage,
        });
      } catch (error, stack) {
        Log.warning('Reader metadata cache', '$error\n$stack');
      }
    }
    return result;
  }

  Future<Res<List<String>>> loadComicPagesForReading(
    String id,
    String? chapter, {
    bool refresh = false,
  }) async {
    if (filePath.isEmpty) return loadComicPages!(id, chapter);
    final cacheKey = _readingCacheKey('pages', id, chapter);
    if (!refresh) {
      final cached = await _readReadingCache(
        cacheKey,
        (value) => List<String>.from(value),
      );
      if (cached?.isNotEmpty == true) return Res(cached!);
    }
    final result = await loadComicPages!(id, chapter);
    if (result.success && result.data.isNotEmpty) {
      await _writeReadingCache(cacheKey, result.data);
    }
    return result;
  }
}
