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
