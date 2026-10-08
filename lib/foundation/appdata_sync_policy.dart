/// Setting roots that stay on this device unless an explicit opt-in policy
/// enables their synchronization.
// Bangumi account credentials sync with bindings; pending retries remain in
// implicitData and are therefore outside this settings policy.
const appdataDefaultDisabledSyncFields = <String>{
  'proxy',
  'authorizationRequired',
  'customImageProcessing',
  'webdav',
  'webdavAutoSync',
  'webdavSyncMode',
  'webdavSyncDirection',
  'webdavSyncTiming',
  'webdavSyncIntervalMinutes',
  'webdavSyncPending',
  'webdavSyncLastAttempt',
  'webdavBaselineTarget',
  'webdavLastSyncedRemoteFile',
  'webdavLastSyncedRemoteVersion',
  'webdavLastSyncedRemoteEtag',
  'webdavProxyEnabled',
  'backupWebdav',
  'backupWebdavPath',
  'backupWebdavSyncEnabled',
  'webdavComicLibrary',
  'webdavComicLibraryPath',
  'webdavComicLibraryAutoSync',
  'webdavComicLibrarySyncIntervalMinutes',
  'webdavComicLibrarySyncEnabled',
  'disableSyncFields',
  'deviceId',
  'deviceSpecificSettings',
  'lastSyncTime',
};

const appdataArchiveSyncFields = {'backupWebdav', 'backupWebdavPath'};

const appdataComicLibrarySyncFields = {
  'webdavComicLibrary',
  'webdavComicLibraryPath',
  'webdavComicLibraryAutoSync',
  'webdavComicLibrarySyncIntervalMinutes',
};

const appdataObsoleteSyncSetting = 'readLaterFolder';

/// The concrete record domains used by the sync document.
///
/// Keep this list aligned with record producers across appdata, favorites,
/// history, and sync.
const appdataSyncDomains = <String>{
  'setting',
  'search',
  'cookies',
  'source',
  'sourceSession',
  'folder',
  'favorite',
  'favoriteRole',
  'history',
  'historyChapter',
  'imageFavorite',
};

/// User-facing sync scope groups and their concrete record domains.
const appdataSyncDomainGroups = <String, Set<String>>{
  'settings': {'setting'},
  'favorites': {'folder', 'favorite', 'favoriteRole'},
  'reading': {'history', 'historyChapter'},
  'images': {'imageFavorite'},
  'search': {'search'},
  'sourceScripts': {'source'},
  'loginStatus': {'cookies', 'sourceSession'},
};

const appdataSyncExcludedDomainsKey = 'syncExcludedDomains';

/// Normalizes exclusions so one disabled member excludes its whole UI group.
Set<String> normalizeAppDataSyncExcludedDomains(Iterable<String> domains) {
  final normalized = <String>{};
  for (final domain in domains) {
    if (!appdataSyncDomains.contains(domain)) {
      throw ArgumentError.value(domain, 'domains', 'Unknown sync domain');
    }
    normalized.add(domain);
  }
  for (final group in appdataSyncDomainGroups.values) {
    if (group.any(normalized.contains)) normalized.addAll(group);
  }
  return normalized;
}

/// Returns valid domain exclusions saved in local-only implicit data.
Set<String> getAppDataSyncExcludedDomains(Map<String, dynamic> implicitData) {
  final value = implicitData[appdataSyncExcludedDomainsKey];
  if (value is! List) return {};
  return normalizeAppDataSyncExcludedDomains(
    value.whereType<String>().where(appdataSyncDomains.contains),
  );
}

/// Whether a concrete record domain is currently included in sync scope.
bool isAppDataSyncDomainEnabled(
  Map<String, dynamic> implicitData,
  String domain,
) {
  if (!appdataSyncDomains.contains(domain)) return false;
  final excluded = implicitData[appdataSyncExcludedDomainsKey];
  if (excluded is! List) return true;
  for (final group in appdataSyncDomainGroups.values) {
    if (!group.contains(domain)) continue;
    for (final item in excluded) {
      if (item is String && group.contains(item)) return false;
    }
    return true;
  }
  return false;
}

/// Resolves a UI group name to its concrete domains.
Set<String> appdataSyncDomainsForGroup(String group) =>
    appdataSyncDomainGroups[group] ?? const {};

/// Whether any concrete domain in a UI group remains enabled.
bool isAppDataSyncGroupEnabled(
  Map<String, dynamic> implicitData,
  String group,
) {
  final domains = appdataSyncDomainsForGroup(group);
  return domains.isNotEmpty &&
      domains.any((domain) => isAppDataSyncDomainEnabled(implicitData, domain));
}

/// Returns roots that this device's settings policy excludes from sync.
Set<String> getDisabledAppDataSyncFields(Map<String, dynamic> settings) {
  final disabled = <String>{
    ...appdataDefaultDisabledSyncFields,
    appdataObsoleteSyncSetting,
    'readingFolder',
  };
  if (settings['backupWebdavSyncEnabled'] == true) {
    disabled.removeAll(appdataArchiveSyncFields);
  }
  if (settings['webdavComicLibrarySyncEnabled'] == true) {
    disabled.removeAll(appdataComicLibrarySyncFields);
  }
  final custom = settings['disableSyncFields'];
  if (custom is String) {
    disabled.addAll(
      custom
          .split(',')
          .map((field) => field.trim())
          .where((field) => field.isNotEmpty),
    );
  }
  return disabled;
}
