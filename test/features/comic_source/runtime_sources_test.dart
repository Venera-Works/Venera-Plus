import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = ComicSourceManager();

  tearDown(() {
    configureRuntimeComicSourcesProvider(null);
    for (final source in manager.all()) {
      manager.remove(source.key);
    }
  });

  test(
    'runtime source creation, replacement and removal preserve website sources and live sessions',
    () async {
      final website = _WebsiteSource();
      manager.add(website);
      var runtimeSources = [_source('library_a'), _source('library_b')];
      configureRuntimeComicSourcesProvider(() => runtimeSources);
      var notifications = 0;
      void onChanged() => notifications++;
      manager.addListener(onChanged);
      addTearDown(() => manager.removeListener(onChanged));

      await manager.refreshRuntimeSources();
      final original = manager.find('library_a')!;
      original.data['token'] = 'live-session';
      expect(manager.all(), [website, ...runtimeSources]);

      final renamed = _source('library_a', name: 'Renamed library');
      runtimeSources = [renamed, _source('library_c')];
      await manager.refreshRuntimeSources();

      expect(manager.find(website.key), same(website));
      expect(manager.find('library_a'), same(renamed));
      expect(renamed.name, 'Renamed library');
      expect(renamed.data, same(original.data));
      original.data['token'] = 'updated-by-old-callback';
      expect(renamed.data['token'], 'updated-by-old-callback');
      expect(manager.find('library_b'), isNull);
      expect(manager.find('library_c'), same(runtimeSources.last));

      runtimeSources = [];
      await manager.refreshRuntimeSources();
      expect(manager.all(), [website]);
      expect(notifications, 3);
    },
  );

  test('a failed runtime provider preserves the registered sources', () async {
    final website = _WebsiteSource();
    final library = _source('library_a');
    manager.add(website);
    manager.add(library);
    configureRuntimeComicSourcesProvider(() => throw StateError('failed'));

    await expectLater(
      manager.refreshRuntimeSources(),
      throwsA(isA<StateError>()),
    );
    expect(manager.all(), [website, library]);
  });
}

class _WebsiteSource extends Fake implements ComicSource {
  @override
  String get key => 'website';

  @override
  String get filePath => 'website.js';

  @override
  Future<void> loadData() async {
    fail('Updating a cloud library must not reload website source data');
  }
}

ComicSource _source(String key, {String name = 'Library'}) => ComicSource(
  name,
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  '',
  '',
  '',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);
