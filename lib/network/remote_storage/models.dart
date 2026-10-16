import 'dart:convert';

enum StorageBackend { webdav, openlist }

enum StorageAuthorizationStatus { unknown, valid, invalid }

class StorageAccount {
  const StorageAccount({
    required this.id,
    required this.backend,
    required this.driver,
    required this.name,
    required this.authorization,
    this.status = StorageAuthorizationStatus.unknown,
    this.statusMessage,
  });

  final String id;
  final StorageBackend backend;
  final String driver;
  final String name;
  final Map<String, dynamic> authorization;
  final StorageAuthorizationStatus status;
  final String? statusMessage;

  bool get isConfigured => id.isNotEmpty && driver.isNotEmpty;
  bool get authorizationIsKnownInvalid =>
      status == StorageAuthorizationStatus.invalid;

  StorageAccount copyWith({
    String? name,
    Map<String, dynamic>? authorization,
    StorageAuthorizationStatus? status,
    String? statusMessage,
    bool clearStatusMessage = false,
  }) => StorageAccount(
    id: id,
    backend: backend,
    driver: driver,
    name: name ?? this.name,
    authorization: authorization ?? this.authorization,
    status: status ?? this.status,
    statusMessage: clearStatusMessage
        ? null
        : statusMessage ?? this.statusMessage,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'backend': backend.name,
    'driver': driver,
    'name': name,
    'authorization': authorization,
    'status': status.name,
    if (statusMessage != null) 'statusMessage': statusMessage,
  };

  factory StorageAccount.fromJson(Map<Object?, Object?> json) {
    final backend = _enumByName(
      StorageBackend.values,
      json['backend'] as String?,
    );
    final status = _enumByName(
      StorageAuthorizationStatus.values,
      json['status'] as String?,
    );
    return StorageAccount(
      id: json['id'] as String? ?? '',
      backend: backend ?? StorageBackend.openlist,
      driver: json['driver'] as String? ?? '',
      name: json['name'] as String? ?? '',
      authorization: _jsonMap(json['authorization']),
      status: status ?? StorageAuthorizationStatus.unknown,
      statusMessage: json['statusMessage'] as String?,
    );
  }

  @override
  String toString() => jsonEncode({
    'id': id,
    'backend': backend.name,
    'driver': driver,
    'name': name,
  });
}

T? _enumByName<T extends Enum>(Iterable<T> values, String? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

class RemoteLocation {
  const RemoteLocation({required this.accountId, required this.directory});

  final String accountId;
  final String directory;

  RemoteLocation normalized() => RemoteLocation(
    accountId: accountId,
    directory: normalizeRemoteDirectory(directory),
  );

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'directory': normalizeRemoteDirectory(directory),
  };

  factory RemoteLocation.fromJson(Map<Object?, Object?> json) => RemoteLocation(
    accountId: json['accountId'] as String? ?? '',
    directory: json['directory'] as String? ?? '/',
  ).normalized();
}

class RemoteLibrary {
  const RemoteLibrary({
    required this.id,
    required this.sourceKey,
    required this.accountId,
    required this.directories,
    required this.name,
    this.autoRefresh = true,
    this.refreshIntervalMinutes = 360,
  });

  final String id;
  final String sourceKey;
  final String accountId;
  final List<String> directories;
  final String name;
  final bool autoRefresh;
  final int refreshIntervalMinutes;

  RemoteLibrary normalized() => RemoteLibrary(
    id: id,
    sourceKey: sourceKey,
    accountId: accountId,
    directories: normalizeRemoteDirectories(directories),
    name: name,
    autoRefresh: autoRefresh,
    refreshIntervalMinutes: refreshIntervalMinutes,
  );

  RemoteLibrary copyWith({
    List<String>? directories,
    String? name,
    bool? autoRefresh,
    int? refreshIntervalMinutes,
  }) => RemoteLibrary(
    id: id,
    sourceKey: sourceKey,
    accountId: accountId,
    directories: directories ?? this.directories,
    name: name ?? this.name,
    autoRefresh: autoRefresh ?? this.autoRefresh,
    refreshIntervalMinutes:
        refreshIntervalMinutes ?? this.refreshIntervalMinutes,
  ).normalized();

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceKey': sourceKey,
    'accountId': accountId,
    'directories': normalizeRemoteDirectories(directories),
    'name': name,
    'autoRefresh': autoRefresh,
    'refreshIntervalMinutes': refreshIntervalMinutes,
  };

  factory RemoteLibrary.fromJson(Map<Object?, Object?> json) => RemoteLibrary(
    id: json['id'] as String? ?? '',
    sourceKey: json['sourceKey'] as String? ?? '',
    accountId: json['accountId'] as String? ?? '',
    directories: (json['directories'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    name: json['name'] as String? ?? '',
    autoRefresh: json['autoRefresh'] != false,
    refreshIntervalMinutes:
        (json['refreshIntervalMinutes'] as num?)?.toInt() ?? 360,
  ).normalized();
}

String normalizeRemoteDirectory(String value) {
  final segments = value
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((item) => item.isNotEmpty && item != '.')
      .toList();
  if (segments.any((item) => item == '..')) {
    throw const FormatException('Invalid remote directory path');
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}/';
}

List<String> normalizeRemoteDirectories(Iterable<String> directories) {
  final result = <String>[];
  final seen = <String>{};
  for (final directory in directories) {
    final normalized = normalizeRemoteDirectory(directory);
    if (seen.add(normalized)) result.add(normalized);
  }
  return result;
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry('$key', item));
}
