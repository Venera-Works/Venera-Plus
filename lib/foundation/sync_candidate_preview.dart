import 'sync_records.dart';

/// Shared UI/CLI boundary: never preview credentials or executable/session data.
bool syncCandidatePreviewIsProtected({
  required String domain,
  required String field,
  String? recordKey,
}) {
  if (domain == 'cookies' || domain == 'sourceSession' || domain == 'source') {
    return true;
  }
  if (domain != 'setting') return false;
  if (_sensitiveSettingPart(field)) return true;
  if (recordKey == null) return false;
  try {
    final identity = syncRecordIdentity(recordKey);
    if (identity.isNotEmpty) {
      final root = identity.first?.toString().toLowerCase();
      if (root == 'backupwebdav' ||
          root == 'webdavcomiclibrary' ||
          root == 'webdav') {
        return true;
      }
    }
    return identity.any(
      (part) => _sensitiveSettingPart(part?.toString() ?? ''),
    );
  } on FormatException {
    // Malformed identities must not bypass the preview boundary.
    return true;
  }
}

bool _sensitiveSettingPart(String part) {
  final lower = part.toLowerCase();
  return const [
    'token',
    'pass',
    'auth',
    'secret',
    'key',
    'credential',
    'pin',
  ].any(lower.contains);
}
