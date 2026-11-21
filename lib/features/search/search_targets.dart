import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

typedef SearchTarget = ({
  String key,
  String name,
  SearchPageData searchPageData,
});

// @ 不能出现在网站源的 key 中。本地搜索结果仍使用漫画原有的来源。
const localSearchTargetKey = '@local';

SearchPageData? _localSearch;

void configureLocalLibrarySearch(SearchPageData? data) => _localSearch = data;

List<SearchTarget> allSearchTargets() => [
  for (final source in ComicSource.all())
    if (source.searchPageData case final data?)
      (key: source.key, name: source.name, searchPageData: data),
  if (_localSearch case final data?)
    (key: localSearchTargetKey, name: 'Local Comics'.tl, searchPageData: data),
];

SearchTarget? findSearchTarget(String key) =>
    allSearchTargets().where((target) => target.key == key).firstOrNull;

List<String> searchSourceOrder(List<SearchTarget> targets) {
  final saved = appdata.settings['searchSources'] as List?;
  if (saved == null) return [for (final target in targets) target.key];
  if (saved.isEmpty) return [];
  final disabled = appdata.settings['disabledLibrarySearchSources'] as List;
  return <String>{
    ...saved.whereType<String>(),
    // 旧版本安装网站源时已经写入了名单，新出现的书库可以直接参与搜索。
    for (final target in targets)
      if (target.searchPageData.loadTags != null &&
          !disabled.contains(target.key))
        target.key,
  }.toList();
}

List<SearchTarget> enabledSearchTargets() {
  final targets = allSearchTargets();
  final byKey = {for (final target in targets) target.key: target};
  return [for (final key in searchSourceOrder(targets)) ?byKey[key]];
}

void saveLibrarySearchSelection(
  List<SearchTarget> targets,
  List<String> enabled,
) {
  final disabled = (appdata.settings['disabledLibrarySearchSources'] as List)
      .whereType<String>()
      .toSet();
  for (final target in targets.where(
    (target) => target.searchPageData.loadTags != null,
  )) {
    if (enabled.contains(target.key)) {
      disabled.remove(target.key);
    } else {
      disabled.add(target.key);
    }
  }
  appdata.settings['disabledLibrarySearchSources'] = disabled.toList();
}
