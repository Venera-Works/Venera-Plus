import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/image_preloader.dart';
import 'package:venera_plus/foundation/log.dart';

void main() {
  late ReaderImagePreloader preloader;
  late List<String> started;
  late Map<String, Completer<void>> gates;

  ReaderImagePreload task(String key, {bool decode = false}) =>
      ReaderImagePreload(
        key: key,
        decode: decode,
        load: () {
          final name = '$key:$decode';
          started.add(name);
          return (gates[name] = Completer<void>()).future;
        },
      );

  Future<void> finish(String name) async {
    gates[name]!.complete();
    await pumpEventQueue();
  }

  setUp(() {
    preloader = ReaderImagePreloader();
    started = [];
    gates = {};
  });

  tearDown(() async {
    preloader.dispose();
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await pumpEventQueue();
  });

  test(
    'nearby pages run first and distant downloads run one at a time',
    () async {
      final window = [
        task('next', decode: true),
        task('previous', decode: true),
        task('far-1'),
        task('far-2'),
      ];
      preloader.update(window);
      expect(started, ['next:true', 'previous:true']);
      await finish('next:true');
      expect(started.last, 'far-1:false');
      await finish('previous:true');
      expect(started, hasLength(3));
      preloader.update(window);
      expect(started, hasLength(3));
      await finish('far-1:false');
      expect(started.last, 'far-2:false');
      await finish('far-2:false');
      preloader.update(window);
      expect(started, hasLength(4));
    },
  );

  test(
    'fast navigation replaces queued pages and leaves capacity for next page',
    () async {
      preloader.update([task('old-active'), task('old-queued')]);
      preloader.update([task('new-next', decode: true), task('new-far')]);
      expect(started, ['old-active:false', 'new-next:true']);
      await finish('old-active:false');
      expect(started.last, 'new-far:false');
      expect(started, isNot(contains('old-queued:false')));
    },
  );

  test('an active download is decoded once when it becomes adjacent', () async {
    preloader.update([task('page')]);
    preloader.update([task('page', decode: true)]);
    expect(started, ['page:false']);
    await finish('page:false');
    expect(started, ['page:false', 'page:true']);
    await finish('page:true');
    preloader.update([task('page', decode: true), task('page')]);
    expect(started, hasLength(2));
  });

  test('failed preloads do not loop or block subsequent pages', () async {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    preloader.update([task('bad'), task('next')]);
    gates['bad:false']!.completeError(StateError('download failed'));
    await pumpEventQueue();
    expect(started, ['bad:false', 'next:false']);
    preloader.update([task('bad'), task('next')]);
    expect(started, hasLength(2));
    await finish('next:false');
    expect(started, hasLength(2));
  });

  test('disposing stops queued work', () async {
    preloader.update([task('active'), task('queued')]);
    preloader.dispose();
    await finish('active:false');
    expect(started, ['active:false']);
  });
}
