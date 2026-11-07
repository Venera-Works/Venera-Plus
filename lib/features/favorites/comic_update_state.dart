import 'dart:convert';
import 'dart:math' as math;

enum ComicUpdateCheckStatus { updated, unchanged, baseline, unknown }

String _encodeUnique(String chapterId) => jsonEncode(['u', chapterId]);

String _encodeGrouped(String? groupId, String chapterId) =>
    jsonEncode(['g', groupId ?? '', chapterId]);

String _occurrenceKey(String? groupId, String chapterId) {
  if (groupId != null && groupId.isNotEmpty) {
    return _encodeGrouped(groupId, chapterId);
  }
  return _encodeUnique(chapterId);
}

({bool isUnique, String? groupId, String chapterId}) _decodeChapterKey(
  String key,
) {
  final decoded = jsonDecode(key);
  if (decoded is List) {
    if (decoded.length == 2 && decoded[0] == 'u') {
      final id = decoded[1];
      if (id is String && id.isNotEmpty) {
        return (isUnique: true, groupId: null, chapterId: id);
      }
    } else if (decoded.length == 3 && decoded[0] == 'g') {
      final g = decoded[1];
      final id = decoded[2];
      if (g is String && id is String && id.isNotEmpty) {
        return (isUnique: false, groupId: g.isEmpty ? null : g, chapterId: id);
      }
    }
  }
  throw FormatException('Invalid chapter key format: $key');
}

class ComicUpdateSnapshot {
  final Set<String> chapterKeys;
  final String? updateTime;
  final int? maxPage;
  final Map<String, int> chapterPageCounts;
  final Map<(String?, String), String> occurrenceToKey;
  final Map<String, Set<String>> chapterGroups;
  final Map<String, int> idCounts;
  final List<({String? groupId, String chapterId})> occurrences;
  final bool hasReliableChapters;

  const ComicUpdateSnapshot._({
    required this.chapterKeys,
    required this.updateTime,
    required this.maxPage,
    required this.chapterPageCounts,
    required this.occurrenceToKey,
    required this.chapterGroups,
    required this.idCounts,
    required this.occurrences,
    required this.hasReliableChapters,
  });
  factory ComicUpdateSnapshot.fromChapters(
    Map<String, dynamic>? chapters, {
    String? updateTime,
    int? maxPage,
    Map<String, int> chapterPageCounts = const {},
  }) {
    final validMaxPage = (maxPage != null && maxPage > 0) ? maxPage : null;

    if (chapters == null || chapters.isEmpty) {
      return ComicUpdateSnapshot._(
        chapterKeys: const <String>{},
        updateTime: updateTime,
        maxPage: validMaxPage,
        chapterPageCounts: const <String, int>{},
        occurrenceToKey: const <(String?, String), String>{},
        chapterGroups: const <String, Set<String>>{},
        idCounts: const <String, int>{},
        occurrences: const [],
        hasReliableChapters: false,
      );
    }

    final items = <({String? groupId, String chapterId})>[];
    final counts = <String, int>{};
    final groups = <String, Set<String>>{};

    for (final entry in chapters.entries) {
      final value = entry.value;
      if (value is Map) {
        final groupId = entry.key;
        for (final chEntry in value.entries) {
          final chId = chEntry.key.toString();
          items.add((groupId: groupId, chapterId: chId));
          counts[chId] = (counts[chId] ?? 0) + 1;
          groups.putIfAbsent(chId, () => <String>{}).add(groupId);
        }
      } else {
        final chId = entry.key;
        items.add((groupId: null, chapterId: chId));
        counts[chId] = (counts[chId] ?? 0) + 1;
        groups.putIfAbsent(chId, () => <String>{}).add('');
      }
    }

    if (items.isEmpty) {
      return ComicUpdateSnapshot._(
        chapterKeys: const <String>{},
        updateTime: updateTime,
        maxPage: validMaxPage,
        chapterPageCounts: const <String, int>{},
        occurrenceToKey: const <(String?, String), String>{},
        chapterGroups: const <String, Set<String>>{},
        idCounts: const <String, int>{},
        occurrences: const [],
        hasReliableChapters: false,
      );
    }

    final resolvedKeys = <String>{};
    final occurrenceMap = <(String?, String), String>{};

    for (final item in items) {
      final chId = item.chapterId;
      final gId = item.groupId;
      final count = counts[chId] ?? 0;

      if (count <= 1) {
        resolvedKeys.add(_encodeUnique(chId));
      } else {
        resolvedKeys.add(_encodeGrouped(gId, chId));
      }

      occurrenceMap[(gId, chId)] = _occurrenceKey(gId, chId);
    }

    final resolvedPageCounts = <String, int>{};
    for (final e in chapterPageCounts.entries) {
      if (e.value <= 0) continue;

      String? key;
      if (e.key.startsWith('[')) {
        try {
          _decodeChapterKey(e.key);
          if (resolvedKeys.contains(e.key) ||
              occurrenceMap.values.contains(e.key)) {
            key = e.key;
          }
        } catch (_) {}
      }

      if (key == null) {
        if (counts[e.key] == 1) {
          final g = groups[e.key]?.first;
          key = _occurrenceKey(g, e.key);
        }
      }

      if (key != null) {
        resolvedPageCounts[key] = e.value;
      }
    }

    return ComicUpdateSnapshot._(
      chapterKeys: Set.unmodifiable(resolvedKeys),
      updateTime: updateTime,
      maxPage: validMaxPage,
      chapterPageCounts: Map.unmodifiable(resolvedPageCounts),
      occurrenceToKey: Map.unmodifiable(occurrenceMap),
      chapterGroups: Map.unmodifiable(
        groups.map((k, v) => MapEntry(k, Set.unmodifiable(v))),
      ),
      idCounts: Map.unmodifiable(counts),
      occurrences: List.unmodifiable(items),
      hasReliableChapters: true,
    );
  }

  String? chapterKeyFor(String chapterId, {String? groupId}) {
    if (!hasReliableChapters) return null;

    if (groupId != null && groupId.isNotEmpty) {
      final key = occurrenceToKey[(groupId, chapterId)];
      if (key != null) return key;
      if (idCounts[chapterId] == 1) {
        return _encodeUnique(chapterId);
      }
      return null;
    }

    if (idCounts[chapterId] == 1) {
      return _encodeUnique(chapterId);
    }

    return null;
  }

  String occurrenceKeyFor(String chapterId, {String? groupId}) {
    if (groupId != null && groupId.isNotEmpty) {
      return _occurrenceKey(groupId, chapterId);
    }
    final g = chapterGroups[chapterId];
    if (g != null && g.length == 1 && g.first.isNotEmpty) {
      return _occurrenceKey(g.first, chapterId);
    }
    return _encodeUnique(chapterId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComicUpdateSnapshot &&
          runtimeType == other.runtimeType &&
          updateTime == other.updateTime &&
          maxPage == other.maxPage &&
          hasReliableChapters == other.hasReliableChapters &&
          _setEquals(chapterKeys, other.chapterKeys) &&
          _mapEquals(chapterPageCounts, other.chapterPageCounts);

  @override
  int get hashCode => Object.hash(
    updateTime,
    maxPage,
    hasReliableChapters,
    Object.hashAllUnordered(chapterKeys),
    Object.hashAllUnordered(
      chapterPageCounts.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

class ComicUpdateObservation {
  final ComicUpdateState state;
  final ComicUpdateCheckStatus status;
  final int newChapterCount;

  const ComicUpdateObservation({
    required this.state,
    required this.status,
    required this.newChapterCount,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComicUpdateObservation &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          status == other.status &&
          newChapterCount == other.newChapterCount;

  @override
  int get hashCode => Object.hash(state, status, newChapterCount);

  @override
  String toString() =>
      'ComicUpdateObservation(status: $status, newChapterCount: $newChapterCount, state: $state)';
}

class ComicUpdateState {
  final Set<String> knownChapterKeys;
  final Set<String> updatedChapterKeys;
  final Set<String> acknowledgedChapterKeys;
  final String? updateTime;
  final String? updatedUpdateTime;
  final String? acknowledgedUpdateTime;
  final int? maxPage;
  final int? updatedMaxPage;
  final int? acknowledgedMaxPage;
  final Map<String, int> chapterPageCounts;
  final Map<String, int> updatedChapterPages;
  final Map<String, int> acknowledgedChapterPages;
  final Map<String, Set<String>> knownChapterGroups;
  final bool legacyUnread;
  final bool legacyAcknowledged;
  final bool hasBaseline;

  const ComicUpdateState._({
    required this.knownChapterKeys,
    required this.updatedChapterKeys,
    required this.acknowledgedChapterKeys,
    required this.updateTime,
    required this.updatedUpdateTime,
    required this.acknowledgedUpdateTime,
    required this.maxPage,
    required this.updatedMaxPage,
    required this.acknowledgedMaxPage,
    required this.chapterPageCounts,
    required this.updatedChapterPages,
    required this.acknowledgedChapterPages,
    required this.knownChapterGroups,
    required this.legacyUnread,
    required this.legacyAcknowledged,
    required this.hasBaseline,
  });

  const ComicUpdateState.empty()
    : knownChapterKeys = const <String>{},
      updatedChapterKeys = const <String>{},
      acknowledgedChapterKeys = const <String>{},
      updateTime = null,
      updatedUpdateTime = null,
      acknowledgedUpdateTime = null,
      maxPage = null,
      updatedMaxPage = null,
      acknowledgedMaxPage = null,
      chapterPageCounts = const <String, int>{},
      updatedChapterPages = const <String, int>{},
      acknowledgedChapterPages = const <String, int>{},
      knownChapterGroups = const <String, Set<String>>{},
      legacyUnread = false,
      legacyAcknowledged = false,
      hasBaseline = false;

  ComicUpdateState.fromLegacy({this.updateTime, bool unread = false})
    : knownChapterKeys = const <String>{},
      updatedChapterKeys = const <String>{},
      acknowledgedChapterKeys = const <String>{},
      updatedUpdateTime = null,
      acknowledgedUpdateTime = null,
      maxPage = null,
      updatedMaxPage = null,
      acknowledgedMaxPage = null,
      chapterPageCounts = const <String, int>{},
      updatedChapterPages = const <String, int>{},
      acknowledgedChapterPages = const <String, int>{},
      knownChapterGroups = const <String, Set<String>>{},
      legacyUnread = unread,
      legacyAcknowledged = false,
      hasBaseline = updateTime != null;

  factory ComicUpdateState.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected Map for ComicUpdateState.fromJson');
    }

    final version = value['version'];
    if (version is! int || version != 1) {
      throw FormatException(
        'Unsupported ComicUpdateState schema version: $version',
      );
    }

    Set<String> parseSet(String fieldName) {
      final v = value[fieldName];
      if (v == null) return const <String>{};
      if (v is! List) {
        throw FormatException('Expected List for $fieldName');
      }
      return Set<String>.unmodifiable(
        v.map((e) {
          if (e is! String) {
            throw FormatException('Expected List<String> for $fieldName');
          }
          _decodeChapterKey(e);
          return e;
        }),
      );
    }

    Map<String, int> parsePageMap(String fieldName) {
      final v = value[fieldName];
      if (v == null) return const <String, int>{};
      if (v is! Map) {
        throw FormatException('Expected Map for $fieldName');
      }
      final res = <String, int>{};
      for (final e in v.entries) {
        if (e.key is! String || e.value is! int || (e.value as int) <= 0) {
          throw FormatException(
            'Expected Map<String, positive int> for $fieldName',
          );
        }
        _decodeChapterKey(e.key as String);
        res[e.key as String] = e.value as int;
      }
      return Map<String, int>.unmodifiable(res);
    }

    Map<String, Set<String>> parseGroupMap(String fieldName) {
      final v = value[fieldName];
      if (v == null) return const <String, Set<String>>{};
      if (v is! Map) {
        throw FormatException('Expected Map for $fieldName');
      }
      final res = <String, Set<String>>{};
      for (final e in v.entries) {
        if (e.key is! String || e.value is! List) {
          throw FormatException(
            'Expected Map<String, List<String>> for $fieldName',
          );
        }
        res[e.key as String] = Set<String>.unmodifiable(
          (e.value as List).map((x) {
            if (x is! String) {
              throw FormatException('Expected List<String> in $fieldName');
            }
            return x;
          }),
        );
      }
      return Map<String, Set<String>>.unmodifiable(res);
    }

    int? parsePositiveInt(String fieldName) {
      final v = value[fieldName];
      if (v == null) return null;
      if (v is! int || v <= 0) {
        throw FormatException('Expected positive int for $fieldName');
      }
      return v;
    }

    String? parseString(String fieldName) {
      final v = value[fieldName];
      if (v == null) return null;
      if (v is! String) {
        throw FormatException('Expected String for $fieldName');
      }
      return v;
    }

    bool parseBool(String fieldName) {
      final v = value[fieldName];
      if (v == null) return false;
      if (v is! bool) {
        throw FormatException('Expected bool for $fieldName');
      }
      return v;
    }

    return ComicUpdateState._(
      knownChapterKeys: parseSet('knownChapterKeys'),
      updatedChapterKeys: parseSet('updatedChapterKeys'),
      acknowledgedChapterKeys: parseSet('acknowledgedChapterKeys'),
      updateTime: parseString('updateTime'),
      updatedUpdateTime: parseString('updatedUpdateTime'),
      acknowledgedUpdateTime: parseString('acknowledgedUpdateTime'),
      maxPage: parsePositiveInt('maxPage'),
      updatedMaxPage: parsePositiveInt('updatedMaxPage'),
      acknowledgedMaxPage: parsePositiveInt('acknowledgedMaxPage'),
      chapterPageCounts: parsePageMap('chapterPageCounts'),
      updatedChapterPages: parsePageMap('updatedChapterPages'),
      acknowledgedChapterPages: parsePageMap('acknowledgedChapterPages'),
      knownChapterGroups: parseGroupMap('knownChapterGroups'),
      legacyUnread: parseBool('legacyUnread'),
      legacyAcknowledged: parseBool('legacyAcknowledged'),
      hasBaseline: parseBool('hasBaseline'),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'version': 1,
      'hasBaseline': hasBaseline,
      if (updateTime != null) 'updateTime': updateTime,
      if (updatedUpdateTime != null) 'updatedUpdateTime': updatedUpdateTime,
      if (acknowledgedUpdateTime != null)
        'acknowledgedUpdateTime': acknowledgedUpdateTime,
      if (maxPage != null) 'maxPage': maxPage,
      if (updatedMaxPage != null) 'updatedMaxPage': updatedMaxPage,
      if (acknowledgedMaxPage != null)
        'acknowledgedMaxPage': acknowledgedMaxPage,
      if (knownChapterKeys.isNotEmpty)
        'knownChapterKeys': (knownChapterKeys.toList()..sort()),
      if (updatedChapterKeys.isNotEmpty)
        'updatedChapterKeys': (updatedChapterKeys.toList()..sort()),
      if (acknowledgedChapterKeys.isNotEmpty)
        'acknowledgedChapterKeys': (acknowledgedChapterKeys.toList()..sort()),
      if (chapterPageCounts.isNotEmpty)
        'chapterPageCounts': Map.fromEntries(
          chapterPageCounts.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)),
        ),
      if (updatedChapterPages.isNotEmpty)
        'updatedChapterPages': Map.fromEntries(
          updatedChapterPages.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)),
        ),
      if (acknowledgedChapterPages.isNotEmpty)
        'acknowledgedChapterPages': Map.fromEntries(
          acknowledgedChapterPages.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)),
        ),
      if (knownChapterGroups.isNotEmpty)
        'knownChapterGroups': Map.fromEntries(
          knownChapterGroups.entries
              .map((e) => MapEntry(e.key, e.value.toList()..sort()))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key)),
        ),
      if (legacyUnread) 'legacyUnread': true,
      if (legacyAcknowledged) 'legacyAcknowledged': true,
    };
  }

  bool get isEmpty =>
      !hasBaseline &&
      updateTime == null &&
      updatedUpdateTime == null &&
      acknowledgedUpdateTime == null &&
      maxPage == null &&
      updatedMaxPage == null &&
      acknowledgedMaxPage == null &&
      knownChapterKeys.isEmpty &&
      updatedChapterKeys.isEmpty &&
      acknowledgedChapterKeys.isEmpty &&
      chapterPageCounts.isEmpty &&
      updatedChapterPages.isEmpty &&
      acknowledgedChapterPages.isEmpty &&
      knownChapterGroups.isEmpty &&
      !legacyUnread &&
      !legacyAcknowledged;

  bool get hasNewUpdate {
    if (legacyUnread && !legacyAcknowledged) {
      return true;
    }
    for (final key in updatedChapterKeys) {
      if (!acknowledgedChapterKeys.contains(key)) {
        return true;
      }
    }
    for (final entry in updatedChapterPages.entries) {
      final acked = acknowledgedChapterPages[entry.key] ?? 0;
      if (entry.value > acked) {
        return true;
      }
    }
    if (updatedUpdateTime != null) {
      if (acknowledgedUpdateTime == null) {
        return true;
      }
      if (_isTimestampForward(acknowledgedUpdateTime, updatedUpdateTime)) {
        return true;
      }
    }
    if (updatedMaxPage != null) {
      if (acknowledgedMaxPage == null ||
          updatedMaxPage! > acknowledgedMaxPage!) {
        return true;
      }
    }
    return false;
  }

  ComicUpdateObservation observe(ComicUpdateSnapshot snapshot) {
    final hasChapters = snapshot.hasReliableChapters;
    final hasTime = snapshot.updateTime != null;
    final hasPages =
        snapshot.maxPage != null || snapshot.chapterPageCounts.isNotEmpty;
    final hasSignals = hasChapters || hasTime || hasPages;

    if (!hasSignals) {
      return ComicUpdateObservation(
        state: this,
        status: ComicUpdateCheckStatus.unknown,
        newChapterCount: 0,
      );
    }

    if (!hasBaseline) {
      final nextGroups = <String, Set<String>>{};
      if (hasChapters) {
        for (final entry in snapshot.chapterGroups.entries) {
          nextGroups[entry.key] = Set<String>.from(entry.value);
        }
      }

      final nextState = ComicUpdateState._(
        knownChapterKeys: hasChapters ? snapshot.chapterKeys : const <String>{},
        updatedChapterKeys: const <String>{},
        acknowledgedChapterKeys: acknowledgedChapterKeys,
        updateTime: snapshot.updateTime ?? updateTime,
        updatedUpdateTime: null,
        acknowledgedUpdateTime: acknowledgedUpdateTime,
        maxPage: snapshot.maxPage ?? maxPage,
        updatedMaxPage: null,
        acknowledgedMaxPage: acknowledgedMaxPage,
        chapterPageCounts: Map.unmodifiable(snapshot.chapterPageCounts),
        updatedChapterPages: const <String, int>{},
        acknowledgedChapterPages: acknowledgedChapterPages,
        knownChapterGroups: Map.unmodifiable(
          nextGroups.map((k, v) => MapEntry(k, Set.unmodifiable(v))),
        ),
        legacyUnread: legacyUnread,
        legacyAcknowledged: legacyAcknowledged,
        hasBaseline: true,
      );
      return ComicUpdateObservation(
        state: nextState,
        status: ComicUpdateCheckStatus.baseline,
        newChapterCount: 0,
      );
    }

    final introducesChapterDimension = knownChapterKeys.isEmpty && hasChapters;
    final newChapterKeys = <String>{};
    final unacknowledgedNewKeys = <String>{};

    final nextGroups = <String, Set<String>>{};
    for (final e in knownChapterGroups.entries) {
      nextGroups[e.key] = Set<String>.from(e.value);
    }

    if (hasChapters) {
      for (final occ in snapshot.occurrences) {
        final gId = occ.groupId;
        final chId = occ.chapterId;
        final key = snapshot.occurrenceToKey[(gId, chId)]!;
        final knownForId = nextGroups[chId];
        var isKnown = false;

        if (knownForId != null && knownForId.isNotEmpty) {
          if (knownForId.contains(gId ?? '')) {
            isKnown = true;
          } else if (snapshot.idCounts[chId] == 1 && knownForId.length == 1) {
            // Unique ID group rename
            isKnown = true;
          }
        }

        if (!introducesChapterDimension && !isKnown) {
          newChapterKeys.add(key);

          var isAcked = acknowledgedChapterKeys.contains(key);
          if (!isAcked) {
            final grpKey = _encodeGrouped(gId, chId);
            if (acknowledgedChapterKeys.contains(grpKey)) {
              isAcked = true;
            } else if (knownForId == null || knownForId.length <= 1) {
              if (acknowledgedChapterKeys.contains(_encodeUnique(chId))) {
                isAcked = true;
              }
            }
          }

          if (!isAcked) {
            unacknowledgedNewKeys.add(key);
          }
        }
      }

      for (final entry in snapshot.chapterGroups.entries) {
        nextGroups.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
      }
    }

    final isForward = _isTimestampForward(updateTime, snapshot.updateTime);
    final isUnackForward =
        isForward &&
        (acknowledgedUpdateTime == null ||
            _isTimestampForward(acknowledgedUpdateTime, snapshot.updateTime));

    final isMaxPageGrowth =
        maxPage != null &&
        snapshot.maxPage != null &&
        snapshot.maxPage! > maxPage!;
    final isUnackMaxPageGrowth =
        isMaxPageGrowth &&
        (acknowledgedMaxPage == null ||
            snapshot.maxPage! > acknowledgedMaxPage!);

    var hasUnackChapterPageGrowth = false;
    final nextUpdatedChapterPages = Map<String, int>.from(updatedChapterPages);
    for (final e in snapshot.chapterPageCounts.entries) {
      final curCount = chapterPageCounts[e.key] ?? 0;
      if (curCount > 0 && e.value > curCount) {
        final ackedCount = acknowledgedChapterPages[e.key] ?? 0;
        if (e.value > ackedCount) {
          hasUnackChapterPageGrowth = true;
        }
        nextUpdatedChapterPages[e.key] = math.max(
          nextUpdatedChapterPages[e.key] ?? 0,
          e.value,
        );
      }
    }

    final isUpdated =
        unacknowledgedNewKeys.isNotEmpty ||
        isUnackForward ||
        isUnackMaxPageGrowth ||
        hasUnackChapterPageGrowth;

    final status = isUpdated
        ? ComicUpdateCheckStatus.updated
        : (introducesChapterDimension
              ? ComicUpdateCheckStatus.baseline
              : ComicUpdateCheckStatus.unchanged);

    final nextKnown = Set<String>.from(knownChapterKeys);
    if (hasChapters) {
      nextKnown.addAll(snapshot.chapterKeys);
    }

    final nextUpdated = Set<String>.from(updatedChapterKeys);
    if (newChapterKeys.isNotEmpty) {
      nextUpdated.addAll(newChapterKeys);
    }

    final nextUpdateTime = _maxTimestamp(updateTime, snapshot.updateTime);
    final nextUpdatedUpdateTime = isForward
        ? _maxTimestamp(updatedUpdateTime, snapshot.updateTime)
        : updatedUpdateTime;

    final nextMaxPage = _maxNullableInt(maxPage, snapshot.maxPage);
    final nextUpdatedMaxPage = isMaxPageGrowth
        ? _maxNullableInt(updatedMaxPage, snapshot.maxPage)
        : updatedMaxPage;

    final nextPageCounts = Map<String, int>.from(chapterPageCounts);
    for (final e in snapshot.chapterPageCounts.entries) {
      final cur = nextPageCounts[e.key];
      nextPageCounts[e.key] = cur == null ? e.value : math.max(cur, e.value);
    }

    final nextState = ComicUpdateState._(
      knownChapterKeys: Set.unmodifiable(nextKnown),
      updatedChapterKeys: Set.unmodifiable(nextUpdated),
      acknowledgedChapterKeys: acknowledgedChapterKeys,
      updateTime: nextUpdateTime,
      updatedUpdateTime: nextUpdatedUpdateTime,
      acknowledgedUpdateTime: acknowledgedUpdateTime,
      maxPage: nextMaxPage,
      updatedMaxPage: nextUpdatedMaxPage,
      acknowledgedMaxPage: acknowledgedMaxPage,
      chapterPageCounts: Map.unmodifiable(nextPageCounts),
      updatedChapterPages: Map.unmodifiable(nextUpdatedChapterPages),
      acknowledgedChapterPages: acknowledgedChapterPages,
      knownChapterGroups: Map.unmodifiable(
        nextGroups.map((k, v) => MapEntry(k, Set.unmodifiable(v))),
      ),
      legacyUnread: legacyUnread,
      legacyAcknowledged: legacyAcknowledged,
      hasBaseline: true,
    );

    return ComicUpdateObservation(
      state: nextState,
      status: status,
      newChapterCount: unacknowledgedNewKeys.length,
    );
  }

  ComicUpdateState merge(ComicUpdateState other) {
    if (isEmpty) return other;
    if (other.isEmpty) return this;

    final mergedKnown = Set<String>.from(knownChapterKeys)
      ..addAll(other.knownChapterKeys);
    final mergedUpdated = Set<String>.from(updatedChapterKeys)
      ..addAll(other.updatedChapterKeys);
    final mergedAcked = Set<String>.from(acknowledgedChapterKeys)
      ..addAll(other.acknowledgedChapterKeys);

    final mergedUpdateTime = _maxTimestamp(updateTime, other.updateTime);
    final mergedUpdatedUpdateTime = _maxTimestamp(
      updatedUpdateTime,
      other.updatedUpdateTime,
    );
    final mergedAckedUpdateTime = _maxTimestamp(
      acknowledgedUpdateTime,
      other.acknowledgedUpdateTime,
    );

    final mergedMaxPage = _maxNullableInt(maxPage, other.maxPage);
    final mergedUpdatedMaxPage = _maxNullableInt(
      updatedMaxPage,
      other.updatedMaxPage,
    );
    final mergedAckedMaxPage = _maxNullableInt(
      acknowledgedMaxPage,
      other.acknowledgedMaxPage,
    );

    final mergedPageCounts = <String, int>{};
    for (final e in chapterPageCounts.entries) {
      mergedPageCounts[e.key] = e.value;
    }
    for (final e in other.chapterPageCounts.entries) {
      final cur = mergedPageCounts[e.key];
      mergedPageCounts[e.key] = cur == null ? e.value : math.max(cur, e.value);
    }

    final mergedUpdatedPages = <String, int>{};
    for (final e in updatedChapterPages.entries) {
      mergedUpdatedPages[e.key] = e.value;
    }
    for (final e in other.updatedChapterPages.entries) {
      final cur = mergedUpdatedPages[e.key];
      mergedUpdatedPages[e.key] = cur == null
          ? e.value
          : math.max(cur, e.value);
    }

    final mergedAckedPages = <String, int>{};
    for (final e in acknowledgedChapterPages.entries) {
      mergedAckedPages[e.key] = e.value;
    }
    for (final e in other.acknowledgedChapterPages.entries) {
      final cur = mergedAckedPages[e.key];
      mergedAckedPages[e.key] = cur == null ? e.value : math.max(cur, e.value);
    }

    final mergedGroups = <String, Set<String>>{};
    for (final e in knownChapterGroups.entries) {
      mergedGroups[e.key] = Set<String>.from(e.value);
    }
    for (final e in other.knownChapterGroups.entries) {
      final cur = mergedGroups[e.key];
      if (cur == null) {
        mergedGroups[e.key] = Set<String>.from(e.value);
      } else {
        cur.addAll(e.value);
      }
    }

    final mergedLegacyAcked = legacyAcknowledged || other.legacyAcknowledged;
    final mergedLegacyUnread =
        (legacyUnread || other.legacyUnread) && !mergedLegacyAcked;
    final mergedHasBaseline = hasBaseline || other.hasBaseline;

    return ComicUpdateState._(
      knownChapterKeys: Set.unmodifiable(mergedKnown),
      updatedChapterKeys: Set.unmodifiable(mergedUpdated),
      acknowledgedChapterKeys: Set.unmodifiable(mergedAcked),
      updateTime: mergedUpdateTime,
      updatedUpdateTime: mergedUpdatedUpdateTime,
      acknowledgedUpdateTime: mergedAckedUpdateTime,
      maxPage: mergedMaxPage,
      updatedMaxPage: mergedUpdatedMaxPage,
      acknowledgedMaxPage: mergedAckedMaxPage,
      chapterPageCounts: Map.unmodifiable(mergedPageCounts),
      updatedChapterPages: Map.unmodifiable(mergedUpdatedPages),
      acknowledgedChapterPages: Map.unmodifiable(mergedAckedPages),
      knownChapterGroups: Map.unmodifiable(
        mergedGroups.map((k, v) => MapEntry(k, Set.unmodifiable(v))),
      ),
      legacyUnread: mergedLegacyUnread,
      legacyAcknowledged: mergedLegacyAcked,
      hasBaseline: mergedHasBaseline,
    );
  }

  ComicUpdateState acknowledgeAll() {
    if (isEmpty) return this;

    final newAckedChapters = Set<String>.from(acknowledgedChapterKeys)
      ..addAll(updatedChapterKeys)
      ..addAll(knownChapterKeys);

    final newAckedChapterPages = Map<String, int>.from(
      acknowledgedChapterPages,
    );
    for (final e in updatedChapterPages.entries) {
      newAckedChapterPages[e.key] = math.max(
        newAckedChapterPages[e.key] ?? 0,
        e.value,
      );
    }
    for (final e in chapterPageCounts.entries) {
      newAckedChapterPages[e.key] = math.max(
        newAckedChapterPages[e.key] ?? 0,
        e.value,
      );
    }

    final newAckedUpdateTime = _maxTimestamp(
      acknowledgedUpdateTime,
      _maxTimestamp(updateTime, updatedUpdateTime),
    );

    final newAckedMaxPage = _maxNullableInt(
      acknowledgedMaxPage,
      _maxNullableInt(maxPage, updatedMaxPage),
    );

    return ComicUpdateState._(
      knownChapterKeys: knownChapterKeys,
      updatedChapterKeys: updatedChapterKeys,
      acknowledgedChapterKeys: Set.unmodifiable(newAckedChapters),
      updateTime: updateTime,
      updatedUpdateTime: updatedUpdateTime,
      acknowledgedUpdateTime: newAckedUpdateTime,
      maxPage: maxPage,
      updatedMaxPage: updatedMaxPage,
      acknowledgedMaxPage: newAckedMaxPage,
      chapterPageCounts: chapterPageCounts,
      updatedChapterPages: updatedChapterPages,
      acknowledgedChapterPages: Map.unmodifiable(newAckedChapterPages),
      knownChapterGroups: knownChapterGroups,
      legacyUnread: false,
      legacyAcknowledged: true,
      hasBaseline: hasBaseline,
    );
  }

  ComicUpdateState acknowledgeSnapshot(
    ComicUpdateSnapshot snapshot, {
    required String chapterId,
    String? groupId,
    required bool isLastChapter,
  }) {
    final occKey = snapshot.occurrenceKeyFor(chapterId, groupId: groupId);
    final resolvedKey =
        snapshot.chapterKeyFor(chapterId, groupId: groupId) ?? occKey;

    final nextAckedChapters = Set<String>.from(acknowledgedChapterKeys)
      ..add(occKey)
      ..add(resolvedKey);

    final actualGroup =
        groupId ??
        (snapshot.chapterGroups[chapterId]?.length == 1
            ? snapshot.chapterGroups[chapterId]!.first
            : null);
    if (actualGroup != null && actualGroup.isNotEmpty) {
      nextAckedChapters.add(_encodeGrouped(actualGroup, chapterId));
    }
    if (snapshot.idCounts[chapterId] == 1 &&
        (knownChapterGroups[chapterId]?.length ?? 1) <= 1) {
      nextAckedChapters.add(_encodeUnique(chapterId));
    }

    final nextAckedChapterPages = Map<String, int>.from(
      acknowledgedChapterPages,
    );
    final visibleCount =
        snapshot.chapterPageCounts[occKey] ??
        snapshot.chapterPageCounts[resolvedKey] ??
        snapshot.chapterPageCounts[chapterId];
    if (visibleCount != null && visibleCount > 0) {
      nextAckedChapterPages[occKey] = math.max(
        nextAckedChapterPages[occKey] ?? 0,
        visibleCount,
      );
      nextAckedChapterPages[resolvedKey] = math.max(
        nextAckedChapterPages[resolvedKey] ?? 0,
        visibleCount,
      );
    }
    var nextAckedUpdateTime = acknowledgedUpdateTime;
    var nextAckedMaxPage = acknowledgedMaxPage;
    var nextLegacyUnread = legacyUnread;
    var nextLegacyAcked = legacyAcknowledged;

    if (isLastChapter || !snapshot.hasReliableChapters) {
      if (snapshot.updateTime != null) {
        nextAckedUpdateTime = _maxTimestamp(
          acknowledgedUpdateTime,
          snapshot.updateTime,
        );
      }
      if (snapshot.maxPage != null) {
        nextAckedMaxPage = _maxNullableInt(
          acknowledgedMaxPage,
          snapshot.maxPage,
        );
      }
      nextLegacyUnread = false;
      nextLegacyAcked = true;
    }

    return ComicUpdateState._(
      knownChapterKeys: knownChapterKeys,
      updatedChapterKeys: updatedChapterKeys,
      acknowledgedChapterKeys: Set.unmodifiable(nextAckedChapters),
      updateTime: updateTime,
      updatedUpdateTime: updatedUpdateTime,
      acknowledgedUpdateTime: nextAckedUpdateTime,
      maxPage: maxPage,
      updatedMaxPage: updatedMaxPage,
      acknowledgedMaxPage: nextAckedMaxPage,
      chapterPageCounts: chapterPageCounts,
      updatedChapterPages: updatedChapterPages,
      acknowledgedChapterPages: Map.unmodifiable(nextAckedChapterPages),
      knownChapterGroups: knownChapterGroups,
      legacyUnread: nextLegacyUnread,
      legacyAcknowledged: nextLegacyAcked,
      hasBaseline: hasBaseline,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ComicUpdateState) return false;

    return updateTime == other.updateTime &&
        updatedUpdateTime == other.updatedUpdateTime &&
        acknowledgedUpdateTime == other.acknowledgedUpdateTime &&
        maxPage == other.maxPage &&
        updatedMaxPage == other.updatedMaxPage &&
        acknowledgedMaxPage == other.acknowledgedMaxPage &&
        legacyUnread == other.legacyUnread &&
        legacyAcknowledged == other.legacyAcknowledged &&
        hasBaseline == other.hasBaseline &&
        _setEquals(knownChapterKeys, other.knownChapterKeys) &&
        _setEquals(updatedChapterKeys, other.updatedChapterKeys) &&
        _setEquals(acknowledgedChapterKeys, other.acknowledgedChapterKeys) &&
        _mapEquals(chapterPageCounts, other.chapterPageCounts) &&
        _mapEquals(updatedChapterPages, other.updatedChapterPages) &&
        _mapEquals(acknowledgedChapterPages, other.acknowledgedChapterPages) &&
        _nestedMapSetEquals(knownChapterGroups, other.knownChapterGroups);
  }

  @override
  int get hashCode => Object.hash(
    updateTime,
    updatedUpdateTime,
    acknowledgedUpdateTime,
    maxPage,
    updatedMaxPage,
    acknowledgedMaxPage,
    legacyUnread,
    legacyAcknowledged,
    hasBaseline,
    Object.hashAllUnordered(knownChapterKeys),
    Object.hashAllUnordered(updatedChapterKeys),
    Object.hashAllUnordered(acknowledgedChapterKeys),
    Object.hashAllUnordered(
      chapterPageCounts.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      updatedChapterPages.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      acknowledgedChapterPages.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      knownChapterGroups.entries.map(
        (e) => Object.hash(e.key, Object.hashAllUnordered(e.value)),
      ),
    ),
  );

  @override
  String toString() =>
      'ComicUpdateState(updateTime: $updateTime, hasNewUpdate: $hasNewUpdate, known: ${knownChapterKeys.length}, updated: ${updatedChapterKeys.length}, acked: ${acknowledgedChapterKeys.length})';
}

bool _isDateOnly(String s) {
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s.trim());
}

DateTime? _parseCalendarDay(String s) {
  if (_isDateOnly(s)) {
    final parts = s.trim().split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (y < 2000 || y > 3000 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    return DateTime.utc(y, m, d);
  }
  final dt = DateTime.tryParse(s);
  if (dt == null) return null;
  final utc = dt.toUtc();
  if (utc.year < 2000 || utc.year > 3000) return null;
  return DateTime.utc(utc.year, utc.month, utc.day);
}

DateTime? _parseInstant(String s) {
  if (_isDateOnly(s)) return null;
  final dt = DateTime.tryParse(s);
  if (dt == null) return null;
  final utc = dt.toUtc();
  if (utc.year < 2000 || utc.year > 3000) return null;
  return utc;
}

bool _isTimestampForward(String? current, String? candidate) {
  if (candidate == null) return false;
  final canDay = _parseCalendarDay(candidate);
  if (canDay == null) return false;

  if (current == null) {
    return false;
  }

  final curDay = _parseCalendarDay(current);
  if (curDay == null) {
    return true;
  }

  final curDateOnly = _isDateOnly(current);
  final canDateOnly = _isDateOnly(candidate);

  if (curDateOnly || canDateOnly) {
    return canDay.isAfter(curDay);
  }

  final curInst = _parseInstant(current);
  final canInst = _parseInstant(candidate);
  if (curInst == null || canInst == null) {
    return false;
  }
  return canInst.isAfter(curInst);
}

String? _maxTimestamp(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a == b) return a;

  final aDay = _parseCalendarDay(a);
  final bDay = _parseCalendarDay(b);

  if (aDay == null && bDay != null) return b;
  if (bDay == null && aDay != null) return a;
  if (aDay == null && bDay == null) return a.compareTo(b) >= 0 ? a : b;

  if (_isTimestampForward(a, b)) return b;
  if (_isTimestampForward(b, a)) return a;

  final aDateOnly = _isDateOnly(a);
  final bDateOnly = _isDateOnly(b);

  if (aDateOnly && !bDateOnly) return b;
  if (!aDateOnly && bDateOnly) return a;

  return a.compareTo(b) >= 0 ? a : b;
}

int? _maxNullableInt(int? a, int? b) {
  if (a == null) return b;
  if (b == null) return a;
  return math.max(a, b);
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || a[key] != b[key]) return false;
  }
  return true;
}

bool _nestedMapSetEquals(
  Map<String, Set<String>> a,
  Map<String, Set<String>> b,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final bSet = b[entry.key];
    if (bSet == null || !_setEquals(entry.value, bSet)) {
      return false;
    }
  }
  return true;
}
