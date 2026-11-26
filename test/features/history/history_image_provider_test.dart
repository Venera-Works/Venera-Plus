import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/painting.dart' show ImageChunkEvent;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/network/images.dart';

void main() {
  test('历史中的两类远端归档封面键直接交给缩略图加载器', () async {
    final directory = await Directory.systemTemp.createTemp('history-cover-');
    App.dataPath = App.cachePath = directory.path;
    CacheManager.debugDisableInitialScan = true;
    final chunkEvents = StreamController<ImageChunkEvent>.broadcast();
    const sourceKey = 'remote_library_1';
    final type = ComicType.fromKey(sourceKey);
    ComicType.configureSourceKeyResolver(
      (value) => value == type.value ? sourceKey : null,
    );
    addTearDown(() async {
      await chunkEvents.close();
      ComicType.configureSourceKeyResolver(null);
      ImageDownloader.debugResetSourceImageLoading();
      await CacheManager.resetForTesting();
      await directory.delete(recursive: true);
    });

    final bytes = Uint8List.fromList([1, 2, 3]);
    final requests = <(String, String)>[];
    ImageDownloader.configureSourceImageLoading(
      thumbnailLoadingConfig: (source, key) {
        requests.add((source, key));
        return {'loadBytes': (CancelToken _) async => bytes};
      },
    );
    final keys = [
      'remote-zip:${base64Url.encode(utf8.encode('["/books/book.zip","v1",null]'))}',
      'remote-work-image:${base64Url.encode(utf8.encode('["/books/work","volume",null]'))}',
    ];

    for (final key in keys) {
      expect(key, isNot(contains('/')));
      final history = History.fromMap({
        'id': 'book',
        'type': type.value,
        'time': 0,
        'cover': key,
      });
      final result = await HistoryImageProvider(
        history,
      ).load(chunkEvents, () {});
      expect(result, bytes);
      expect(history.cover, key);
    }
    expect(requests, keys.map((key) => (sourceKey, key)).toList());
  });
}
