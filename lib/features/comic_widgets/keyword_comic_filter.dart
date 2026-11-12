import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/keyword_filter.dart';

export 'package:venera_plus/foundation/keyword_filter.dart';

KeywordFilter comicKeywordFilter() => KeywordFilter.fromSettings({
  'blockedWords': appdata.settings['blockedWords'],
  'blockedWordRules': appdata.settings['blockedWordRules'],
});

KeywordMatch? matchComicKeyword(Comic comic, {KeywordFilter? filter}) =>
    (filter ?? comicKeywordFilter()).comicMatch(
      title: comic.title,
      subtitle: comic.subtitle,
      description: comic.description,
      tags: comic.tags ?? const [],
    );
