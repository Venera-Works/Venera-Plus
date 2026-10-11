import 'dart:convert';

import 'package:venera_plus/foundation/sync_records.dart';

enum ReadingNavigationSource {
  userBackward,
  userSeek,

  /// Confirms the already visible position without moving backwards.
  userConfirm,
  userForward,
  automatic,
  restore,
  layout,
  passive,
}

class UnsupportedReadingProgressVersionException
    extends UnsupportedSyncProtocolException {
  const UnsupportedReadingProgressVersionException(int version)
    : super('reading progress', version);
}

class ReadingChapter {
  const ReadingChapter({
    required this.id,
    required this.ep,
    this.group,
    this.groupId,
  });

  final String id;
  final int ep;
  final int? group;
  final String? groupId;

  Map<String, Object?> toJson() => {
    'id': id,
    'ep': ep,
    'group': group,
    'groupId': groupId,
  };

  factory ReadingChapter.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Reading chapter must be an object');
    }
    final id = value['id'];
    final ep = value['ep'];
    final group = value['group'];
    final groupId = value['groupId'];
    if (id is! String ||
        ep is! int ||
        (group != null && group is! int) ||
        (groupId != null && groupId is! String)) {
      throw const FormatException('Invalid reading chapter');
    }
    return ReadingChapter(
      id: id,
      ep: ep,
      group: group as int?,
      groupId: groupId as String?,
    );
  }
}

/// Source chapter order and stable identities used to compare positions.
/// The input order is authoritative; chapter titles and IDs are never sorted.
class ReadingCatalog {
  ReadingCatalog(List<ReadingChapter> chapters)
    : chapters = List<ReadingChapter>.unmodifiable(chapters) {
    final byId = <String, List<int>>{};
    for (var index = 0; index < this.chapters.length; index++) {
      byId.putIfAbsent(this.chapters[index].id, () => <int>[]).add(index);
    }
    _indicesById = byId;
  }

  final List<ReadingChapter> chapters;
  late final Map<String, List<int>> _indicesById;

  Map<String, Object?> toJson() => {
    'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
  };

  factory ReadingCatalog.fromJson(Object? value) {
    if (value is! Map || value['chapters'] is! List) {
      throw const FormatException('Reading catalog must contain chapters');
    }
    return ReadingCatalog(
      (value['chapters'] as List)
          .map(ReadingChapter.fromJson)
          .toList(growable: false),
    );
  }

  int? indexOf(ReadingPosition position) {
    final chapterId = position.chapterId;
    if (chapterId != null) {
      final candidates = _indicesById[chapterId];
      if (candidates == null) return null;
      if (candidates.length == 1) return candidates.single;
      int? match;
      for (final index in candidates) {
        final chapter = chapters[index];
        if (position.groupId != null
            ? chapter.groupId != position.groupId
            : position.group != null && chapter.group != position.group) {
          continue;
        }
        if (match != null) return null;
        match = index;
      }
      return match;
    }

    int? match;
    for (var index = 0; index < chapters.length; index++) {
      final chapter = chapters[index];
      if (chapter.ep != position.ep ||
          (position.groupId != null
              ? chapter.groupId != position.groupId
              : chapter.group != position.group)) {
        continue;
      }
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  ReadingPosition rebasePosition(ReadingPosition position) {
    final index = indexOf(position);
    if (index == null) return position;
    final chapter = chapters[index];
    return ReadingPosition(
      ep: chapter.ep,
      page: position.page,
      group: chapter.group,
      chapterId: chapter.id,
      groupId: chapter.groupId,
    );
  }
}

class ReadingPosition {
  const ReadingPosition({
    required this.ep,
    required this.page,
    this.group,
    this.chapterId,
    this.groupId,
  });

  /// Source chapter index (1-based), not a visual/spread index.
  final int ep;

  /// Source image index (1-based), not a visual/spread index.
  final int page;
  final int? group;
  final String? chapterId;
  final String? groupId;

  bool get isValid => ep > 0 && page > 0;

  Map<String, Object?> toJson() => {
    'ep': ep,
    'page': page,
    'group': group,
    'chapterId': chapterId,
    'groupId': groupId,
  };

  factory ReadingPosition.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Reading position must be an object');
    }
    final ep = value['ep'];
    final page = value['page'];
    final group = value['group'];
    final chapterId = value['chapterId'];
    final groupId = value['groupId'];
    if (ep is! int ||
        page is! int ||
        (group != null && group is! int) ||
        (chapterId != null && chapterId is! String) ||
        (groupId != null && groupId is! String)) {
      throw const FormatException('Invalid reading position');
    }
    final position = ReadingPosition(
      ep: ep,
      page: page,
      group: group as int?,
      chapterId: chapterId as String?,
      groupId: groupId as String?,
    );
    if (!position.isValid) {
      throw const FormatException('Reading position must be positive');
    }
    return position;
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      ep == other.ep &&
      page == other.page &&
      group == other.group &&
      chapterId == other.chapterId &&
      groupId == other.groupId;

  @override
  int get hashCode => Object.hash(ep, page, group, chapterId, groupId);

  @override
  String toString() => 'ReadingPosition(${jsonEncode(toJson())})';
}

ReadingPosition _positionAt(ReadingCatalog catalog, int index, int page) {
  final chapter = catalog.chapters[index];
  return ReadingPosition(
    ep: chapter.ep,
    page: page,
    group: chapter.group,
    chapterId: chapter.id,
    groupId: chapter.groupId,
  );
}

ReadingPosition? _rebaseUniquePosition(
  ReadingCatalog catalog,
  ReadingPosition position,
) {
  final index = catalog.indexOf(position);
  return index == null ? null : _positionAt(catalog, index, position.page);
}

class _ReadingRound {
  const _ReadingRound({required this.anchor, required this.cursor});

  final ReadingPosition anchor;
  final ReadingPosition cursor;

  Map<String, Object?> toJson() => {
    'anchor': anchor.toJson(),
    'cursor': cursor.toJson(),
  };
}

/// Joinable maximum progress and explicit reread-round state.
///
/// Round IDs are opaque command IDs. Retired and ended IDs are exact sets,
/// never interpreted as a causal sequence or counter prefix.
class ReadingProgress {
  ReadingProgress._({
    required List<ReadingPosition> maximum,
    required this.catalog,
    required Map<String, _ReadingRound> rounds,
    required Set<String> retired,
    required Set<String> ended,
    required this.time,
    bool immutable = false,
  }) : maximumPositions = immutable
           ? maximum
           : List<ReadingPosition>.unmodifiable(maximum),
       _rounds = immutable
           ? rounds
           : Map<String, _ReadingRound>.unmodifiable(rounds),
       _retired = immutable ? retired : Set<String>.unmodifiable(retired),
       _ended = immutable ? ended : Set<String>.unmodifiable(ended);

  final List<ReadingPosition> maximumPositions;
  final ReadingCatalog? catalog;
  final Map<String, _ReadingRound> _rounds;
  final Set<String> _retired;
  final Set<String> _ended;
  final int time;

  factory ReadingProgress.seed(
    ReadingPosition position, {
    int time = 0,
    ReadingCatalog? catalog,
  }) {
    if (!position.isValid) {
      return ReadingProgress._empty(time: time, catalog: catalog);
    }
    final rebased = catalog == null
        ? position
        : _rebaseUniquePosition(catalog, position) ?? position;
    return ReadingProgress._create(
      maximum: [rebased],
      catalog: catalog,
      rounds: const {},
      retired: const {},
      ended: const {},
      time: time,
    );
  }

  factory ReadingProgress.fromJson(Object? json) {
    if (json == null) return ReadingProgress._empty();
    if (json is! Map) {
      throw const FormatException('Reading progress must be an object');
    }
    final version = json['version'];
    if (version is! int) {
      throw const FormatException(
        'Reading progress version must be an integer',
      );
    }
    if (version != 1) {
      throw UnsupportedReadingProgressVersionException(version);
    }
    final rawMaximum = json['maximum'];
    final rawRounds = json['rounds'];
    final rawRetired = json['retired'];
    final rawEnded = json['ended'];
    final rawTime = json['time'];
    if (rawMaximum is! List ||
        rawRounds is! Map ||
        rawRetired is! List ||
        rawEnded is! List ||
        rawTime is! int) {
      throw const FormatException('Invalid reading progress fields');
    }

    final catalogValue = json['catalog'];
    final catalog = catalogValue == null
        ? null
        : ReadingCatalog.fromJson(catalogValue);
    final maximum = rawMaximum
        .map(ReadingPosition.fromJson)
        .cast<ReadingPosition>()
        .toList(growable: false);
    final retired = _readIdSet(rawRetired, 'retired');
    final ended = _readIdSet(rawEnded, 'ended');
    final rounds = <String, _ReadingRound>{};
    for (final entry in rawRounds.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid reading round');
      }
      final id = entry.key as String;
      final rawRound = entry.value as Map;
      if (!rawRound.containsKey('anchor') || !rawRound.containsKey('cursor')) {
        throw const FormatException('Reading round needs anchor and cursor');
      }
      final anchor = ReadingPosition.fromJson(rawRound['anchor']);
      final cursor = ReadingPosition.fromJson(rawRound['cursor']);
      if (!retired.contains(id) && !ended.contains(id)) {
        rounds[id] = _ReadingRound(
          anchor: catalog == null
              ? anchor
              : _rebaseUniquePosition(catalog, anchor) ?? anchor,
          cursor: catalog == null
              ? cursor
              : _rebaseUniquePosition(catalog, cursor) ?? cursor,
        );
      }
    }
    return ReadingProgress._create(
      maximum: maximum,
      catalog: catalog,
      rounds: rounds,
      retired: retired,
      ended: ended,
      time: rawTime,
    );
  }

  factory ReadingProgress._empty({int time = 0, ReadingCatalog? catalog}) =>
      ReadingProgress._(
        maximum: const [],
        catalog: catalog,
        rounds: const {},
        retired: const {},
        ended: const {},
        time: time,
        immutable: true,
      );

  factory ReadingProgress._create({
    required Iterable<ReadingPosition> maximum,
    required ReadingCatalog? catalog,
    required Map<String, _ReadingRound> rounds,
    required Set<String> retired,
    required Set<String> ended,
    required int time,
    ReadingProgress? previous,
    bool maximumIsPruned = false,
  }) {
    final nextMaximum = identical(maximum, previous?.maximumPositions)
        ? previous!.maximumPositions
        : List<ReadingPosition>.unmodifiable(
            maximumIsPruned ? maximum : _pruneMaximum(maximum, catalog),
          );
    final nextRetired = identical(retired, previous?._retired)
        ? previous!._retired
        : Set<String>.unmodifiable(retired);
    final nextEnded = identical(ended, previous?._ended)
        ? previous!._ended
        : Set<String>.unmodifiable(ended);
    final nextRounds = identical(rounds, previous?._rounds)
        ? previous!._rounds
        : Map<String, _ReadingRound>.unmodifiable({
            for (final entry in rounds.entries)
              if (!nextRetired.contains(entry.key) &&
                  !nextEnded.contains(entry.key))
                entry.key: entry.value,
          });
    return ReadingProgress._(
      maximum: nextMaximum,
      catalog: catalog,
      rounds: nextRounds,
      retired: nextRetired,
      ended: nextEnded,
      time: time,
      immutable: true,
    );
  }

  static Set<String> _readIdSet(List values, String field) {
    final result = <String>{};
    for (final value in values) {
      if (value is! String) {
        throw FormatException(
          'Reading progress $field entries must be strings',
        );
      }
      result.add(value);
    }
    return result;
  }

  Map<String, Object?> toJson() {
    final rounds = <String, Object?>{};
    for (final id in _rounds.keys.toList()..sort()) {
      rounds[id] = _rounds[id]!.toJson();
    }
    final maximum = maximumPositions.toList()
      ..sort((a, b) => _positionCanonical(a).compareTo(_positionCanonical(b)));
    final retired = _retired.toList()..sort();
    final ended = _ended.toList()..sort();
    return {
      'version': 1,
      'maximum': maximum.map((position) => position.toJson()).toList(),
      'catalog': catalog?.toJson(),
      'rounds': rounds,
      'retired': retired,
      'ended': ended,
      'time': time,
    };
  }

  bool get hasProgress => maximumPositions.isNotEmpty;

  bool get hasOrderConflict => maximumPositions.length > 1;

  ReadingPosition? get resumePosition {
    if (hasOrderConflict) return null;
    final roundId = activeRoundId;
    if (roundId != null) return _rounds[roundId]!.cursor;
    return maximumPositions.isEmpty ? null : maximumPositions.single;
  }

  Iterable<String> get activeRoundIds => _rounds.keys;

  bool isActiveRound(String id) => _rounds.containsKey(id);

  String? get activeRoundId {
    String? selected;
    for (final id in _rounds.keys) {
      if (selected == null || id.compareTo(selected) < 0) selected = id;
    }
    return selected;
  }

  ReadingProgress merge(ReadingProgress other) {
    final mergedCatalog = _mergeCatalog(catalog, other.catalog);
    final maxima =
        <ReadingPosition>[...maximumPositions, ...other.maximumPositions]
            .map(
              (position) => mergedCatalog == null
                  ? position
                  : _rebaseUniquePosition(mergedCatalog, position) ?? position,
            )
            .toList();

    final retired = <String>{..._retired, ...other._retired};
    final ended = <String>{..._ended, ...other._ended};
    final rounds = <String, _ReadingRound>{};
    final ids = {..._rounds.keys, ...other._rounds.keys}.toList()..sort();
    for (final id in ids) {
      if (retired.contains(id) || ended.contains(id)) continue;
      final left = _rounds[id];
      final right = other._rounds[id];
      if (left == null) {
        rounds[id] = right!;
      } else if (right == null) {
        rounds[id] = left;
      } else {
        if (!_sameLogicalPosition(left.anchor, right.anchor, mergedCatalog)) {
          throw FormatException('Reading round $id has conflicting anchors');
        }
        final anchor = _canonicalPosition(left.anchor, right.anchor);
        final cursor = _joinPosition(left.cursor, right.cursor, mergedCatalog);
        if (_comparePositions(left.cursor, right.cursor, mergedCatalog) ==
            null) {
          maxima
            ..add(
              mergedCatalog == null
                  ? left.cursor
                  : _rebaseUniquePosition(mergedCatalog, left.cursor) ??
                        left.cursor,
            )
            ..add(
              mergedCatalog == null
                  ? right.cursor
                  : _rebaseUniquePosition(mergedCatalog, right.cursor) ??
                        right.cursor,
            );
        }
        rounds[id] = _ReadingRound(
          anchor: mergedCatalog == null
              ? anchor
              : _rebaseUniquePosition(mergedCatalog, anchor) ?? anchor,
          cursor: mergedCatalog == null
              ? cursor
              : _rebaseUniquePosition(mergedCatalog, cursor) ?? cursor,
        );
      }
    }
    return ReadingProgress._create(
      maximum: maxima,
      catalog: mergedCatalog,
      rounds: rounds,
      retired: retired,
      ended: ended,
      time: time > other.time ? time : other.time,
    );
  }

  /// Records one validated source-image position while preserving max history.
  ReadingProgress record(
    ReadingPosition position, {
    required ReadingNavigationSource source,
    String? sessionRoundId,
    String? newRoundId,
    ReadingCatalog? catalog,
    int? time,
    Iterable<String>? observedRoundIds,
  }) {
    if (!position.isValid) return this;
    final base = catalog == null ? this : rebaseCatalog(catalog);
    final resolvedPosition = catalog == null
        ? position
        : _rebaseUniquePosition(catalog, position) ?? position;
    final maxPosition = base.maximumPositions.length == 1
        ? base.maximumPositions.single
        : null;
    final relativeToMax = maxPosition == null
        ? null
        : _comparePositions(resolvedPosition, maxPosition, base.catalog);
    final matchedRound = sessionRoundId == null
        ? null
        : base._rounds[sessionRoundId];
    final relativeToSessionCursor = matchedRound == null
        ? null
        : _comparePositions(
            resolvedPosition,
            matchedRound.cursor,
            base.catalog,
          );
    final startsRound = switch (source) {
      ReadingNavigationSource.userBackward =>
        relativeToMax != null &&
            relativeToMax < 0 &&
            (matchedRound == null ||
                (relativeToSessionCursor != null &&
                    relativeToSessionCursor < 0)),
      ReadingNavigationSource.userSeek =>
        relativeToMax != null &&
            relativeToMax < 0 &&
            (matchedRound == null ||
                (relativeToSessionCursor != null &&
                    relativeToSessionCursor < 0)),
      _ => false,
    };

    var maximum = _updatedMaximum(
      base.maximumPositions,
      resolvedPosition,
      base.catalog,
    );
    Map<String, _ReadingRound> rounds = base._rounds;
    Set<String> retired = base._retired;
    Set<String> ended = base._ended;
    final alreadyNamedRound =
        newRoundId != null && base._rounds.containsKey(newRoundId);
    if (startsRound && !alreadyNamedRound) {
      if (newRoundId == null || newRoundId.isEmpty) {
        throw ArgumentError.value(
          newRoundId,
          'newRoundId',
          'An explicit rewind requires a unique round ID',
        );
      }
      final nextRounds = Map<String, _ReadingRound>.from(base._rounds);
      final nextRetired = Set<String>.from(base._retired);
      for (final id in base._rounds.keys) {
        if (observedRoundIds == null || observedRoundIds.contains(id)) {
          nextRetired.add(id);
          nextRounds.remove(id);
        }
      }
      nextRounds[newRoundId] = _ReadingRound(
        anchor: maxPosition!,
        cursor: resolvedPosition,
      );
      rounds = nextRounds;
      retired = nextRetired;
    } else {
      if (matchedRound != null) {
        final joinedCursor = _joinPosition(
          matchedRound.cursor,
          resolvedPosition,
          base.catalog,
        );
        if (_atOrPast(resolvedPosition, matchedRound.anchor, base.catalog)) {
          final nextRounds = Map<String, _ReadingRound>.from(rounds)
            ..remove(sessionRoundId);
          final nextEnded = Set<String>.from(ended)..add(sessionRoundId!);
          rounds = nextRounds;
          ended = nextEnded;
        } else if (joinedCursor != matchedRound.cursor) {
          rounds = Map<String, _ReadingRound>.from(rounds)
            ..[sessionRoundId!] = _ReadingRound(
              anchor: matchedRound.anchor,
              cursor: joinedCursor,
            );
        }
      }

      if ((source == ReadingNavigationSource.userSeek ||
              source == ReadingNavigationSource.userConfirm) &&
          relativeToMax != null &&
          relativeToMax >= 0) {
        final nextRounds = Map<String, _ReadingRound>.from(rounds);
        final nextEnded = Set<String>.from(ended);
        for (final id in rounds.keys) {
          if (observedRoundIds == null || observedRoundIds.contains(id)) {
            nextRounds.remove(id);
            nextEnded.add(id);
          }
        }
        if (nextRounds.length != rounds.length) {
          rounds = nextRounds;
          ended = nextEnded;
        }
      }
    }

    return ReadingProgress._create(
      maximum: maximum,
      catalog: base.catalog,
      rounds: rounds,
      retired: retired,
      ended: ended,
      time: time != null && time > base.time ? time : base.time,
      previous: base,
      maximumIsPruned: true,
    );
  }

  /// Re-resolves stable chapter IDs against the authoritative loaded source.
  ReadingProgress rebaseCatalog(ReadingCatalog catalog) {
    if (identical(catalog, this.catalog)) return this;
    final maximum = maximumPositions.map(
      (position) => _rebaseUniquePosition(catalog, position) ?? position,
    );
    final rounds = <String, _ReadingRound>{};
    for (final entry in _rounds.entries) {
      rounds[entry.key] = _ReadingRound(
        anchor:
            _rebaseUniquePosition(catalog, entry.value.anchor) ??
            entry.value.anchor,
        cursor:
            _rebaseUniquePosition(catalog, entry.value.cursor) ??
            entry.value.cursor,
      );
    }
    return ReadingProgress._create(
      maximum: maximum,
      catalog: catalog,
      rounds: rounds,
      retired: _retired,
      ended: _ended,
      time: time,
      previous: this,
    );
  }

  /// Maps every original maximum and active-round position into [catalog].
  /// Returns null for ambiguous identities or an already joined ambiguous
  /// reread whose original same-round cursors are no longer available.
  ReadingProgress? normalizeForCatalog(ReadingCatalog catalog) {
    if (hasOrderConflict && _rounds.isNotEmpty) return null;

    ReadingPosition? normalizePosition(ReadingPosition position) {
      var identity = position;
      final sourceCatalog = this.catalog;
      if (sourceCatalog != null) {
        final sourceIndex = sourceCatalog.indexOf(position);
        if (position.chapterId == null) {
          if (sourceIndex == null) return null;
          identity = _positionAt(sourceCatalog, sourceIndex, position.page);
        } else if (sourceIndex != null) {
          identity = _positionAt(sourceCatalog, sourceIndex, position.page);
        }
      }
      return _rebaseUniquePosition(catalog, identity);
    }

    final maximum = <ReadingPosition>[];
    for (final position in maximumPositions) {
      final normalized = normalizePosition(position);
      if (normalized == null) return null;
      maximum.add(normalized);
    }
    final rounds = <String, _ReadingRound>{};
    for (final entry in _rounds.entries) {
      final anchor = normalizePosition(entry.value.anchor);
      final cursor = normalizePosition(entry.value.cursor);
      if (anchor == null || cursor == null) return null;
      rounds[entry.key] = _ReadingRound(anchor: anchor, cursor: cursor);
    }
    return ReadingProgress._create(
      maximum: _pruneMaximum(maximum, catalog),
      maximumIsPruned: true,
      catalog: catalog,
      rounds: rounds,
      retired: _retired,
      ended: _ended,
      time: time,
    );
  }
}

int? _comparePositions(
  ReadingPosition left,
  ReadingPosition right,
  ReadingCatalog? catalog,
) {
  if (catalog != null) {
    final leftIndex = catalog.indexOf(left);
    final rightIndex = catalog.indexOf(right);
    if (leftIndex != null && rightIndex != null) {
      final chapterOrder = leftIndex.compareTo(rightIndex);
      return chapterOrder == 0 ? left.page.compareTo(right.page) : chapterOrder;
    }
  }

  if (left.chapterId != null || right.chapterId != null) {
    if (left.chapterId == null ||
        right.chapterId == null ||
        !_sameChapterIdentity(left, right)) {
      return null;
    }
    return left.page.compareTo(right.page);
  }
  if (left.groupId != null || right.groupId != null) {
    if (left.groupId == null ||
        right.groupId == null ||
        left.groupId != right.groupId) {
      return null;
    }
    final chapterOrder = left.ep.compareTo(right.ep);
    return chapterOrder == 0 ? left.page.compareTo(right.page) : chapterOrder;
  }
  if (left.group == null && right.group == null) {
    final chapterOrder = left.ep.compareTo(right.ep);
    return chapterOrder == 0 ? left.page.compareTo(right.page) : chapterOrder;
  }
  if (left.group == null || right.group == null) return null;
  final groupOrder = left.group!.compareTo(right.group!);
  if (groupOrder != 0) return groupOrder;
  final chapterOrder = left.ep.compareTo(right.ep);
  return chapterOrder == 0 ? left.page.compareTo(right.page) : chapterOrder;
}

bool _sameLogicalPosition(
  ReadingPosition left,
  ReadingPosition right,
  ReadingCatalog? catalog,
) {
  if (left.page != right.page) return false;
  if (catalog != null) {
    final leftIndex = catalog.indexOf(left);
    final rightIndex = catalog.indexOf(right);
    if (leftIndex != null && rightIndex != null) return leftIndex == rightIndex;
  }
  return _sameChapterIdentity(left, right);
}

bool _sameChapterIdentity(ReadingPosition left, ReadingPosition right) {
  if (left.chapterId != null || right.chapterId != null) {
    if (left.chapterId == null ||
        right.chapterId == null ||
        left.chapterId != right.chapterId) {
      return false;
    }
    if (left.groupId != null && right.groupId != null) {
      return left.groupId == right.groupId;
    }
    return true;
  }
  return left.ep == right.ep &&
      left.group == right.group &&
      left.groupId == right.groupId;
}

bool _atOrPast(
  ReadingPosition position,
  ReadingPosition anchor,
  ReadingCatalog? catalog,
) {
  final comparison = _comparePositions(position, anchor, catalog);
  return comparison != null && comparison >= 0;
}

ReadingPosition _joinPosition(
  ReadingPosition left,
  ReadingPosition right,
  ReadingCatalog? catalog,
) {
  final comparison = _comparePositions(left, right, catalog);
  if (comparison != null) {
    if (comparison > 0) return left;
    if (comparison < 0) return right;
  }
  return _canonicalPosition(left, right);
}

ReadingPosition _canonicalPosition(
  ReadingPosition left,
  ReadingPosition right,
) => _positionCanonical(left).compareTo(_positionCanonical(right)) <= 0
    ? left
    : right;

List<ReadingPosition> _updatedMaximum(
  List<ReadingPosition> current,
  ReadingPosition candidate,
  ReadingCatalog? catalog,
) {
  var hasLower = false;
  var hasGreater = false;
  var hasEqual = false;
  for (final existing in current) {
    final order = _comparePositions(candidate, existing, catalog);
    if (order == null) continue;
    if (order < 0) {
      hasLower = true;
    } else if (order > 0) {
      hasGreater = true;
    } else {
      hasEqual = true;
    }
  }
  if (!hasGreater && (hasLower || hasEqual)) return current;
  if (!hasGreater && !hasLower && !hasEqual) {
    return [...current, candidate];
  }
  return _pruneMaximum([...current, candidate], catalog);
}

List<ReadingPosition> _pruneMaximum(
  Iterable<ReadingPosition> input,
  ReadingCatalog? catalog,
) {
  final candidates = <ReadingPosition>[];
  for (final position in input) {
    if (!position.isValid) continue;
    final normalized = catalog == null
        ? position
        : _rebaseUniquePosition(catalog, position) ?? position;
    final matchingIndex = candidates.indexWhere(
      (candidate) => _comparePositions(candidate, normalized, catalog) == 0,
    );
    if (matchingIndex < 0) {
      candidates.add(normalized);
    } else {
      candidates[matchingIndex] = _canonicalPosition(
        candidates[matchingIndex],
        normalized,
      );
    }
  }

  final result = <ReadingPosition>[];
  for (final candidate in candidates) {
    final dominated = candidates.any((other) {
      if (identical(candidate, other)) return false;
      final order = _comparePositions(other, candidate, catalog);
      return order != null && order > 0;
    });
    if (!dominated) result.add(candidate);
  }
  result.sort((a, b) => _positionCanonical(a).compareTo(_positionCanonical(b)));
  return result;
}

ReadingCatalog? _mergeCatalog(ReadingCatalog? left, ReadingCatalog? right) {
  if (left == null) return right;
  if (right == null) return left;
  final leftKeys = left.chapters.map(_chapterKey).toList();
  final rightKeys = right.chapters.map(_chapterKey).toList();
  if (_isSubsequence(leftKeys, rightKeys)) {
    if (leftKeys.length < rightKeys.length) return right;
    return _canonicalCatalog(left, right);
  }
  if (_isSubsequence(rightKeys, leftKeys)) return left;
  return null;
}

String _chapterKey(ReadingChapter chapter) => jsonEncode([
  chapter.groupId ?? chapter.group?.toString() ?? '',
  chapter.id,
]);

bool _isSubsequence(List<String> smaller, List<String> larger) {
  if (smaller.length > larger.length) return false;
  var smallerIndex = 0;
  for (final key in larger) {
    if (smallerIndex < smaller.length && smaller[smallerIndex] == key) {
      smallerIndex++;
    }
  }
  return smallerIndex == smaller.length;
}

ReadingCatalog _canonicalCatalog(ReadingCatalog left, ReadingCatalog right) =>
    _catalogCanonical(left).compareTo(_catalogCanonical(right)) <= 0
    ? left
    : right;

String _catalogCanonical(ReadingCatalog catalog) =>
    jsonEncode(catalog.toJson());

String _positionCanonical(ReadingPosition position) =>
    jsonEncode(position.toJson());
