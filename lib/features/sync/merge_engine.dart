import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../../foundation/sync_candidate_preview.dart';
import '../../foundation/sync_records.dart';

/// An allocation identity, not a vector-clock proof that earlier edits were seen.
class MergeDot {
  final String actor;
  final int counter;
  const MergeDot(this.actor, this.counter);
  String toKey() => '$actor:$counter';
  List<Object?> toJson() => [actor, counter];
  static MergeDot parse(String key) {
    final split = key.lastIndexOf(':');
    if (split <= 0) throw const FormatException('Invalid merge dot');
    final counter = int.tryParse(key.substring(split + 1));
    if (counter == null || counter <= 0) {
      throw const FormatException('Invalid merge counter');
    }
    final dot = MergeDot(key.substring(0, split), counter);
    if (dot.toKey() != key) throw const FormatException('Noncanonical dot');
    return dot;
  }

  factory MergeDot.fromJson(Object? value) {
    if (value is String) return MergeDot.parse(value);
    if (value is! List ||
        value.length != 2 ||
        value[0] is! String ||
        value[1] is! int)
      throw const FormatException('Invalid merge dot');
    return MergeDot.parse('${value[0]}:${value[1]}');
  }
  @override
  bool operator ==(Object other) =>
      other is MergeDot && actor == other.actor && counter == other.counter;
  @override
  int get hashCode => Object.hash(actor, counter);
  @override
  String toString() => toKey();
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(canonicalSyncJson(value))).toString();

Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected a JSON object');
  }
  return value.cast<String, Object?>();
}

void _keys(Map<String, Object?> value, Set<String> required) {
  if (value.length != required.length ||
      !value.keys.toSet().containsAll(required)) {
    throw const FormatException('Invalid merge schema keys');
  }
}

void _jsonValue(Object? value) {
  if (value == null || value is String || value is bool || value is int) return;
  if (value is double && value.isFinite) return;
  if (value is List) {
    for (final item in value) {
      _jsonValue(item);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) throw const FormatException('Invalid JSON key');
      _jsonValue(entry.value);
    }
    return;
  }
  throw const FormatException('Invalid JSON value');
}

Map<String, int> _counters(Object? value) {
  final result = <String, int>{};
  for (final entry in _map(value).entries) {
    if (entry.key.isEmpty || entry.value is! int || (entry.value as int) < 0) {
      throw const FormatException('Invalid actor counter');
    }
    result[entry.key] = entry.value as int;
  }
  return result;
}

Map<String, String> _digests(Object? value) {
  final result = <String, String>{};
  for (final entry in _map(value).entries) {
    MergeDot.parse(entry.key);
    if (entry.value is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value as String)) {
      throw const FormatException('Invalid event fingerprint');
    }
    result[entry.key] = entry.value as String;
  }
  return result;
}

/// Exact observed-dot MVR. Retired payloads are discarded, but their fingerprints
/// remain: allocation gaps cannot retire an unseen cell, and even a retired dot
/// cannot be reused with another payload. No actor-counter prefix is inferred.
class _Cell {
  final Map<String, String> seen;
  final Map<String, Set<String>> retired;
  final Map<String, Object?> values;
  _Cell() : seen = {}, retired = {}, values = {};
  _Cell._(this.seen, this.retired, this.values);
  _Cell clone() => _Cell._(Map.of(seen), {
    for (final entry in retired.entries) entry.key: Set.of(entry.value),
  }, Map.of(values));

  void retire(Iterable<String> ids, String by) {
    for (final id in ids.toList()) {
      if (id == by) throw const FormatException('Self-retiring cell dot');
      retired.putIfAbsent(id, () => <String>{}).add(by);
      values.remove(id);
    }
  }

  void write(String dot, Object? value, {bool contribution = false}) {
    final copy = canonicalizeSyncValue(value);
    final hash = _digest(copy);
    if (seen.containsKey(dot) && seen[dot] != hash) {
      throw const FormatException('Reused cell dot with another payload');
    }
    final actor = MergeDot.parse(dot).actor;
    retire(
      values.keys.where(
        (id) => !contribution || MergeDot.parse(id).actor == actor,
      ),
      dot,
    );
    seen[dot] = hash;
    values[dot] = copy;
  }

  void validateIdentity(_Cell other) {
    for (final entry in other.seen.entries) {
      if (seen.containsKey(entry.key) && seen[entry.key] != entry.value) {
        throw const FormatException(
          'Conflicting payload for identical cell dot',
        );
      }
    }
  }

  void merge(_Cell other) {
    validateIdentity(other);
    seen.addAll(other.seen);
    values.addAll(other.values);
    for (final entry in other.retired.entries) {
      retired.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
    }
    values.removeWhere((id, _) => retired.containsKey(id));
  }

  bool covers(_Cell other) =>
      other.seen.entries.every((entry) => seen[entry.key] == entry.value) &&
      other.retired.entries.every(
        (entry) => retired[entry.key]?.containsAll(entry.value) ?? false,
      );
  Map<String, Object?> toJson() => {
    'seen': Map<String, String>.of(seen),
    'retired': {
      for (final entry in retired.entries)
        entry.key: entry.value.toList()..sort(),
    },
    'values': canonicalizeSyncValue(values),
  };
  factory _Cell.fromJson(Object? value) {
    final map = _map(value);
    _keys(map, {'seen', 'retired', 'values'});
    final seen = _digests(map['seen']);
    final values = _map(map['values']);
    final retired = <String, Set<String>>{};
    for (final entry in _map(map['retired']).entries) {
      if (!seen.containsKey(entry.key) ||
          entry.value is! List ||
          (entry.value as List).isEmpty) {
        throw const FormatException('Invalid retirement context');
      }
      final witnesses = <String>{};
      for (final witness in entry.value as List) {
        if (witness is! String ||
            witness == entry.key ||
            !seen.containsKey(witness) ||
            !witnesses.add(witness)) {
          throw const FormatException('Invalid retirement witness');
        }
      }
      retired[entry.key] = witnesses;
    }
    for (final entry in values.entries) {
      _jsonValue(entry.value);
      if (retired.containsKey(entry.key) ||
          seen[entry.key] != _digest(entry.value)) {
        throw const FormatException('Candidate fingerprint mismatch');
      }
    }
    if (values.length + retired.length != seen.length) {
      throw const FormatException(
        'Observed dot lacks candidate or retirement proof',
      );
    }
    // Topological validation without recursion: every retirement chain must end
    // at an active dot, not a fabricated cyclic deletion context.
    final remaining = <String, int>{
      for (final id in seen.keys) id: retired[id]?.length ?? 0,
    };
    final parents = <String, List<String>>{};
    for (final entry in retired.entries) {
      for (final witness in entry.value) {
        parents.putIfAbsent(witness, () => <String>[]).add(entry.key);
      }
    }
    final queue = values.keys.toList();
    for (var i = 0; i < queue.length; i++) {
      for (final parent in parents[queue[i]] ?? <String>[]) {
        remaining[parent] = remaining[parent]! - 1;
        if (remaining[parent] == 0) queue.add(parent);
      }
    }
    if (queue.length != seen.length) {
      throw const FormatException('Cyclic retirement context');
    }
    return _Cell._(seen, retired, {
      for (final entry in values.entries)
        entry.key: canonicalizeSyncValue(entry.value),
    });
  }
}

class _Record {
  final _Cell presence;
  final Map<String, _Cell> fields;
  final _Cell bases;
  final _Cell contributions;
  _Record()
    : presence = _Cell(),
      fields = {},
      bases = _Cell(),
      contributions = _Cell();
  _Record._(this.presence, this.fields, this.bases, this.contributions);
  bool get alive => presence.values.values.any((value) => value == true);
  _Record clone() => _Record._(
    presence.clone(),
    {for (final entry in fields.entries) entry.key: entry.value.clone()},
    bases.clone(),
    contributions.clone(),
  );

  Map<String, int> get prefixes {
    final result = <String, int>{};
    for (final entry in contributions.values.entries) {
      result[MergeDot.parse(entry.key).actor] = entry.value as int;
    }
    return result;
  }

  int totalFor(Object? base) {
    final map = base == null ? null : _map(base);
    var total = map == null ? 0 : map['value'] as int;
    final absorbed = map == null ? <String, int>{} : _counters(map['absorbed']);
    for (final entry in prefixes.entries) {
      total += max(0, entry.value - (absorbed[entry.key] ?? 0));
    }
    return total;
  }

  MapEntry<String, Object?>? get defaultBase {
    final regular = bases.values.entries
        .where((entry) => _map(entry.value)['kind'] != 'reset')
        .toList();
    if (regular.isEmpty) return null;
    regular.sort((a, b) {
      final cmp = totalFor(b.value).compareTo(totalFor(a.value));
      return cmp != 0 ? cmp : a.key.compareTo(b.key);
    });
    return regular.first;
  }

  int get total => totalFor(defaultBase?.value);
  bool get durationConflict {
    if (bases.values.values.any((value) => _map(value)['kind'] == 'reset'))
      return true;
    return bases.values.values.map(totalFor).toSet().length > 1;
  }

  void _validateContributions(_Record other) {
    // An actor's contribution is lifetime cumulative, including absorbed prefixes.
    // A newer dot may not reduce it, even across resets or reincarnations.
    if (contributions.values.isEmpty || other.contributions.values.isEmpty) {
      return;
    }
    final incomingByActor = <String, (MergeDot, int)>{};
    for (final entry in other.contributions.values.entries) {
      final dot = MergeDot.parse(entry.key);
      incomingByActor[dot.actor] = (dot, entry.value as int);
    }
    for (final entry in contributions.values.entries) {
      final mine = MergeDot.parse(entry.key);
      final incoming = incomingByActor[mine.actor];
      if (incoming == null) continue;
      final value = entry.value as int;
      if ((mine.counter < incoming.$1.counter && value > incoming.$2) ||
          (mine.counter > incoming.$1.counter && value < incoming.$2)) {
        throw const FormatException('Nonmonotonic duration contribution');
      }
    }
  }

  void validateIdentity(_Record other) {
    _validateContributions(other);
    presence.validateIdentity(other.presence);
    bases.validateIdentity(other.bases);
    contributions.validateIdentity(other.contributions);
    for (final entry in other.fields.entries) {
      fields[entry.key]?.validateIdentity(entry.value);
    }
  }

  void merge(_Record other) {
    _validateContributions(other);
    presence.merge(other.presence);
    for (final entry in other.fields.entries) {
      fields.putIfAbsent(entry.key, _Cell.new).merge(entry.value);
    }
    bases.merge(other.bases);
    contributions.merge(other.contributions);
    final latest = <String, String>{};
    for (final id in contributions.values.keys) {
      final dot = MergeDot.parse(id);
      final prior = latest[dot.actor];
      if (prior == null || MergeDot.parse(prior).counter < dot.counter) {
        latest[dot.actor] = id;
      }
    }
    for (final id in contributions.values.keys.toList()) {
      final winner = latest[MergeDot.parse(id).actor]!;
      if (winner != id) contributions.retire([id], winner);
    }
  }

  bool covers(_Record other) =>
      presence.covers(other.presence) &&
      bases.covers(other.bases) &&
      contributions.covers(other.contributions) &&
      other.fields.entries.every(
        (entry) => fields[entry.key]?.covers(entry.value) ?? false,
      );
  Iterable<_Cell> get cells sync* {
    yield presence;
    yield* fields.values;
    yield bases;
    yield contributions;
  }

  Map<String, Object?> toJson() => {
    'presence': presence.toJson(),
    'fields': {
      for (final entry in fields.entries) entry.key: entry.value.toJson(),
    },
    'bases': bases.toJson(),
    'contributions': contributions.toJson(),
  };
  factory _Record.fromJson(Object? value) {
    final map = _map(value);
    _keys(map, {'presence', 'fields', 'bases', 'contributions'});
    final record = _Record._(
      _Cell.fromJson(map['presence']),
      {
        for (final entry in _map(map['fields']).entries)
          entry.key: _Cell.fromJson(entry.value),
      },
      _Cell.fromJson(map['bases']),
      _Cell.fromJson(map['contributions']),
    );
    if (record.presence.values.values.any((value) => value is! bool)) {
      throw const FormatException('Invalid presence candidate');
    }
    for (final field in record.fields.values) {
      for (final candidate in field.values.values) {
        final payload = _map(candidate);
        _keys(payload, {'value', 'deleted'});
        if (payload['deleted'] is! bool ||
            (payload['deleted'] == true && payload['value'] != null)) {
          throw const FormatException('Invalid field candidate');
        }
      }
    }
    for (final base in record.bases.values.values) {
      final payload = _map(base);
      _keys(payload, {'value', 'absorbed', 'kind'});
      if (payload['value'] is! int ||
          (payload['value'] as int) < 0 ||
          !{
            'legacy',
            'reset',
            'resolution',
            'incarnation',
          }.contains(payload['kind'])) {
        throw const FormatException('Invalid duration baseline');
      }
      _counters(payload['absorbed']);
    }
    final actors = <String>{};
    for (final contribution in record.contributions.values.entries) {
      if (contribution.value is! int ||
          (contribution.value as int) < 0 ||
          !actors.add(MergeDot.parse(contribution.key).actor)) {
        throw const FormatException('Invalid cumulative duration candidate');
      }
    }
    return record;
  }
}

class MergeCandidate {
  final String id;
  final Object? value;
  final String actor;
  final int counter;
  final bool isDeleted;
  final String recordKey;
  final String field;
  MergeCandidate({
    required this.id,
    required this.value,
    required this.actor,
    required this.counter,
    required this.isDeleted,
    required this.recordKey,
    required this.field,
  });

  /// Only safe summaries, never session/script or compound-setting contents.
  String get safeLabel {
    if (field == 'presence') return isDeleted ? 'Delete record' : 'Keep record';
    if (isDeleted) return '[Deleted]';
    String domain;
    try {
      domain = syncRecordDomain(recordKey);
    } catch (_) {
      domain = '';
    }
    if (domain == 'cookies') return 'Cookies session data';
    if (domain == 'source' || domain == 'sourceSession') {
      return 'Comic source session/script data';
    }
    if (domain == 'setting') {
      if (syncCandidatePreviewIsProtected(
        domain: domain,
        field: field,
        recordKey: recordKey,
      )) {
        return '***protected setting value***';
      }
      if (value is List)
        return 'Setting list (${(value as List).length} items)';
      if (value is Map)
        return 'Setting object (${(value as Map).length} fields)';
    }
    if (domain.isEmpty && (value is Map || value is List))
      return 'Structured value';
    final text = canonicalSyncJson(value);
    return text.length > 80 ? '${text.substring(0, 77)}...' : text;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'value': canonicalizeSyncValue(value),
    'actor': actor,
    'counter': counter,
    'isDeleted': isDeleted,
    'recordKey': recordKey,
    'field': field,
  };
  factory MergeCandidate.fromJson(Map<String, Object?> json) => MergeCandidate(
    id: json['id'] as String,
    value: json['value'],
    actor: json['actor'] as String,
    counter: json['counter'] as int,
    isDeleted: json['isDeleted'] as bool,
    recordKey: json['recordKey'] as String,
    field: json['field'] as String,
  );
  @override
  String toString() =>
      'MergeCandidate(id: $id, actor: $actor, counter: $counter, value: $safeLabel)';
}

class MergeConflict {
  final String recordKey;
  final String field;
  final List<MergeCandidate> candidates;

  /// Duration candidate values can change as new contributions arrive, even
  /// when the candidate IDs remain stable.
  late final String candidateFingerprint = field == 'readDurationMs'
      ? _digest(candidates.map((candidate) => candidate.toJson()).toList())
      : '';
  MergeConflict({
    required this.recordKey,
    required this.field,
    required this.candidates,
  });
  Map<String, Object?> toJson() => {
    'recordKey': recordKey,
    'field': field,
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
  };
  factory MergeConflict.fromJson(Map<String, Object?> json) => MergeConflict(
    recordKey: json['recordKey'] as String,
    field: json['field'] as String,
    candidates: (json['candidates'] as List)
        .map((value) => MergeCandidate.fromJson(_map(value)))
        .toList(),
  );
  @override
  String toString() =>
      'MergeConflict(recordKey: $recordKey, field: $field, candidates: ${candidates.map((candidate) => candidate.safeLabel).join(', ')})';
}

/// One selected candidate for a currently active merge conflict.
class MergeConflictResolution {
  final String recordKey;
  final String field;
  final String candidateId;

  /// Optional candidate-set snapshot used to reject newly arrived variants.
  final Set<String>? expectedCandidateIds;

  /// Optional value snapshot for synthetic candidates whose IDs are stable.
  final String? expectedCandidateFingerprint;

  const MergeConflictResolution({
    required this.recordKey,
    required this.field,
    required this.candidateId,
    this.expectedCandidateIds,
    this.expectedCandidateFingerprint,
  });
}

/// Lossless per-cell exact-dot merge. Counter floors allocate identities only.
/// Each register retains observed identities and fingerprints, not retired data.
/// Duration = chosen atomic baseline + sum(lifetime contributions - absorbed
/// prefixes). Reset proposals remain candidates until an explicit resolution.
class MergeDocument {
  final Map<String, int> _vclock = {};
  final Map<String, String> _eventDigests = {};
  final Map<String, _Record> _records = {};
  MergeDocument();
  int counterFor(String actor) => _vclock[actor] ?? 0;
  int reserveCounter(String actor) {
    if (actor.isEmpty) throw ArgumentError.value(actor, 'actor');
    final counter = counterFor(actor) + 1;
    _vclock[actor] = counter;
    return counter;
  }

  void setCounterFloor(String actor, int floor) {
    if (actor.isEmpty || floor < 0)
      throw ArgumentError('Invalid counter floor');
    _vclock[actor] = max(counterFor(actor), floor);
  }

  Map<String, int> get vclock => Map.unmodifiable(_vclock);

  /// Dot IDs that are currently active in any record cell.
  Set<String> get activeCandidateIds => Set.unmodifiable(<String>{
    for (final record in _records.values)
      for (final cell in record.cells) ...cell.values.keys,
  });

  bool hasActiveCandidate(String recordKey, String field, String candidateId) {
    final record = _records[recordKey];
    if (record == null) return false;
    if (field == 'presence') {
      return record.presence.values.containsKey(candidateId);
    }
    if (field == 'readDurationMs') {
      return record.bases.values.containsKey(candidateId) ||
          record.contributions.values.containsKey(candidateId);
    }
    return record.fields[field]?.values.containsKey(candidateId) ?? false;
  }

  /// Compares one active history progress/presence candidate without
  /// materializing the document or walking unrelated records.
  bool hasActiveHistoryCandidateValue(
    String recordKey,
    String field,
    String candidateId, {
    required Object? value,
    required bool present,
  }) {
    final record = _records[recordKey];
    if (record == null || _domain(recordKey) != 'history') return false;
    if (field == 'presence') {
      final candidates = record.presence.values;
      return candidates.containsKey(candidateId) &&
          candidates[candidateId] == present;
    }
    if (field != 'progress') return false;
    final raw = record.fields['progress']?.values[candidateId];
    if (raw == null) return false;
    final payload = raw as Map;
    return payload['deleted'] == !present &&
        (!present || syncValuesEqual(payload['value'], value));
  }

  bool hasActiveDurationContribution(String recordKey, String candidateId) =>
      _records[recordKey]?.contributions.values.containsKey(candidateId) ??
      false;

  Iterable<String> get recordKeys => _records.keys;

  bool dominates(MergeDocument other) =>
      other._vclock.entries.every(
        (entry) => counterFor(entry.key) >= entry.value,
      ) &&
      other._eventDigests.entries.every(
        (entry) => _eventDigests[entry.key] == entry.value,
      ) &&
      other._records.entries.every(
        (entry) => _records[entry.key]?.covers(entry.value) ?? false,
      );
  bool covers(MergeDocument other) => dominates(other);

  /// Publication allocation bound only; use [dominates] to prove content coverage.
  bool coversActor(String actor, int counter) => counterFor(actor) >= counter;

  /// Checks exact cell seen fingerprint of normal {'deleted':false,'value':value}
  /// payload (active or retired), not actor counters.
  bool hasObservedFieldValue(String recordKey, String field, Object? value) {
    final record = _records[recordKey];
    if (record == null) return false;
    final cell = record.fields[field];
    if (cell == null) return false;
    final expectedDigest = _digest({'deleted': false, 'value': value});
    return cell.seen.values.contains(expectedDigest);
  }

  /// Content-addressed immutable variant seed document with actor
  /// `source_variant_<SHA256(canonicalSyncJson([recordKey,script]))>` and counter 1.
  static MergeDocument createSourceVariantSeed(
    String recordKey,
    Map<String, Object?> script,
  ) {
    final hash = sha256
        .convert(utf8.encode(canonicalSyncJson([recordKey, script])))
        .toString();
    final actor = 'source_variant_$hash';
    final seedDoc = MergeDocument();
    seedDoc.captureLocal(actor, {}, {
      recordKey: {'script': script},
    });
    return seedDoc;
  }

  String _domain(String key) {
    try {
      return syncRecordDomain(key);
    } catch (_) {
      return '';
    }
  }

  void _write(
    _Cell cell,
    String dot,
    Object? value,
    Map<String, Object?> edits,
    String cellKey, {
    bool contribution = false,
    bool proposalsOnly = false,
  }) {
    final context = cell.seen.keys.toList()..sort();
    edits[cellKey] = {'value': value, 'observed': context};
    if (proposalsOnly) {
      // A rewind is a proposal alongside the accumulated total, not an implicit
      // choice against it. It only supersedes earlier observed rewind proposals.
      final hash = _digest(value);
      cell.retire(
        cell.values.entries
            .where((entry) => _map(entry.value)['kind'] == 'reset')
            .map((entry) => entry.key),
        dot,
      );
      cell.seen[dot] = hash;
      cell.values[dot] = canonicalizeSyncValue(value);
    } else {
      cell.write(dot, value, contribution: contribution);
    }
  }

  int captureLocal(
    String actor,
    SyncRecords previous,
    SyncRecords current, {
    bool bootstrap = false,
    MergeDocument? contributionFloor,
  }) {
    final changed = <String>[];
    for (final key in <String>{...previous.keys, ...current.keys}) {
      if (previous.containsKey(key) != current.containsKey(key) ||
          !syncValuesEqual(previous[key], current[key]))
        changed.add(key);
    }
    if (changed.isEmpty) return 0;
    for (final key in changed) {
      _jsonValue(current[key]);
      if (_domain(key) == 'history') {
        _duration(previous[key]?['readDurationMs']);
        _duration(current[key]?['readDurationMs']);
      }
    }
    final counter = reserveCounter(actor);
    final dot = MergeDot(actor, counter).toKey();
    final event = <String, Object?>{};
    for (final key in changed) {
      final record = _records.putIfAbsent(key, _Record.new);
      final before = previous[key];
      final after = current[key];
      final edits = <String, Object?>{};
      event[key] = edits;
      final reincarnation =
          after != null &&
          before == null &&
          record.presence.values.isNotEmpty &&
          !record.alive;
      _write(record.presence, dot, after != null, edits, 'presence');
      if (after == null) continue;
      final fieldKeys = <String>{
        ...?before?.keys,
        ...after.keys,
        if (reincarnation) ...record.fields.keys,
        if (reincarnation && _domain(key) == 'history') 'readDurationMs',
      };
      for (final field in fieldKeys) {
        final had = before?.containsKey(field) ?? false;
        final has = after.containsKey(field);
        if (!reincarnation &&
            had == has &&
            syncValuesEqual(before?[field], after[field]))
          continue;
        if (_domain(key) == 'history' && field == 'readDurationMs') {
          final old = _duration(before?[field]);
          final next = _duration(after[field]);
          final prefixes = record.prefixes;
          if (reincarnation) {
            _write(
              record.bases,
              dot,
              {'value': 0, 'absorbed': prefixes, 'kind': 'incarnation'},
              edits,
              'base',
            );
          }
          if (!reincarnation &&
              before == null &&
              (bootstrap || actor.startsWith('legacy_'))) {
            _write(
              record.bases,
              dot,
              {'value': next, 'absorbed': prefixes, 'kind': 'legacy'},
              edits,
              'base',
            );
          } else if (next > old || (reincarnation && next > 0)) {
            final delta = reincarnation ? next : next - old;
            final floor =
                contributionFloor?._records[key]?.prefixes[actor] ?? 0;
            _write(
              record.contributions,
              dot,
              max(prefixes[actor] ?? 0, floor) + delta,
              edits,
              'contribution',
              contribution: true,
            );
          } else if (next < old) {
            final absorbed =
                record.bases.seen.isEmpty &&
                    record.contributions.seen.isEmpty &&
                    contributionFloor != null
                ? contributionFloor._records[key]?.prefixes ?? prefixes
                : prefixes;
            _write(
              record.bases,
              dot,
              {'value': next, 'absorbed': absorbed, 'kind': 'reset'},
              edits,
              'base',
              proposalsOnly: true,
            );
          }
        } else {
          _write(
            record.fields.putIfAbsent(field, _Cell.new),
            dot,
            {'value': has ? after[field] : null, 'deleted': !has},
            edits,
            'field:$field',
          );
        }
      }
    }
    _eventDigests[dot] = _digest(event);
    return counter;
  }

  int _duration(Object? value) {
    if (value == null) return 0;
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.toInt()) {
      throw const FormatException('Invalid reading duration');
    }
    return value.toInt();
  }

  void _validateEventDigests(MergeDocument other) {
    for (final entry in other._eventDigests.entries) {
      if (_eventDigests.containsKey(entry.key) &&
          _eventDigests[entry.key] != entry.value) {
        throw const FormatException(
          'Conflicting payload for identical event dot',
        );
      }
    }
  }

  /// Validates shared event/cell identities and cumulative durations without
  /// copying or merging either document. Incomparable causal branches are valid.
  void validateEventIdentities(MergeDocument other) {
    _validateEventDigests(other);
    for (final entry in other._records.entries) {
      _records[entry.key]?.validateIdentity(entry.value);
    }
  }

  void merge(MergeDocument other) {
    _validateEventDigests(other);
    // Construct before committing so corruption cannot partially mutate a document.
    final merged = <String, _Record>{};
    for (final key in <String>{..._records.keys, ...other._records.keys}) {
      final mine = _records[key];
      final incoming = other._records[key];
      final record = mine?.clone() ?? incoming!.clone();
      if (mine != null && incoming != null) record.merge(incoming);
      merged[key] = record;
    }
    _records
      ..clear()
      ..addAll(merged);
    _eventDigests.addAll(other._eventDigests);
    for (final entry in other._vclock.entries)
      setCounterFloor(entry.key, entry.value);
  }

  MapEntry<String, Object?> _choose(
    _Cell cell,
    Map<String, Object?>? preferred,
    String field,
  ) {
    final values = cell.values.entries.toList();
    if (preferred != null) {
      final present = preferred.containsKey(field);
      for (final entry in values) {
        final payload = _map(entry.value);
        if ((payload['deleted'] == true && !present) ||
            (payload['deleted'] == false &&
                present &&
                syncValuesEqual(payload['value'], preferred[field])))
          return entry;
      }
    }
    // Add/edit wins when there is no matching preferred membership.
    values.sort((a, b) {
      final pa = _map(a.value);
      final pb = _map(b.value);
      if (pa['deleted'] != pb['deleted']) return pa['deleted'] == true ? 1 : -1;
      final da = MergeDot.parse(a.key);
      final db = MergeDot.parse(b.key);
      final counter = db.counter.compareTo(da.counter);
      return counter != 0 ? counter : db.actor.compareTo(da.actor);
    });
    return values.first;
  }

  int _compareProgressCandidates(String leftId, String rightId) {
    final left = MergeDot.parse(leftId);
    final right = MergeDot.parse(rightId);
    final counter = left.counter.compareTo(right.counter);
    return counter != 0 ? counter : left.actor.compareTo(right.actor);
  }

  bool _isProgressInteger(Object? value) =>
      value is num && value.isFinite && value == value.toInt();

  bool _sameProgressPosition(
    Map<String, Object?> left,
    Map<String, Object?> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (entry.key == 'time') continue;
      if (!right.containsKey(entry.key) ||
          !syncValuesEqual(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }

  MapEntry<String, Object?>? _compatibleProgressWinner(_Cell cell) {
    if (cell.values.length < 2) return null;
    Map<String, Object?>? position;
    MapEntry<String, Object?>? winner;
    var winnerTime = -1;
    for (final entry in cell.values.entries) {
      final payload = _map(entry.value);
      if (payload['deleted'] != false) return null;
      final rawProgress = payload['value'];
      if (rawProgress is! Map) return null;
      final progress = _map(rawProgress);
      if (!progress.containsKey('ep') ||
          !progress.containsKey('page') ||
          !progress.containsKey('group') ||
          !progress.containsKey('time')) {
        return null;
      }
      if (!_isProgressInteger(progress['ep']) ||
          !_isProgressInteger(progress['page']) ||
          (progress['group'] != null &&
              !_isProgressInteger(progress['group'])) ||
          !_isProgressInteger(progress['time'])) {
        return null;
      }
      final rawTime = progress['time'] as num;
      if (rawTime < 0 || rawTime > 8640000000000000) return null;
      if (position == null) {
        position = progress;
      } else if (!_sameProgressPosition(position, progress)) {
        return null;
      }
      final time = rawTime.toInt();
      if (winner == null ||
          time > winnerTime ||
          (time == winnerTime &&
              _compareProgressCandidates(entry.key, winner.key) > 0)) {
        winner = entry;
        winnerTime = time;
      }
    }
    return winner;
  }

  SyncRecords materialize({SyncRecords? preferred}) {
    final result = <String, Map<String, Object?>>{};
    for (final entry in _records.entries) {
      final record = entry.value;
      if (!record.alive) continue;
      final fields = <String, Object?>{};
      for (final field in record.fields.entries) {
        if (field.value.values.isEmpty) continue;
        final automaticProgress =
            _domain(entry.key) == 'history' && field.key == 'progress'
            ? _compatibleProgressWinner(field.value)
            : null;
        final payload = _map(
          (automaticProgress ??
                  _choose(field.value, preferred?[entry.key], field.key))
              .value,
        );
        if (payload['deleted'] == false)
          fields[field.key] = canonicalizeSyncValue(payload['value']);
      }
      if (_domain(entry.key) == 'history') {
        var duration = record.total;
        final local = preferred?[entry.key]?['readDurationMs'];
        if (local is num && record.durationConflict) {
          for (final base in record.bases.values.values) {
            if (record.totalFor(base) == local) {
              duration = local.toInt();
              break;
            }
          }
        }
        fields['readDurationMs'] = duration;
      }
      result[entry.key] = fields;
    }
    return result;
  }

  MergeCandidate _candidate(
    String recordKey,
    String field,
    String id,
    Object? value, {
    bool deleted = false,
  }) {
    final dot = MergeDot.parse(id);
    return MergeCandidate(
      id: id,
      value: canonicalizeSyncValue(value),
      actor: dot.actor,
      counter: dot.counter,
      isDeleted: deleted,
      recordKey: recordKey,
      field: field,
    );
  }

  List<MergeConflict> get conflicts {
    final result = <MergeConflict>[];
    final keys = _records.keys.toList()..sort();
    for (final key in keys) {
      final record = _records[key]!;
      if (!record.alive) continue;
      final fields = record.fields.keys.toList()..sort();
      for (final field in fields) {
        final cell = record.fields[field]!;
        if (cell.values.values.map(canonicalSyncJson).toSet().length <= 1)
          continue;
        if (field == 'progress' &&
            _domain(key) == 'history' &&
            _compatibleProgressWinner(cell) != null) {
          continue;
        }
        final ids = cell.values.keys.toList()..sort();
        result.add(
          MergeConflict(
            recordKey: key,
            field: field,
            candidates: [
              for (final id in ids)
                _candidate(
                  key,
                  field,
                  id,
                  _map(cell.values[id])['value'],
                  deleted: _map(cell.values[id])['deleted'] as bool,
                ),
            ],
          ),
        );
      }
      if (record.presence.values.values.toSet().length > 1) {
        final ids = record.presence.values.keys.toList()..sort();
        result.add(
          MergeConflict(
            recordKey: key,
            field: 'presence',
            candidates: [
              for (final id in ids)
                _candidate(
                  key,
                  'presence',
                  id,
                  record.presence.values[id] == true ? 'present' : 'deleted',
                  deleted: record.presence.values[id] == false,
                ),
            ],
          ),
        );
      }
      if (record.durationConflict) {
        final ids = record.bases.values.keys.toList()..sort();
        result.add(
          MergeConflict(
            recordKey: key,
            field: 'readDurationMs',
            candidates: [
              MergeCandidate(
                id: 'accumulated_total',
                value: record.total,
                actor: 'engine',
                counter: 0,
                isDeleted: false,
                recordKey: key,
                field: 'readDurationMs',
              ),
              for (final id in ids)
                _candidate(
                  key,
                  'readDurationMs',
                  id,
                  record.totalFor(record.bases.values[id]),
                ),
            ],
          ),
        );
      }
    }
    return result;
  }

  void resolve(
    String actor,
    String recordKey,
    String field,
    String candidateId,
  ) {
    final record = _records[recordKey];
    if (record == null || !record.alive)
      throw StateError('Record is not alive');
    Object? chosen;
    if (field == 'presence') {
      if (!record.presence.values.containsKey(candidateId))
        throw StateError('Unknown candidate');
      chosen = record.presence.values[candidateId];
    } else if (field == 'readDurationMs') {
      if (candidateId != 'accumulated_total' &&
          !record.bases.values.containsKey(candidateId)) {
        throw StateError('Unknown duration candidate');
      }
      chosen = candidateId == 'accumulated_total'
          ? record.total
          : record.totalFor(record.bases.values[candidateId]);
    } else {
      final cell = record.fields[field];
      if (cell == null || !cell.values.containsKey(candidateId))
        throw StateError('Unknown candidate');
      chosen = cell.values[candidateId];
      if (_domain(recordKey) == 'source' && field == 'script') {
        final seenScripts = <String, Map<String, Object?>>{};
        for (final entry in cell.values.entries) {
          final digest = cell.seen[entry.key]!;
          if (seenScripts.containsKey(digest)) continue;
          final payload = _map(entry.value);
          if (payload['deleted'] != true && payload['value'] is Map) {
            seenScripts[digest] = (payload['value'] as Map)
                .cast<String, Object?>();
          }
        }
        for (final script in seenScripts.values) {
          final seed = createSourceVariantSeed(recordKey, script);
          if (!dominates(seed)) {
            merge(seed);
          }
        }
      }
    }
    final currentRecord = _records[recordKey]!;
    final dot = MergeDot(actor, reserveCounter(actor)).toKey();
    final edits = <String, Object?>{};
    _write(
      currentRecord.presence,
      dot,
      field == 'presence' ? chosen : true,
      edits,
      'presence',
    );
    if (field == 'readDurationMs') {
      _write(
        currentRecord.bases,
        dot,
        {
          'value': chosen,
          'absorbed': currentRecord.prefixes,
          'kind': 'resolution',
        },
        edits,
        'base',
      );
    } else if (field != 'presence') {
      _write(currentRecord.fields[field]!, dot, chosen, edits, 'field:$field');
    }
    _eventDigests[dot] = _digest({recordKey: edits});
  }

  MergeDocument clone() {
    final copy = MergeDocument();
    copy._vclock.addAll(_vclock);
    copy._eventDigests.addAll(_eventDigests);
    for (final entry in _records.entries)
      copy._records[entry.key] = entry.value.clone();
    return copy;
  }

  /// Projects only records actually accepted by an application's apply policy.
  /// Tombstones and all cell observations survive for accepted records; business
  /// materialization is deliberately not used as an observation-key whitelist.
  MergeDocument filterRecords(bool Function(String key) predicate) {
    final filtered = MergeDocument();
    filtered._vclock.addAll(_vclock);
    for (final entry in _records.entries) {
      if (!predicate(entry.key)) continue;
      final record = entry.value.clone();
      filtered._records[entry.key] = record;
      for (final id in record.presence.seen.keys) {
        filtered._eventDigests[id] = _eventDigests[id]!;
      }
    }
    return filtered;
  }

  Map<String, Object?> toJson() => {
    'schema': 3,
    'vclock': Map<String, int>.of(_vclock),
    'eventDigests': Map<String, String>.of(_eventDigests),
    'records': {
      for (final entry in _records.entries) entry.key: entry.value.toJson(),
    },
  };
  factory MergeDocument.fromJson(Map<String, Object?> json) {
    _keys(json, {'schema', 'vclock', 'eventDigests', 'records'});
    if (json['schema'] != 3)
      throw const FormatException('Unsupported merge schema');
    final document = MergeDocument();
    document._vclock.addAll(_counters(json['vclock']));
    document._eventDigests.addAll(_digests(json['eventDigests']));
    final referencedEvents = <String>{};
    for (final entry in _map(json['records']).entries) {
      final record = _Record.fromJson(entry.value);
      if (record.presence.values.isEmpty) {
        throw const FormatException('Record lacks a presence candidate');
      }
      referencedEvents.addAll(record.presence.seen.keys);
      for (final cell in record.cells) {
        for (final id in cell.seen.keys) {
          if (!document._eventDigests.containsKey(id)) {
            throw const FormatException('Cell references an unknown event');
          }
        }
      }
      document._records[entry.key] = record;
    }
    for (final id in document._eventDigests.keys) {
      if (!referencedEvents.contains(id)) {
        throw const FormatException('Event lacks a record presence context');
      }
      final dot = MergeDot.parse(id);
      if (document.counterFor(dot.actor) < dot.counter) {
        throw const FormatException('Event exceeds allocation floor');
      }
    }
    return document;
  }
}

/// Canonically hashed full causal checkpoint, including tombstones and contexts.
class MergeBatch {
  final String actor;
  final int counter;
  final MergeDocument document;
  final String id;
  MergeBatch({
    required this.actor,
    required this.counter,
    required this.document,
    String? id,
  }) : id = id ?? _computeId(actor, counter, document);
  factory MergeBatch.create({
    required String actor,
    required int counter,
    required MergeDocument document,
  }) => MergeBatch(actor: actor, counter: counter, document: document.clone());
  static String _computeId(String actor, int counter, MergeDocument document) =>
      _digest({
        'actor': actor,
        'counter': counter,
        'document': document.toJson(),
      });

  /// Rechecks a publication supplied by a caller without copying its document.
  /// A matching id alone is not proof after a mutable document was changed.
  void validateIdentity() {
    if (actor.isEmpty ||
        counter <= 0 ||
        document.counterFor(actor) != counter ||
        id != _computeId(actor, counter, document)) {
      throw const FormatException('Batch counter or digest mismatch');
    }
  }

  /// The wire payload omits its own digest: a body cannot hash itself.
  /// Durable [toJson] includes the digest; transport authenticates these bytes
  /// against the filename before passing that verified digest to [fromJson].
  Uint8List serializeBytes() => Uint8List.fromList(
    utf8.encode(
      canonicalSyncJson({
        'actor': actor,
        'counter': counter,
        'document': document.toJson(),
      }),
    ),
  );
  String computeDigest() => id;
  bool dominates(MergeBatch other) => document.dominates(other.document);
  bool covers(MergeBatch other) => dominates(other);
  bool coversActor(String actor, int counter) =>
      document.coversActor(actor, counter);
  Map<String, Object?> toJson() => {
    'actor': actor,
    'counter': counter,
    'document': document.toJson(),
    'id': id,
  };
  factory MergeBatch.fromJson(Map<String, Object?> json) {
    _keys(json, {'actor', 'counter', 'document', 'id'});
    if (json['actor'] is! String ||
        (json['actor'] as String).isEmpty ||
        json['counter'] is! int ||
        (json['counter'] as int) <= 0 ||
        json['id'] is! String) {
      throw const FormatException('Invalid batch metadata');
    }
    final actor = json['actor'] as String;
    final counter = json['counter'] as int;
    final document = MergeDocument.fromJson(_map(json['document']));
    if (document.counterFor(actor) != counter ||
        json['id'] != _computeId(actor, counter, document)) {
      throw const FormatException('Batch counter or digest mismatch');
    }
    return MergeBatch(
      actor: actor,
      counter: counter,
      document: document,
      id: json['id'] as String,
    );
  }
}
