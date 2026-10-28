import 'package:venera_plus/features/comic_source/comic_source.dart';

import 'bangumi_models.dart';
import 'bangumi_server.dart';
import 'bangumi_service.dart';

/// A presentation of a work. Storage and reading still use [members].
class BangumiComicGroup<T extends Comic> implements Comic {
  BangumiComicGroup({
    required this.groupKey,
    required Iterable<T> members,
    required this.representative,
    this.binding,
  }) : members = List.unmodifiable(members);

  final String groupKey;
  final List<T> members;
  final T representative;
  final BangumiBinding? binding;

  int? get subjectId => binding?.subjectId;

  @override
  String get title => binding?.subjectTitle.isNotEmpty == true
      ? binding!.subjectTitle
      : representative.title;

  @override
  String get cover => binding?.coverUrl.isNotEmpty == true
      ? currentBangumiServer.resolveImageUrl(binding!.coverUrl)
      : representative.cover;

  // Keep real source identities even when a caller only needs display data.
  @override
  String get id => representative.id;
  @override
  String get sourceKey => representative.sourceKey;
  @override
  String? get subtitle => representative.subtitle;
  @override
  List<String>? get tags =>
      {for (final member in members) ...?member.tags}.toList();
  @override
  String get description => representative.description;
  @override
  int? get maxPage => representative.maxPage;
  @override
  String? get language => representative.language;
  @override
  String? get favoriteId => representative.favoriteId;
  @override
  double? get stars => representative.stars;
  @override
  Map<String, dynamic> toJson() => representative.toJson();

  @override
  bool operator ==(Object other) =>
      other is BangumiComicGroup && other.groupKey == groupKey;
  @override
  int get hashCode => groupKey.hashCode;
}

/// Uses saved bindings only, preserving the first occurrence of each work.
List<BangumiComicGroup<T>> groupBangumiComics<T extends Comic>(
  Iterable<T> comics, {
  BangumiService? service,
  DateTime? Function(T)? lastRead,
}) {
  final bangumi = service ?? BangumiService();
  final members = <String, List<T>>{};
  final bindings = <String, BangumiBinding>{};
  final seen = <(String, String)>{};
  for (final comic in comics) {
    if (!seen.add((comic.sourceKey, comic.id))) continue;
    final binding = bangumi.bindingFor(comic.sourceKey, comic.id);
    final key = binding == null
        ? 'source:${bangumiBindingKey(comic.sourceKey, comic.id)}'
        : 'bangumi:${binding.subjectId}';
    members.putIfAbsent(key, () => []).add(comic);
    if (binding != null) bindings.putIfAbsent(key, () => binding);
  }
  return members.entries.map((entry) {
    var representative = entry.value.first;
    var latest = lastRead?.call(representative);
    for (final member in entry.value.skip(1)) {
      final time = lastRead?.call(member);
      if (time != null && (latest == null || time.isAfter(latest))) {
        representative = member;
        latest = time;
      }
    }
    return BangumiComicGroup<T>(
      groupKey: entry.key,
      members: entry.value,
      representative: representative,
      binding: bindings[entry.key],
    );
  }).toList();
}
