import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Representation of business records materialized for sync.
///
/// Map of recordKey -> fields.
/// Each record is a map of fieldName -> JSON-encodable value.
/// An empty field map represents existence of a record with no specific fields.
typedef SyncRecords = Map<String, Map<String, Object?>>;

/// Local snapshot containing materialized sync records, discovered source variants,
/// and flags indicating if local storage requires source file normalization.
class SyncLocalSnapshot {
  /// Materialized business records with deterministic representatives.
  final SyncRecords records;

  /// Discovered distinct content variants for source identities with differing duplicate scripts.
  ///
  /// Keys are encoded source record keys: `syncRecordKey('source', [key])`.
  /// Values are distinct atomic script objects: `{'filename': ..., 'content': ...}`.
  final Map<String, List<Map<String, Object?>>> sourceVariants;

  /// Whether local physical storage contains duplicate source identities needing normalization.
  final bool needsSourceNormalization;

  /// Issues encountered during source scanning (empty/corrupted/unsupported scripts, session errors, etc.).
  final List<SyncSourceIssue> sourceIssues;

  /// Domains that could not be fully captured or verified (e.g. 'source', 'sourceSession').
  final Set<String> unavailableDomains;

  const SyncLocalSnapshot({
    required this.records,
    this.sourceVariants = const {},
    this.needsSourceNormalization = false,
    this.sourceIssues = const [],
    this.unavailableDomains = const {},
  });
}

/// Issue encountered with a comic source or source session file during sync scan or migration.
class SyncSourceIssue {
  final String filename;
  final String reason;

  /// SHA-256 digest of the exact bytes observed when this issue was created.
  /// Used to reject repair actions after the file has changed.
  final String? contentDigest;
  final String? sourceKey;
  final String? backupPath;
  final String? archiveName;
  final bool recovered;

  const SyncSourceIssue({
    required this.filename,
    required this.reason,
    this.contentDigest,
    this.sourceKey,
    this.backupPath,
    this.archiveName,
    this.recovered = false,
  });

  SyncSourceIssue copyWith({
    String? filename,
    String? reason,
    String? contentDigest,
    String? sourceKey,
    String? backupPath,
    String? archiveName,
    bool? recovered,
  }) {
    return SyncSourceIssue(
      filename: filename ?? this.filename,
      reason: reason ?? this.reason,
      contentDigest: contentDigest ?? this.contentDigest,
      sourceKey: sourceKey ?? this.sourceKey,
      backupPath: backupPath ?? this.backupPath,
      archiveName: archiveName ?? this.archiveName,
      recovered: recovered ?? this.recovered,
    );
  }

  Map<String, Object?> toJson() => {
    'filename': filename,
    'reason': reason,
    if (contentDigest != null) 'contentDigest': contentDigest,
    if (sourceKey != null) 'sourceKey': sourceKey,
    if (backupPath != null) 'backupPath': backupPath,
    if (archiveName != null) 'archiveName': archiveName,
    'recovered': recovered,
  };

  factory SyncSourceIssue.fromJson(Map<String, Object?> json) {
    final contentDigest = json['contentDigest'];
    if (contentDigest != null &&
        (contentDigest is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentDigest))) {
      throw const FormatException('Invalid source issue content digest');
    }
    return SyncSourceIssue(
      filename: json['filename'] as String? ?? '',
      reason: json['reason'] as String? ?? 'unknown',
      contentDigest: contentDigest as String?,
      sourceKey: json['sourceKey'] as String?,
      backupPath: json['backupPath'] as String?,
      archiveName: json['archiveName'] as String?,
      recovered: json['recovered'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncSourceIssue &&
        other.filename == filename &&
        other.reason == reason &&
        other.contentDigest == contentDigest &&
        other.sourceKey == sourceKey &&
        other.backupPath == backupPath &&
        other.archiveName == archiveName &&
        other.recovered == recovered;
  }

  @override
  int get hashCode => Object.hash(
    filename,
    reason,
    contentDigest,
    sourceKey,
    backupPath,
    archiveName,
    recovered,
  );

  @override
  String toString() =>
      'SyncSourceIssue(filename: $filename, reason: $reason, '
      'sourceKey: $sourceKey, backupPath: $backupPath, archiveName: $archiveName, recovered: $recovered)';
}

/// Encodes a record identity into a stable, unambiguous JSON-string key.
///
/// Example: `syncRecordKey('folder', ['folder-123'])` -> `["folder","folder-123"]`
String syncRecordKey(String domain, List<Object?> identity) {
  return jsonEncode([domain, ...identity]);
}

/// Deterministic legacy folder ID based on exact folder name.
/// Used during migration to stabilize identities of folders with the same name.
String legacySyncFolderId(String name) {
  return 'legacy-${sha256.convert(utf8.encode(name))}';
}

/// Decodes a stable JSON-string key back into `[domain, ...identity]`.
List<Object?> decodeSyncRecordKey(String key) {
  final decoded = jsonDecode(key);
  if (decoded is! List) {
    throw FormatException('Sync record key must be a JSON array: $key');
  }
  return List<Object?>.from(decoded);
}

/// Extracts the domain from an encoded sync record key.
String syncRecordDomain(String key) {
  final parts = decodeSyncRecordKey(key);
  if (parts.isEmpty || parts.first is! String) {
    throw FormatException(
      'Invalid sync record key, domain must be String: $key',
    );
  }
  return parts.first as String;
}

/// Extracts the identity parts (without domain) from an encoded sync record key.
List<Object?> syncRecordIdentity(String key) {
  final parts = decodeSyncRecordKey(key);
  if (parts.isEmpty) {
    throw FormatException('Invalid sync record key, empty: $key');
  }
  return parts.sublist(1);
}

/// Recursively canonicalizes a JSON value:
/// - Maps have keys converted to strings and sorted lexicographically.
/// - Lists preserve order, with items canonicalized recursively.
/// - Primitives remain as-is.
Object? canonicalizeSyncValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map(
              (e) => MapEntry(e.key.toString(), canonicalizeSyncValue(e.value)),
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return {for (final e in entries) e.key: e.value};
  }
  if (value is List) {
    return value.map(canonicalizeSyncValue).toList();
  }
  if (value is Iterable) {
    return value.map(canonicalizeSyncValue).toList();
  }
  return value;
}

/// Serializes [value] into canonical JSON where map keys are recursively sorted.
String canonicalSyncJson(Object? value) {
  return jsonEncode(canonicalizeSyncValue(value));
}

/// Deep equality comparison for JSON-valued objects.
///
/// Recursively handles Maps (order independent), Lists (order preserved),
/// numbers, booleans, strings, and null.
bool syncValuesEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!syncValuesEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!syncValuesEqual(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  return canonicalSyncJson(a) == canonicalSyncJson(b);
}

/// Creates a deep copy of a [SyncRecords] map.
SyncRecords cloneSyncRecords(SyncRecords records) {
  final copy = <String, Map<String, Object?>>{};
  for (final recordEntry in records.entries) {
    final fields = <String, Object?>{};
    for (final fieldEntry in recordEntry.value.entries) {
      fields[fieldEntry.key] = _deepCloneSyncValue(fieldEntry.value);
    }
    copy[recordEntry.key] = fields;
  }
  return copy;
}

Object? _deepCloneSyncValue(Object? value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        e.key.toString(): _deepCloneSyncValue(e.value),
    };
  }
  if (value is List) {
    return value.map(_deepCloneSyncValue).toList();
  }
  return value;
}
