import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';

History entry() =>
    History.fromMap({
        'id': 'comic',
        'type': ComicType.local.value,
        'title': 'Comic',
        'time': 1,
        'ep': 2,
        'page': 3,
        'group': 1,
        'readEpisode': ['1-2'],
        'maxPage': 20,
      })
      ..maxChapter = 12
      ..chapterTitle = 'Chapter title'
      ..groupTitle = 'Volume one';

void main() {
  test(
    'old records keep their ordinal description and omit unknown totals',
    () {
      final history = History.fromMap({
        'id': 'old',
        'type': ComicType.local.value,
        'time': 0,
        'ep': 2,
        'page': 3,
        'readEpisode': <String>[],
      });
      expect(history.description, 'Chapter 2 - Page 3');
      expect(
        history.progressDescription(showTotals: true),
        history.description,
      );
      history.maxPage = 1;
      expect(
        history.progressDescription(showTotals: true),
        history.description,
      );
    },
  );

  test(
    'chapter display survives write, restart, synchronization and repeated import',
    () async {
      final directory = Directory.systemTemp.createTempSync('history-display-');
      App.dataPath = App.cachePath = directory.path;
      HistoryManager.cache = null;
      var manager = HistoryManager();
      await manager.init();
      addTearDown(() async {
        await manager.waitForAsyncWrites();
        manager.close();
        HistoryManager.cache = null;
        await directory.delete(recursive: true);
      });
      final history = entry();
      manager.addHistory(history);
      await manager.waitForAsyncWrites();
      manager.close();
      HistoryManager.cache = null;
      manager = HistoryManager();
      await manager.init();
      final restored = manager.find('comic', ComicType.local)!;
      expect(restored.description, 'Volume one - Chapter title - Page 3');
      expect(
        restored.progressDescription(showTotals: true, compact: true),
        'Ch. 2/12\nP. 3/20',
      );

      final db = sqlite3.open('${directory.path}/history.db');
      final remote = sqlite3.openInMemory();
      addTearDown(db.close);
      addTearDown(remote.close);
      final records = HistorySyncData.readSyncRecords(db);
      HistorySyncData.applySyncRecords(remote, records);
      final imported = History.fromRow(
        remote.select('SELECT * FROM history').single,
      );
      expect(imported.readingMetadata, restored.readingMetadata);
      expect(
        HistorySyncData.applySyncRecords(remote, records).historyChanged,
        isFalse,
      );
    },
  );

  test('metadata from a different saved chapter is not shown', () {
    final history = entry();
    final metadata = history.readingMetadata;
    final next = History.fromMap({
      'id': 'comic',
      'type': ComicType.local.value,
      'time': 2,
      'ep': 3,
      'page': 1,
      'group': 1,
      'readEpisode': <String>[],
      'readingMetadata': metadata,
    });
    expect(next.chapterTitle, isNull);
    expect(next.maxChapter, isNull);
  });
}
