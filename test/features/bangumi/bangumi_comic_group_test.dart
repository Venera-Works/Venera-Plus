import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  late BangumiService service;
  late Map<String, dynamic> previous;
  var scope = '';
  const a = Comic('Source A', 'a.jpg', '1', null, ['a'], '', 'a', null, null);
  const b = Comic('Source B', 'b.jpg', '1', null, ['b'], '', 'b', null, null);
  const c = Comic('Source A', 'c.jpg', '2', null, null, '', 'a', null, null);

  void saveBindings(List<BangumiBinding> bindings) {
    appdata.settings['bangumiBindings'] = {
      for (final binding in bindings)
        bangumiBindingKey(
          binding.sourceKey,
          binding.comicId,
          scopeId: binding.scopeId,
        ): binding
            .toJson(),
    };
  }

  setUp(() {
    previous = {
      for (final key in [
        'bangumiBindings',
        'bangumiAccessToken',
        'bangumiUsername',
        'bangumiAutoSyncEnabled',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    appdata.settings['bangumiAutoSyncEnabled'] = false;
    scope = '';
    service = BangumiService.forTesting(
      gatewayFactory: (_) =>
          throw StateError('Grouping must not request the network'),
      scopeResolver: (_) => scope,
    );
  });

  tearDown(() {
    service.dispose();
    previous.forEach((key, value) => appdata.settings[key] = value);
  });

  test('only saved valid bindings merge, including when disconnected', () {
    saveBindings([_binding(a, 42), _binding(b, 42)]);
    final groups = groupBangumiComics([a, c, b, a], service: service);
    expect(groups, hasLength(2));
    expect(groups.first.members, [a, b]);
    expect(groups.first.title, 'Work 42');
    expect(groups.first.cover, 'work.jpg');
    expect(groups.last.members, [c]);
    expect(groups.last.title, 'Source A');
    expect(groups.first.id, a.id);
    expect(groups.first.sourceKey, a.sourceKey);
    expect(groups.first.tags, ['a', 'b']);
  });

  test(
    'saved Bangumi covers follow the selected image proxy without changing bindings',
    () {
      final previousServer = appdata.settings['bangumiServer'];
      addTearDown(() => appdata.settings['bangumiServer'] = previousServer);
      const original = 'https://lain.bgm.tv/r/400/pic/cover.jpg';
      saveBindings([
        _binding(a, 42).copyWith(coverUrl: original),
        _binding(b, 42),
      ]);
      final group = groupBangumiComics([a, b], service: service).single;
      appdata.settings['bangumiServer'] = bangumiPresetServers[2].apiUrl;
      expect(group.cover, 'https://bgmimg.anibt.net/r/400/pic/cover.jpg');
      expect(service.bindingFor(a.sourceKey, a.id)!.coverUrl, original);
      expect(groupBangumiComics([c], service: service).single.cover, c.cover);
    },
  );

  test(
    'newest reading changes representative without changing work identity or member order',
    () {
      saveBindings([_binding(a, 42), _binding(b, 42)]);
      final first = groupBangumiComics([a, b], service: service).single;
      final recent = groupBangumiComics(
        [a, b],
        service: service,
        lastRead: (comic) => comic == b ? DateTime(2026) : null,
      ).single;
      expect(recent, first);
      expect(recent.hashCode, first.hashCode);
      expect(recent.representative, same(b));
      expect(recent.members, [a, b]);
      expect(recent.sourceKey, b.sourceKey);
      expect(() => recent.members.clear(), throwsUnsupportedError);
    },
  );

  test(
    'unbinding and rebinding split or regroup without inventing members',
    () {
      saveBindings([_binding(a, 42), _binding(b, 42), _binding(c, 42)]);
      expect(groupBangumiComics([a, b], service: service).single.members, [
        a,
        b,
      ]);
      saveBindings([_binding(a, 42), _binding(c, 42)]);
      expect(groupBangumiComics([a, b], service: service), hasLength(2));
      saveBindings([_binding(a, 42), _binding(b, 99)]);
      expect(
        groupBangumiComics([
          a,
          b,
        ], service: service).map((group) => group.subjectId),
        [42, 99],
      );
    },
  );

  test('wrong scope and invalid binding IDs do not merge', () {
    saveBindings([
      _binding(a, 42).copyWith(scopeId: 'old-library'),
      _binding(b, 42),
    ]);
    expect(groupBangumiComics([a, b], service: service), hasLength(2));
    scope = 'old-library';
    expect(groupBangumiComics([a, b], service: service), hasLength(2));
    scope = '';
    saveBindings([_binding(a, 0), _binding(b, 0)]);
    expect(groupBangumiComics([a, b], service: service), hasLength(2));
  });

  test('missing work metadata falls back to the representative', () {
    saveBindings([_binding(a, 42).copyWith(subjectTitle: '', coverUrl: '')]);
    final group = groupBangumiComics([a], service: service).single;
    expect(group.title, a.title);
    expect(group.cover, a.cover);
  });
}

BangumiBinding _binding(Comic comic, int subjectId) => BangumiBinding(
  sourceKey: comic.sourceKey,
  comicId: comic.id,
  subjectId: subjectId,
  subjectTitle: 'Work $subjectId',
  subjectOriginalTitle: '',
  coverUrl: 'work.jpg',
  progressMode: BangumiProgressMode.auto,
  totalEpisodes: 0,
  totalVolumes: 0,
  lastRemoteEpisode: 0,
  lastRemoteVolume: 0,
  rating: 0,
);
