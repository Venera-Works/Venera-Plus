part of 'remote_library_engine.dart';

class RemoteLibraryMetadataInput {
  const RemoteLibraryMetadataInput({
    required this.title,
    this.directoryTitle,
    this.fileNames = const [],
    this.authors = const [],
  });

  final String title;
  final String? directoryTitle;
  final Iterable<String> fileNames;
  final Iterable<String> authors;
}

typedef RemoteLibraryMetadataScraper =
    Future<ComicMetaData?> Function(RemoteLibraryMetadataInput input);

typedef RemoteLibraryMetadataSubjectHandler =
    FutureOr<void> Function({
      required String scopeId,
      required String sourceKey,
      required String comicId,
      required int subjectId,
    });

typedef RemoteLibraryMetadataWriteGuard =
    FutureOr<bool> Function(String libraryId, String comicId, int? subjectId);

/// Persistent library configuration.  The storage account itself is managed
/// by `remote_storage`; this registry owns only the comic-library relation.
/// Keeping this relation separate lets one account back several libraries.
class RemoteComicLibraryRegistry {
  RemoteComicLibraryRegistry._();

  static const settingsKey = 'remoteLibraries';

  /// Importers reset this only for snapshots containing a valid legacy WebDAV
  /// configuration and no `remoteLibraries` field.
  static const legacyMigrationKey = 'remoteComicLibraryLegacyMigrated';
  static const legacyAccountMigrationKey =
      'remoteComicLibraryLegacyAccountMigrated';

  static List<RemoteLibrary> read() {
    final value = appdata.settings[settingsKey];
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => RemoteLibrary.fromJson(item))
        .where(
          (item) =>
              item.id.isNotEmpty &&
              item.sourceKey.isNotEmpty &&
              item.accountId.isNotEmpty &&
              item.directories.isNotEmpty,
        )
        .toList(growable: false);
  }

  static RemoteLibrary? findBySourceKey(String sourceKey) {
    for (final library in read()) {
      if (library.sourceKey == sourceKey) return library;
    }
    return null;
  }

  static Future<void> save(RemoteLibrary library) async {
    final normalized = library.normalized();
    if (normalized.id.isEmpty ||
        normalized.sourceKey.isEmpty ||
        normalized.accountId.isEmpty ||
        normalized.directories.isEmpty) {
      throw ArgumentError(
        'A comic library needs an id, source key, account and directory',
      );
    }
    final libraries = read().toList();
    final index = libraries.indexWhere((item) => item.id == normalized.id);
    if (index >= 0) {
      // IDs and source keys are immutable once a library exists.
      final existing = libraries[index];
      if (existing.sourceKey != normalized.sourceKey ||
          existing.accountId != normalized.accountId) {
        throw ArgumentError(
          'A library cannot change source or account identity',
        );
      }
      libraries[index] = normalized;
    } else {
      if (libraries.any((item) => item.sourceKey == normalized.sourceKey)) {
        throw ArgumentError('Comic library source key already exists');
      }
      libraries.add(normalized);
    }
    appdata.settings[settingsKey] = [
      for (final item in libraries) item.toJson(),
    ];
    await appdata.saveData(false);
  }

  static Future<void> remove(String libraryId) async {
    final libraries = read().where((item) => item.id != libraryId).toList();
    appdata.settings[settingsKey] = [
      for (final item in libraries) item.toJson(),
    ];
    await appdata.saveData(false);
  }

  /// Creates stable values once. Directory reordering and later edits only
  /// use [RemoteLibrary.copyWith], so they never create new comic identities.
  static RemoteLibrary create({
    required String accountId,
    required List<String> directories,
    required String name,
  }) {
    final seed = '${DateTime.now().microsecondsSinceEpoch}:$accountId:$name';
    final digest = sha256.convert(utf8.encode(seed)).toString();
    return RemoteLibrary(
      id: 'remote-library-$digest',
      sourceKey: 'remote_library_$digest',
      accountId: accountId,
      directories: directories,
      name: name,
    ).normalized();
  }

  /// Imports the old singleton WebDAV configuration as a library relation.
  /// The legacy source still serves it so its historical comic ids stay
  /// untouched; the stored relation makes it manageable beside new libraries.
  static Future<void> migrateLegacyRemoteLibrary() async {
    final storage = RemoteStorageAccounts.instance;
    final existing = findBySourceKey(RemoteLibrarySource.sourceKey);
    final legacy = RemoteLibraryConfig.fromSettings();
    if (existing != null) {
      if (appdata.settings[legacyAccountMigrationKey] == true) return;
      if (storage.account(existing.accountId) == null) {
        if (!legacy.isValid || existing.id != legacy.libraryId) return;
        StorageAccount? matching;
        for (final account in storage.accounts.where(
          (account) => account.backend == StorageBackend.webdav,
        )) {
          final endpoint = WebDavEndpoint(
            url: account.authorization['url'] as String? ?? '',
            user: account.authorization['user'] as String? ?? '',
            password: account.authorization['password'] as String? ?? '',
          );
          if (endpoint.url == legacy.url &&
              endpoint.user == legacy.user &&
              endpoint.password == legacy.pass) {
            matching = account;
            break;
          }
        }
        if (matching == null) {
          await storage.save(
            StorageAccount(
              id: existing.accountId,
              backend: StorageBackend.webdav,
              driver: 'webdav',
              name: storage.availableName('WebDAV漫画库'),
              authorization: {
                'url': legacy.url,
                'user': legacy.user,
                'password': legacy.pass,
              },
            ),
          );
        } else {
          await storage.saveLibrary(
            RemoteLibrary(
              id: existing.id,
              sourceKey: existing.sourceKey,
              accountId: matching.id,
              directories: existing.directories,
              name: existing.name,
              autoRefresh: existing.autoRefresh,
              refreshIntervalMinutes: existing.refreshIntervalMinutes,
            ),
          );
        }
      }
      appdata.settings[legacyAccountMigrationKey] = true;
      appdata.settings[legacyMigrationKey] = true;
      await appdata.saveData(false);
      return;
    }
    if (appdata.settings[legacyMigrationKey] == true) return;
    if (!legacy.isValid) {
      appdata.settings[legacyMigrationKey] = true;
      await appdata.saveData(false);
      return;
    }
    final accountId =
        'legacy-${sha256.convert(utf8.encode(jsonEncode([legacy.url, legacy.user.trim()])))}';
    if (RemoteStorageAccounts.instance.account(accountId) == null) {
      await RemoteStorageAccounts.instance.save(
        StorageAccount(
          id: accountId,
          backend: StorageBackend.webdav,
          driver: 'webdav',
          name: storage.availableName('WebDAV漫画库'),
          authorization: {
            'url': legacy.url,
            'user': legacy.user,
            'password': legacy.pass,
          },
        ),
      );
    }
    await RemoteStorageAccounts.instance.saveLibrary(
      RemoteLibrary(
        id: legacy.libraryId,
        sourceKey: RemoteLibrarySource.sourceKey,
        accountId: accountId,
        directories: [legacy.remotePath],
        // 旧默认标题也是 explore_pages 的身份，迁移时保留其启用状态。
        name: 'WebDAV Library',
        autoRefresh: appdata.settings['webdavComicLibraryAutoSync'] != false,
        refreshIntervalMinutes:
            (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
                ?.toInt() ??
            360,
      ),
    );
    appdata.settings[legacyMigrationKey] = true;
    appdata.settings[legacyAccountMigrationKey] = true;
    await appdata.saveData(false);
  }
}

enum RemoteLibraryFailureKind {
  preconditionFailed,
  authentication,
  transient,
  unsupported,
  other,
}

class RemoteLibraryException implements Exception {
  const RemoteLibraryException(
    this.message, {
    required this.kind,
    this.statusCode,
    this.path,
    this.cause,
  });

  final String message;
  final RemoteLibraryFailureKind kind;
  final int? statusCode;
  final String? path;
  final Object? cause;

  bool get isRetryable =>
      kind == RemoteLibraryFailureKind.preconditionFailed ||
      kind == RemoteLibraryFailureKind.transient;

  @override
  String toString() => message;
}

class RemoteLibraryPreconditionFailedException extends RemoteLibraryException {
  const RemoteLibraryPreconditionFailedException(String path)
    : super(
        'WebDAV resource changed before it could be written: $path',
        kind: RemoteLibraryFailureKind.preconditionFailed,
        statusCode: 412,
        path: path,
      );
}

class RemoteLibraryAuthenticationException extends RemoteLibraryException {
  const RemoteLibraryAuthenticationException(
    String path, {
    required super.statusCode,
    super.cause,
  }) : super(
         'WebDAV authentication or permission failed for $path',
         kind: RemoteLibraryFailureKind.authentication,
         path: path,
       );
}

class RemoteLibraryTransientException extends RemoteLibraryException {
  const RemoteLibraryTransientException(
    String path, {
    super.statusCode,
    super.cause,
  }) : super(
         'Temporary WebDAV failure for $path',
         kind: RemoteLibraryFailureKind.transient,
         path: path,
       );
}

class RemoteLibraryUnsupportedException extends RemoteLibraryException {
  const RemoteLibraryUnsupportedException(
    String path, {
    super.statusCode,
    String? message,
    super.cause,
  }) : super(
         message ?? 'The WebDAV server does not support safe writes for $path',
         kind: RemoteLibraryFailureKind.unsupported,
         path: path,
       );
}

class RemoteLibraryTextFile {
  const RemoteLibraryTextFile({
    required this.content,
    this.eTag,
    this.modifiedAt,
  });

  final String content;
  final String? eTag;
  final int? modifiedAt;
}

class RemoteLibraryWriteResult {
  const RemoteLibraryWriteResult({this.eTag, this.modifiedAt});

  final String? eTag;
  final int? modifiedAt;
}

class RemoteLibraryConfig {
  RemoteLibraryConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
    this.remoteLibrary,
    this.remoteStore,
    this.legacyAnchor,
    this.legacyCacheKey,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_comics/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;
  final RemoteLibrary? remoteLibrary;
  final RemoteFileStore? remoteStore;
  final String? legacyAnchor;
  final String? legacyCacheKey;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => endpoint.isValid || remoteStore != null;

  List<String> get directories => remoteLibrary?.directories ?? [remotePath];

  Map<String, String> get authHeaders => endpoint.authHeaders;

  String get cacheKey =>
      legacyCacheKey ??
      (remoteLibrary == null
          ? jsonEncode([url, user, remotePath])
          : 'remote-library:${remoteLibrary!.id}');

  String get archiveAccountKey => remoteStore != null
      ? 'remote-account:${remoteStore!.account.id}'
      : 'webdav-account:${sha256.convert(utf8.encode(jsonEncode([url, user])))}';

  String get libraryId {
    if (remoteLibrary != null) return remoteLibrary!.id;
    final identity = jsonEncode([url, user.trim(), remotePath]);
    return 'webdav:${sha256.convert(utf8.encode(identity))}';
  }

  String get configuredSourceKey =>
      remoteLibrary?.sourceKey ?? RemoteLibrarySource.sourceKey;

  factory RemoteLibraryConfig.forRemoteLibrary(
    RemoteLibrary library,
    RemoteFileStore store, {
    required String root,
    String? legacyAnchor,
    String? legacyCacheKey,
  }) => RemoteLibraryConfig(
    url: '',
    user: '',
    pass: '',
    remotePath: root,
    remoteLibrary: library,
    remoteStore: store,
    legacyAnchor: legacyAnchor,
    legacyCacheKey: legacyCacheKey,
  );

  String get connectionKey => jsonEncode([url, user, pass, remotePath]);

  static RemoteLibraryConfig fromSettings() {
    final config = appdata.settings['webdavComicLibrary'];
    final path = appdata.settings['webdavComicLibraryPath'];
    try {
      if (config is List &&
          config.length == 3 &&
          config.every((value) => value is String)) {
        final values = config.cast<String>();
        return RemoteLibraryConfig(
          url: values[0],
          user: values[1],
          pass: values[2],
          remotePath: path is String ? path : '/venera_comics/',
        );
      }
      return RemoteLibraryConfig(
        url: '',
        user: '',
        pass: '',
        remotePath: path is String ? path : '/venera_comics/',
      );
    } on FormatException {
      return RemoteLibraryConfig(
        url: '',
        user: '',
        pass: '',
        remotePath: '/venera_comics/',
      );
    }
  }

  static Future<void> saveToSettings(RemoteLibraryConfig config) async {
    final previous = fromSettings();
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      appdata.settings['webdavComicLibrary'] = [];
    } else {
      appdata.settings['webdavComicLibrary'] = [
        config.url,
        config.user,
        config.pass,
      ];
    }
    appdata.settings['webdavComicLibraryPath'] = config.remotePath;
    await appdata.saveData(false);
    if (previous.connectionKey != config.connectionKey) {
      await RemoteLibrarySource.onConfigurationChanged(previous);
    }
  }

  String childDirectoryPath(String name) {
    if (name.isEmpty) return legacyAnchor ?? remotePath;
    if (name.startsWith('/')) {
      return normalizeWebDavDirectoryPath(name, fallback: '/');
    }
    if (legacyAnchor != null) {
      return childDirectoryPathFrom(legacyAnchor!, name);
    }
    return childDirectoryPathFrom(remotePath, name);
  }

  String childFilePath(String parent, String name) {
    return joinWebDavFilePath(parent, name);
  }

  String childDirectoryPathFrom(String parent, String name) {
    return joinWebDavDirectoryPath(parent, name);
  }

  String fileUrl(String remoteFilePath) => endpoint.fileUrl(remoteFilePath);
}

class RemoteLibraryEntry {
  const RemoteLibraryEntry({
    required this.name,
    required this.isDirectory,
    this.eTag,
    this.modifiedAt,
    this.size,
  });

  final String name;
  final bool isDirectory;
  final String? eTag;
  final int? modifiedAt;
  final int? size;
}

abstract class RemoteLibraryOps {
  Future<void> test(RemoteLibraryConfig config);

  Future<List<RemoteLibraryEntry>> readDir(
    RemoteLibraryConfig config,
    String remotePath, {
    bool refresh = false,
  });

  Future<RemoteLibraryTextFile> readText(
    RemoteLibraryConfig config,
    String remotePath,
  );

  Future<RemoteLibraryWriteResult> writeText(
    RemoteLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  });
}

class _RemoteLibraryOps implements RemoteLibraryOps {
  final _clients = <String, Client>{};

  Client _client(RemoteLibraryConfig config) {
    return _clients.putIfAbsent(
      config.connectionKey,
      config.endpoint.createClient,
    );
  }

  @override
  Future<void> test(RemoteLibraryConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<RemoteLibraryEntry>> readDir(
    RemoteLibraryConfig config,
    String remotePath, {
    bool refresh = false,
  }) async {
    final entries = await _client(config).readDir(remotePath);
    return entries
        .where((entry) => entry.name != null)
        .map(
          (entry) => RemoteLibraryEntry(
            name: entry.name!,
            isDirectory: entry.isDir == true,
            eTag: entry.eTag?.isEmpty == true ? null : entry.eTag,
            modifiedAt: entry.mTime?.millisecondsSinceEpoch,
            size: entry.size,
          ),
        )
        .toList();
  }

  @override
  Future<RemoteLibraryTextFile> readText(
    RemoteLibraryConfig config,
    String remotePath,
  ) async {
    final client = _client(config);
    try {
      final response = await client.c.req<List<int>>(
        client,
        'GET',
        remotePath,
        optionsHandler: (options) => options.responseType = ResponseType.bytes,
      );
      _throwForStatus(response.statusCode, remotePath);
      return RemoteLibraryTextFile(
        content: utf8.decode(response.data ?? const [], allowMalformed: false),
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _classifyDioError(error, remotePath);
    }
  }

  @override
  Future<RemoteLibraryWriteResult> writeText(
    RemoteLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    if (createOnly && (ifMatch != null || ifUnmodifiedSince != null)) {
      throw ArgumentError(
        'createOnly cannot be combined with update preconditions',
      );
    }
    final client = _client(config);
    try {
      final response = await client.c.req<Object?>(
        client,
        'PUT',
        remotePath,
        data: Uint8List.fromList(utf8.encode(content)),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['content-type'] = 'application/json; charset=utf-8';
          if (createOnly) {
            options.headers!['if-none-match'] = '*';
          } else if (ifMatch != null) {
            options.headers!['if-match'] = ifMatch;
          } else if (ifUnmodifiedSince != null) {
            options.headers!['if-unmodified-since'] = HttpDate.format(
              DateTime.fromMillisecondsSinceEpoch(
                ifUnmodifiedSince,
                isUtc: true,
              ),
            );
          }
        },
      );
      _throwForStatus(response.statusCode, remotePath);
      return RemoteLibraryWriteResult(
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _classifyDioError(error, remotePath);
    }
  }

  static String? _header(Map<String, List<String>> headers, String name) {
    final values = headers[name];
    if (values == null || values.isEmpty || values.first.trim().isEmpty) {
      return null;
    }
    return values.first;
  }

  static int? _modifiedAt(Map<String, List<String>> headers) {
    final value = _header(headers, 'last-modified');
    if (value == null) return null;
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static void _throwForStatus(int? statusCode, String path) {
    if (statusCode != null && statusCode >= 200 && statusCode < 300) return;
    if (statusCode == 412) throw RemoteLibraryPreconditionFailedException(path);
    if (statusCode == 401 || statusCode == 403) {
      throw RemoteLibraryAuthenticationException(path, statusCode: statusCode!);
    }
    if (statusCode == 405 || statusCode == 501) {
      throw RemoteLibraryUnsupportedException(path, statusCode: statusCode);
    }
    if (statusCode == null ||
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500) {
      throw RemoteLibraryTransientException(path, statusCode: statusCode);
    }
    throw RemoteLibraryException(
      'WebDAV request failed with HTTP $statusCode for $path',
      kind: RemoteLibraryFailureKind.other,
      statusCode: statusCode,
      path: path,
    );
  }

  static RemoteLibraryException _classifyDioError(
    DioException error,
    String path,
  ) {
    final status = error.response?.statusCode;
    if (status == 412) return RemoteLibraryPreconditionFailedException(path);
    if (status == 401 || status == 403) {
      return RemoteLibraryAuthenticationException(
        path,
        statusCode: status!,
        cause: error,
      );
    }
    if (status == 405 || status == 501) {
      return RemoteLibraryUnsupportedException(
        path,
        statusCode: status,
        cause: error,
      );
    }
    if (status == null ||
        status == 408 ||
        status == 425 ||
        status == 429 ||
        status >= 500) {
      return RemoteLibraryTransientException(
        path,
        statusCode: status,
        cause: error,
      );
    }
    return RemoteLibraryException(
      'WebDAV request failed with HTTP $status for $path',
      kind: RemoteLibraryFailureKind.other,
      statusCode: status,
      path: path,
      cause: error,
    );
  }
}

class _RemoteFileStoreLibraryOps implements RemoteLibraryOps {
  const _RemoteFileStoreLibraryOps();

  RemoteFileStore _store(RemoteLibraryConfig config) {
    final store = config.remoteStore;
    if (store == null) throw StateError('Remote Library store is unavailable');
    return store;
  }

  @override
  Future<void> test(RemoteLibraryConfig config) => _store(config).test();

  @override
  Future<List<RemoteLibraryEntry>> readDir(
    RemoteLibraryConfig config,
    String remotePath, {
    bool refresh = false,
  }) async => (await _store(config).list(remotePath, refresh: refresh))
      .map(
        (entry) => RemoteLibraryEntry(
          name: entry.name,
          isDirectory: entry.isDirectory,
          eTag: entry.eTag,
          modifiedAt: entry.modifiedAt,
          size: entry.size,
        ),
      )
      .toList();

  @override
  Future<RemoteLibraryTextFile> readText(
    RemoteLibraryConfig config,
    String remotePath,
  ) async {
    final file = await _store(config).readText(remotePath);
    return RemoteLibraryTextFile(
      content: file.content,
      eTag: file.eTag,
      modifiedAt: file.modifiedAt,
    );
  }

  @override
  Future<RemoteLibraryWriteResult> writeText(
    RemoteLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    final isWebDav = _store(config).account.backend == StorageBackend.webdav;
    final result = await _store(config).writeText(
      remotePath,
      content,
      createOnly: isWebDav && createOnly,
      ifMatch: isWebDav ? ifMatch : null,
      ifUnmodifiedSince: isWebDav ? ifUnmodifiedSince : null,
    );
    return RemoteLibraryWriteResult(
      eTag: result.eTag,
      modifiedAt: result.modifiedAt,
    );
  }
}

enum RemoteLibraryMetadataScrapeResult { matched, noMatch, notNeeded }

enum RemoteLibraryMetadataPendingFailure {
  none,
  authentication,
  transient,
  unsupported,
  conflict,
  rejected,
  invalidMetadata,
  other,
}

class RemoteLibraryMetadataPendingStatus {
  const RemoteLibraryMetadataPendingStatus({
    required this.libraryId,
    required this.comicId,
    required this.subjectId,
    required this.attempts,
    required this.lastAttemptAt,
    required this.nextRetryAt,
    required this.failure,
    required this.errorMessage,
  });

  final String libraryId;
  final String comicId;
  final int? subjectId;
  final int attempts;
  final int? lastAttemptAt;
  final int? nextRetryAt;
  final RemoteLibraryMetadataPendingFailure failure;
  final String? errorMessage;
}

class RemoteLibraryMetadataWriteRejectedException implements Exception {
  const RemoteLibraryMetadataWriteRejectedException();

  @override
  String toString() => 'The Remote Library metadata write is no longer current';
}

class RemoteLibrarySyncStatus {
  const RemoteLibrarySyncStatus({
    required this.isSyncing,
    required this.lastSuccessfulSync,
    this.processed = 0,
    this.total = 0,
    this.failed = 0,
    this.errorMessage,
  });

  final bool isSyncing;
  final int lastSuccessfulSync;
  final int processed;
  final int total;
  final int failed;
  final String? errorMessage;

  String get formattedLastSuccessfulSync {
    if (lastSuccessfulSync <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(lastSuccessfulSync);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class _RemoteLibrarySyncRun {
  _RemoteLibrarySyncRun({
    required this.configurationIdentity,
    required this.generation,
    required this.indexReady,
    required this.complete,
    this.refresh = false,
  });

  final String configurationIdentity;
  final int generation;
  final Future<Res<bool>> indexReady;
  final Future<Res<bool>> complete;
  final bool refresh;
  bool hasPublished = false;
}

class _RemoteSynchronizationObsoleteException implements Exception {
  const _RemoteSynchronizationObsoleteException();
}

class _RemotePendingMetadataWrite {
  static const _unset = Object();

  const _RemotePendingMetadataWrite({
    required this.libraryId,
    required this.comicId,
    required this.subjectId,
    required this.metadata,
    required this.sequence,
    this.attempts = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.failure = RemoteLibraryMetadataPendingFailure.none,
    this.errorMessage,
  });

  factory _RemotePendingMetadataWrite.fromJson(Map<String, dynamic> json) {
    final libraryId = json['libraryId'];
    final comicId = json['comicId'];
    final subjectId = json['subjectId'];
    final rawMetadata = json['metadata'];
    if (libraryId is! String ||
        libraryId.isEmpty ||
        comicId is! String ||
        comicId.isEmpty ||
        (subjectId != null && (subjectId is! int || subjectId <= 0)) ||
        rawMetadata is! Map) {
      throw const FormatException(
        'Invalid pending Remote Library metadata write',
      );
    }
    final failureName = json['failure'];
    final failure = RemoteLibraryMetadataPendingFailure.values.firstWhere(
      (value) => value.name == failureName,
      orElse: () => RemoteLibraryMetadataPendingFailure.other,
    );
    return _RemotePendingMetadataWrite(
      libraryId: libraryId,
      comicId: comicId,
      subjectId: subjectId as int?,
      metadata: ComicMetaData.fromJson(Map<String, dynamic>.from(rawMetadata)),
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastAttemptAt: (json['lastAttemptAt'] as num?)?.toInt(),
      nextRetryAt: (json['nextRetryAt'] as num?)?.toInt(),
      failure: failure,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  final String libraryId;
  final String comicId;
  final int? subjectId;
  final ComicMetaData metadata;
  final int sequence;
  final int attempts;
  final int? lastAttemptAt;
  final int? nextRetryAt;
  final RemoteLibraryMetadataPendingFailure failure;
  final String? errorMessage;

  RemoteLibraryMetadataPendingStatus get status =>
      RemoteLibraryMetadataPendingStatus(
        libraryId: libraryId,
        comicId: comicId,
        subjectId: subjectId,
        attempts: attempts,
        lastAttemptAt: lastAttemptAt,
        nextRetryAt: nextRetryAt,
        failure: failure,
        errorMessage: errorMessage,
      );

  _RemotePendingMetadataWrite copyWith({
    int? attempts,
    int? lastAttemptAt,
    Object? nextRetryAt = _unset,
    RemoteLibraryMetadataPendingFailure? failure,
    String? errorMessage,
  }) => _RemotePendingMetadataWrite(
    libraryId: libraryId,
    comicId: comicId,
    subjectId: subjectId,
    metadata: metadata,
    sequence: sequence,
    attempts: attempts ?? this.attempts,
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    nextRetryAt: identical(nextRetryAt, _unset)
        ? this.nextRetryAt
        : nextRetryAt as int?,
    failure: failure ?? this.failure,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'libraryId': libraryId,
    'comicId': comicId,
    'subjectId': subjectId,
    'metadata': metadata.toJson(),
    'sequence': sequence,
    'attempts': attempts,
    'lastAttemptAt': lastAttemptAt,
    'nextRetryAt': nextRetryAt,
    'failure': failure.name,
    'errorMessage': errorMessage,
  };
}

class _RemoteComicSnapshot {
  const _RemoteComicSnapshot({
    required this.title,
    required this.author,
    required this.description,
    required this.tags,
    required this.cover,
    required this.chapters,
    this.chaptersInspected = true,
    required this.chapterImages,
    required this.metadataChapters,
    required this.rootImages,
    required this.bangumiSubjectId,
    required this.metadataFilePresent,
    required this.metadataScrapeStatus,
    required this.metadataScraperVersion,
    required this.metadataScrapeAttemptedAt,
    required this.metadataScrapeRetryAt,
    required this.metadataScrapeError,
    this.archive,
    this.work,
  });

  final String title;
  final String author;
  final String description;
  final List<String> tags;
  final String cover;
  final Map<String, String> chapters;
  final bool chaptersInspected;
  final Map<String, List<String>> chapterImages;
  final Map<String, ComicChapter> metadataChapters;
  final List<RemoteLibraryEntry> rootImages;
  final int? bangumiSubjectId;
  final bool metadataFilePresent;
  final String metadataScrapeStatus;
  final String metadataScraperVersion;
  final int? metadataScrapeAttemptedAt;
  final int? metadataScrapeRetryAt;
  final String? metadataScrapeError;
  final RemoteArchiveComic? archive;
  final RemoteComicWork? work;

  factory _RemoteComicSnapshot.fromJson(
    Map<String, dynamic> json, {
    RemoteComicWork? retainedWork,
    RemoteArchiveComic? retainedArchive,
  }) {
    final chapters = json['chapters'];
    final chapterImages = json['chapterImages'] as Map?;
    final metadataChapters = json['metadataChapters'];
    final rootImages = json['rootImages'];
    final metadataFilePresent = json['metadataFilePresent'] == true;
    return _RemoteComicSnapshot(
      title: json['title'] as String,
      work:
          retainedWork ??
          (json['work'] is Map
              ? RemoteComicWork.fromJson(
                  Map<String, dynamic>.from(json['work'] as Map),
                )
              : null),
      archive:
          retainedArchive ??
          (json['archive'] is Map
              ? RemoteArchiveComic.fromJson(
                  Map<String, dynamic>.from(json['archive'] as Map),
                )
              : null),
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      cover: json['cover'] as String? ?? '',
      chaptersInspected: json['chaptersInspected'] != false,
      chapterImages: {
        if (chapterImages != null)
          for (final entry in chapterImages.entries)
            entry.key as String: List<String>.from(entry.value),
      },
      chapters: chapters is Map
          ? chapters.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      metadataChapters: metadataChapters is Map
          ? metadataChapters.map(
              (key, value) => MapEntry(
                key.toString(),
                ComicChapter.fromJson(Map<String, dynamic>.from(value as Map)),
              ),
            )
          : const {},
      rootImages: rootImages is List
          ? rootImages
                .whereType<Map>()
                .map(
                  (entry) => RemoteLibraryEntry(
                    name: entry['name'] as String,
                    isDirectory: false,
                    eTag: entry['eTag'] as String?,
                    modifiedAt: entry['modifiedAt'] as int?,
                  ),
                )
                .toList()
          : const [],
      bangumiSubjectId: json['bangumiSubjectId'] as int?,
      metadataFilePresent: metadataFilePresent,
      metadataScrapeStatus:
          json['metadataScrapeStatus'] as String? ??
          (metadataFilePresent ? 'notNeeded' : 'pending'),
      metadataScraperVersion: json['metadataScraperVersion'] as String? ?? '',
      metadataScrapeAttemptedAt: json['metadataScrapeAttemptedAt'] as int?,
      metadataScrapeRetryAt: json['metadataScrapeRetryAt'] as int?,
      metadataScrapeError: json['metadataScrapeError'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': remoteLibrarySnapshotFormatVersion,
    if (archive != null) 'archive': archive!.toJson(),
    if (work != null) 'work': work!.toJson(),
    'title': title,
    'author': author,
    'description': description,
    'tags': tags,
    'cover': cover,
    'chapters': chapters,
    'chaptersInspected': chaptersInspected,
    'chapterImages': chapterImages,
    'metadataChapters': metadataChapters.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'bangumiSubjectId': bangumiSubjectId,
    'metadataFilePresent': metadataFilePresent,
    'metadataScrapeStatus': metadataScrapeStatus,
    'metadataScraperVersion': metadataScraperVersion,
    'metadataScrapeAttemptedAt': metadataScrapeAttemptedAt,
    'metadataScrapeRetryAt': metadataScrapeRetryAt,
    'metadataScrapeError': metadataScrapeError,
    'rootImages': [
      for (final entry in rootImages)
        {
          'name': entry.name,
          'eTag': entry.eTag,
          'modifiedAt': entry.modifiedAt,
        },
    ],
  };

  int? get pageCount {
    if (work != null) return null;
    if (archive != null) return archive!.pageCount;
    if (!chaptersInspected) return null;
    return rootImages.length +
        chapterImages.values.fold<int>(
          0,
          (total, images) => total + images.length,
        );
  }

  Map<String, List<String>> get detailTags => {
    if (author.trim().isNotEmpty) '作者': [author],
    if (tags.isNotEmpty) '标签': tags,
  };
}
