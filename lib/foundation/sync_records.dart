import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Representation of business records materialized for sync.
///
/// Map of recordKey -> fields.
/// Each record is a map of fieldName -> JSON-encodable value.
/// An empty field map represents existence of a record with no specific fields.
typedef SyncRecords = Map<String, Map<String, Object?>>;

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
