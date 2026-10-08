import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/data_sync_schedule_fields.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/features/settings/webdav_connection_fields.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

String _formatDataSyncTimestamp(int timestamp) {
  if (timestamp <= 0) return 'Not synced yet'.tl;
  final value = DateTime.fromMillisecondsSinceEpoch(timestamp);
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

String _dataSyncTriggerLabel(String? trigger) {
  final label = switch (trigger) {
    'Manual sync' => 'Manual sync',
    'Local changes' => 'Local changes',
    'Scheduled sync' => 'Scheduled sync',
    'Startup check' => 'Startup check',
    'Resume check' => 'Resume check',
    'Remote check' => 'Remote check',
    'Retry' => 'Retry',
    _ => null,
  };
  if (label != null) return label.tl;
  if (trigger == null || trigger.isEmpty) return 'Not synced yet'.tl;
  return 'Other sync trigger: @trigger'.tlParams({'trigger': trigger});
}

String _changedSyncRecordSummary(Map<String, int> counts) {
  if (counts.isEmpty) return 'No captured record changes'.tl;
  final entries = counts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((entry) => '${entry.key}: ${entry.value}').join(', ');
}

class _DataSyncStatusPanel extends StatelessWidget {
  const _DataSyncStatusPanel({
    required this.status,
    required this.isBusy,
    required this.onSyncNow,
    required this.onImportLegacyChanges,
  });

  final DataSyncStatusSnapshot status;
  final bool isBusy;
  final VoidCallback onSyncNow;
  final VoidCallback onImportLegacyChanges;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('data-sync-status-summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sync status'.tl, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'Last trigger: @trigger'.tlParams({
              'trigger': _dataSyncTriggerLabel(status.lastTrigger),
            }),
          ),
          Text(
            'Last successful sync: @time'.tlParams({
              'time': _formatDataSyncTimestamp(status.lastSuccessTime),
            }),
          ),
          Text(
            'Pending publication records: @count'.tlParams({
              'count': status.pendingChangeCount,
            }),
          ),
          Text(
            'Sync Conflict (@count pending)'.tlParams({
              'count': status.conflictCount,
            }),
          ),
          Text(
            'Changed records: @counts'.tlParams({
              'counts': _changedSyncRecordSummary(status.changedRecordCounts),
            }),
          ),
          Text(
            'Uploaded: @bytes bytes in @objects objects'.tlParams({
              'bytes': status.uploadedBytes,
              'objects': status.uploadedObjects,
            }),
          ),
          Text(
            'Downloaded: @bytes bytes in @objects objects'.tlParams({
              'bytes': status.downloadedBytes,
              'objects': status.downloadedObjects,
            }),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('data-sync-now'),
              onPressed: isBusy ? null : onSyncNow,
              child: Text('Sync now'.tl),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('data-sync-review-conflicts'),
              onPressed: isBusy ? null : () => showSyncConflictDialog(context),
              child: Text('Resolve conflicts'.tl),
            ),
          ),
          if (status.legacyChangesDetected)
            Text(
              'Older protocol changes were detected. Import only after all devices are upgraded and old clients have stopped writing; legacy files will be retained.'
                  .tl,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('data-sync-import-legacy'),
              onPressed: isBusy ? null : onImportLegacyChanges,
              child: Text('Import legacy changes'.tl),
            ),
          ),
        ],
      ),
    );
  }
}

class SourcesAndServicesSettings extends StatefulWidget {
  const SourcesAndServicesSettings({super.key});

  @override
  State<SourcesAndServicesSettings> createState() =>
      _SourcesAndServicesSettingsState();
}

class _SourcesAndServicesSettingsState
    extends State<SourcesAndServicesSettings> {
  @override
  Widget build(BuildContext context) {
    final rawBangumiUsername = appdata.settings['bangumiUsername'];
    final bangumiUsername = rawBangumiUsername is String
        ? rawBangumiUsername
        : '';
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Sources and Services".tl)),
        SettingPartTitle(
          title: "Comic Sources".tl,
          icon: Icons.source_outlined,
        ),
        CallbackSetting(
          title: "Manage Comic Sources".tl,
          actionTitle: "Open".tl,
          callback: () {
            context.to(() => const ComicSourcePage());
          },
        ).toSliver(),
        SettingPartTitle(
          title: "Online Services".tl,
          icon: Icons.cloud_outlined,
        ),
        CallbackSetting(
          title: "WebDAV Comic Library".tl,
          subtitle:
              "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                  .tl,
          callback: () async {
            showPopUpWidget(context, const _WebDavComicLibrarySetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          key: const Key('bangumi-settings-entry'),
          title: 'Bangumi',
          subtitle: bangumiUsername.isEmpty
              ? 'Not connected'.tl
              : bangumiUsername,
          callback: () async {
            await showPopUpWidget(
              context,
              BangumiSettingsPage(
                onConnectionChanged: () {
                  if (BangumiService().isConnected) {
                    unawaited(WebDavLibrarySource.synchronize());
                  }
                  if (mounted) setState(() {});
                },
              ),
            );
            if (mounted) setState(() {});
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
      ],
    );
  }
}

class StorageAndSyncSettings extends StatefulWidget {
  const StorageAndSyncSettings({super.key});

  @override
  State<StorageAndSyncSettings> createState() => _StorageAndSyncSettingsState();
}

class _StorageAndSyncSettingsState extends State<StorageAndSyncSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Storage and Sync".tl)),
        SettingPartTitle(title: "Storage".tl, icon: Icons.storage),
        ListTile(
          title: Text("Storage Path for local comics".tl),
          subtitle: Text(LocalManager().path, softWrap: false),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: LocalManager().path));
              context.showMessage(message: "Path copied to clipboard".tl);
            },
          ),
        ).toSliver(),
        CallbackSetting(
          title: "Set New Storage Path".tl,
          actionTitle: "Set".tl,
          callback: () async {
            String? result;
            if (App.isAndroid) {
              var picker = DirectoryPicker();
              result = (await picker.pickDirectory())?.path;
            } else if (App.isIOS) {
              result = await selectDirectoryIOS();
            } else {
              result = await selectDirectory();
            }
            if (result == null) return;
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            var res = await LocalManager().setNewPath(result);
            loadingDialog.close();
            if (res != null) {
              context.showMessage(message: res);
            } else {
              context.showMessage(message: "Path set successfully".tl);
              setState(() {});
            }
          },
        ).toSliver(),
        ListTile(
          title: Text("Cache Size".tl),
          subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
        ).toSliver(),
        CallbackSetting(
          title: "Clear Cache".tl,
          actionTitle: "Clear".tl,
          callback: () async {
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            await CacheManager().clear();
            loadingDialog.close();
            context.showMessage(message: "Cache cleared".tl);
            setState(() {});
          },
        ).toSliver(),
        CallbackSetting(
          title: "Cache Limit".tl,
          subtitle: "${appdata.settings['cacheSize']} MB",
          callback: () {
            showInputDialog(
              context: context,
              title: "Set Cache Limit".tl,
              hintText: "Size in MB".tl,
              inputValidator: RegExp(r"^\d+$"),
              onConfirm: (value) {
                appdata.settings['cacheSize'] = int.parse(value);
                appdata.saveData();
                setState(() {});
                CacheManager().setLimitSize(appdata.settings['cacheSize']);
                return null;
              },
            );
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        SettingPartTitle(title: "Downloads & Sync".tl, icon: Icons.sync),
        SliderSetting(
          title: "Download Threads".tl,
          settingsIndex: 'downloadThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
        CallbackSetting(
          key: const Key('data-sync-entry'),
          title: "Data Sync".tl,
          callback: () => showDataSyncSettings(context),
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Comic Archive Backup".tl,
          subtitle: "This is only used for CBZ archive backup and restore.".tl,
          callback: () async {
            showPopUpWidget(context, const _BackupWebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        SettingPartTitle(
          title: "Backup & Restore".tl,
          icon: Icons.import_export,
        ),
        CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await exportAppData(false);
            await saveFile(filename: "data.venera", file: file);
            controller.close();
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await selectFile(ext: ['venera', 'picadata']);
            if (file != null) {
              var cacheFile = File(
                FilePath.join(App.cachePath, "import_data_temp"),
              );
              await file.saveTo(cacheFile.path);
              try {
                if (file.name.endsWith('picadata')) {
                  await importPicaData(cacheFile);
                } else {
                  await importAppData(cacheFile);
                }
              } catch (e, s) {
                Log.error("Import data", e.toString(), s);
                context.showMessage(message: "Failed to import data".tl);
              } finally {
                cacheFile.deleteIgnoreError();
                App.forceRebuild();
              }
            }
            controller.close();
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
      ],
    );
  }
}

class PrivacyAndSecuritySettings extends StatefulWidget {
  const PrivacyAndSecuritySettings({super.key});

  @override
  State<PrivacyAndSecuritySettings> createState() =>
      _PrivacyAndSecuritySettingsState();
}

class _PrivacyAndSecuritySettingsState
    extends State<PrivacyAndSecuritySettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Privacy and Security".tl)),
        if (!App.isLinux) ...[
          SettingPartTitle(title: "Security".tl, icon: Icons.security),
          SwitchSetting(
            title: "Authorization Required".tl,
            settingKey: "authorizationRequired",
            onChanged: () async {
              var current = appdata.settings['authorizationRequired'];
              if (current) {
                final auth = LocalAuthentication();
                final bool canAuthenticateWithBiometrics =
                    await auth.canCheckBiometrics;
                final bool canAuthenticate =
                    canAuthenticateWithBiometrics ||
                    await auth.isDeviceSupported();
                if (!canAuthenticate) {
                  context.showMessage(message: "Biometrics not supported".tl);
                  setState(() {
                    appdata.settings['authorizationRequired'] = false;
                  });
                  appdata.saveData();
                  return;
                }
              }
            },
          ).toSliver(),
        ],
        SettingPartTitle(title: "History".tl, icon: Icons.history),
        SliderSetting(
          title: "Auto Clear History".tl,
          settingsIndex: "historyRetentionDays",
          interval: 7,
          min: 0,
          max: 182,
          onChanged: () {
            final retentionDays =
                (appdata.settings['historyRetentionDays'] as num).round();
            HistoryManager().clearExpiredHistory(retentionDays);
          },
        ).toSliver(),
      ],
    );
  }
}

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

Future<void> showDataSyncSettings(BuildContext context) async {
  final sync = DataSync();
  if (!sync.beginInteraction()) {
    context.showMessage(message: 'Sync is currently in progress'.tl);
    return;
  }
  try {
    await showPopUpWidget(context, const _WebdavSetting());
  } finally {
    sync.endInteraction();
  }
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";
  Set<String> excludedDomains = {};

  bool _deviceNameEdited = false;

  SyncDirection syncDirection = SyncDirection.bidirectional;
  SyncTiming syncTiming = SyncTiming.realtime;
  int syncInterval = 30;
  late final TextEditingController urlController;
  late final TextEditingController userController;
  late final TextEditingController passController;
  late final TextEditingController fieldsController;
  late final TextEditingController deviceNameController;

  bool isTesting = false;

  @override
  void initState() {
    super.initState();
    var deviceName = '';
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    excludedDomains = getAppDataSyncExcludedDomains(appdata.implicitData);
    final savedDeviceName = appdata.implicitData['webdavSyncDeviceName'];
    if (savedDeviceName is String && savedDeviceName.trim().isNotEmpty) {
      try {
        deviceName = normalizeSyncDeviceName(savedDeviceName);
      } on FormatException {
        deviceName = '';
      }
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.length == 3 && configs.whereType<String>().length == 3) {
      url = configs[0];
      user = configs[1];
      pass = configs[2];
      syncDirection = DataSync.direction;
      syncTiming = DataSync.timing;
    }
    syncInterval = DataSync.intervalMinutes;
    urlController = TextEditingController(text: url);
    userController = TextEditingController(text: user);
    passController = TextEditingController(text: pass);
    deviceNameController = TextEditingController(text: deviceName);
    if (deviceName.isEmpty) {
      unawaited(_autofillDeviceName());
    }
    fieldsController = TextEditingController(text: disableSync);
  }

  @override
  void dispose() {
    urlController.dispose();
    userController.dispose();
    passController.dispose();
    deviceNameController.dispose();
    fieldsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: AbsorbPointer(
        absorbing: isTesting,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "URL",
                  hintText: "A valid WebDav directory URL".tl,
                  border: OutlineInputBorder(),
                ),
                controller: urlController,
                onChanged: (value) => url = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Username".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: userController,
                onChanged: (value) => user = value,
              ),
              const SizedBox(height: 12),
              TextField(
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Password".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: passController,
                onChanged: (value) => pass = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Device name".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: deviceNameController,
                onChanged: (_) {
                  _deviceNameEdited = true;
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Advanced field exclusions'.tl),
              ),
              const SizedBox(height: 6),
              TextField(
                decoration: InputDecoration(
                  labelText: "Skip Setting Fields (Optional)".tl,
                  hintText: "field0, field1, field2, ...",
                  hintStyle: TextStyle(color: Theme.of(context).hintColor),
                  border: OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(Icons.help_outline),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text("Skip Setting Fields".tl),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "When sync data, skip certain setting fields, which means these won't be uploaded / override."
                                    .tl,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      "See source code for available fields."
                                          .tl,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      icon: const Icon(Icons.open_in_new),
                                      onPressed: () {
                                        launchUrlString(
                                          "https://github.com/Venera-Works/Venera-Plus/blob/main/lib/foundation/appdata.dart#L335",
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                controller: fieldsController,
                onChanged: (value) => disableSync = value,
              ),
              const SizedBox(height: 12),
              DataSyncScheduleFields(
                direction: syncDirection,
                timing: syncTiming,
                minutes: syncInterval,
                excludedDomains: excludedDomains,
                onExcludedDomainsChanged: (value) =>
                    setState(() => excludedDomains = value),
                onDirectionChanged: (value) =>
                    setState(() => syncDirection = value),
                onTimingChanged: (value) => setState(() => syncTiming = value),
                onIntervalChanged: (value) =>
                    setState(() => syncInterval = value),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('data-sync-protocol-notice'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            syncDirection == SyncDirection.bidirectional
                                ? 'Multi-device sync merges existing local and remote data losslessly rather than overwriting.'
                                      .tl
                                : (syncDirection == SyncDirection.uploadOnly
                                      ? 'Upload-only mode will propagate local changes to remote without importing remote data.'
                                            .tl
                                      : 'Download-only mode will import remote changes without uploading local data.'
                                            .tl),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                          ),
                        ),
                      ],
                    ),
                    if (syncTiming != SyncTiming.manual) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Once saved, the app will automatically sync data according to the schedule.'
                            .tl,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.tertiaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sync data is compressed but not encrypted.'.tl,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'The new sync protocol requires all devices to be upgraded. Stop writes from older clients before syncing.'
                          .tl,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: DataSync(),
                builder: (context, _) => _DataSyncStatusPanel(
                  status: DataSync().statusSnapshot,
                  isBusy: isTesting,
                  onSyncNow: _syncNowFromSettings,
                  onImportLegacyChanges: _importLegacyChanges,
                ),
              ),
              if (DataSync().statusSnapshot.isPartial) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Some synchronization data is unavailable. Other data can sync independently.'
                              .tl,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showSyncSourceIssuesDialog(
                          context,
                          issues: DataSync().statusSnapshot.sourceIssues,
                          onRepair: (issue, content) =>
                              DataSync().repairSourceIssue(
                                issue: issue,
                                replacementContent: content,
                              ),
                          onRetry: () => DataSync().syncNow(),
                          description:
                              'Some synchronization data is unavailable. Other data can sync independently.'
                                  .tl,
                        ),
                        child: Text('View Details'.tl),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      isLoading: isTesting,
                      onPressed: testConnection,
                      child: Text("Test Connection".tl),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: Button.filled(
                  isLoading: isTesting,
                  key: const Key('data-sync-save'),
                  onPressed: () async {
                    if (isTesting) return;
                    setState(() {
                      isTesting = true;
                    });
                    final clear =
                        url.trim().isEmpty &&
                        user.trim().isEmpty &&
                        pass.trim().isEmpty;
                    final String? resolvedDeviceName;
                    try {
                      resolvedDeviceName = clear
                          ? null
                          : await _resolveDeviceNameForSave();
                    } on FormatException {
                      if (!mounted) return;
                      setState(() => isTesting = false);
                      context.showMessage(
                        message: "Enter a valid device name".tl,
                      );
                      return;
                    }
                    if (!mounted) return;
                    final testResult = await DataSync().configure(
                      config: clear ? [] : [url.trim(), user, pass],
                      deviceName: resolvedDeviceName,
                      excludedFields: disableSync,
                      direction: syncDirection,
                      excludedDomains: excludedDomains,
                      timing: syncTiming,
                      minutes: syncInterval,
                    );
                    if (!mounted) return;
                    setState(() => isTesting = false);
                    if (testResult.error) {
                      context.showMessage(message: testResult.errorMessage!.tl);
                      context.showMessage(message: "Saved Failed".tl);
                    } else {
                      context.showMessage(message: "Saved".tl);
                      App.rootPop();
                    }
                  },
                  child: Text("Save".tl),
                ),
              ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  Future<void> _syncNowFromSettings() async {
    if (isTesting) return;
    setState(() => isTesting = true);
    try {
      final result = await DataSync().syncNow();
      if (!mounted) return;
      context.showMessage(
        message: result.error
            ? result.errorMessage?.tl ?? 'Sync failed'.tl
            : 'Sync completed'.tl,
      );
    } finally {
      if (mounted) setState(() => isTesting = false);
    }
  }

  Future<void> _importLegacyChanges() async {
    if (isTesting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Import legacy sync changes?'.tl),
        content: Text(
          'Confirm that all devices are upgraded and old clients have stopped writing. Legacy files will be retained.'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            key: const Key('data-sync-legacy-import-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Import legacy changes'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => isTesting = true);
    try {
      final result = await DataSync().importLegacyChanges();
      if (!mounted) return;
      context.showMessage(
        message: result.error
            ? result.errorMessage?.tl ?? 'Legacy import failed'.tl
            : (result.data
                      ? 'Legacy changes imported'
                      : 'No legacy changes found')
                  .tl,
      );
    } finally {
      if (mounted) setState(() => isTesting = false);
    }
  }

  Future<void> _autofillDeviceName() async {
    final name = await readSyncDeviceName();
    if (!mounted ||
        _deviceNameEdited ||
        deviceNameController.text.trim().isNotEmpty) {
      return;
    }
    deviceNameController.text = name;
  }

  Future<String> _resolveDeviceNameForSave() async {
    final current = deviceNameController.text;
    if (current.trim().isNotEmpty || _deviceNameEdited) {
      return normalizeSyncDeviceName(current);
    }

    final detected = await readSyncDeviceName();
    if (!mounted) return detected;
    final latest = deviceNameController.text;
    if (_deviceNameEdited) {
      final normalized = normalizeSyncDeviceName(latest);
      deviceNameController.text = normalized;
      return normalized;
    }
    final resolved = latest.trim().isEmpty ? detected : latest;
    final normalized = normalizeSyncDeviceName(resolved);
    deviceNameController.text = normalized;
    return normalized;
  }

  BackupConfig get currentConfig =>
      BackupConfig(url: url, user: user, pass: pass, remotePath: '/');

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }
}

class _BackupWebdavSetting extends StatefulWidget {
  const _BackupWebdavSetting();

  @override
  State<_BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends State<_BackupWebdavSetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool syncEnabled = false;
  bool isTesting = false;

  @override
  void initState() {
    super.initState();
    final config = BackupConfig.fromSettings();
    _connectionControllers = WebDavConnectionControllers(
      url: config.url,
      user: config.user,
      password: config.pass,
      remotePath: config.remotePath,
    );
    syncEnabled = appdata.settings['backupWebdavSyncEnabled'] == true;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Archive Backup".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            WebDavConnectionFields(
              controllers: _connectionControllers,
              remotePathHint: '/venera_backup/',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "This is only used for CBZ archive backup and restore."
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Sync archive config".tl),
              subtitle: Text(
                "Sync archive WebDAV URL, username, password and remote path with app data."
                    .tl,
              ),
              trailing: Switch(
                value: syncEnabled,
                onChanged: (v) {
                  setState(() {
                    syncEnabled = v;
                  });
                },
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting,
                    onPressed: save,
                    child: Text("Continue".tl),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  BackupConfig get currentConfig => BackupConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  Future<void> save() async {
    if (isTesting) return;
    appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
    final config = currentConfig;
    if (!config.isValid && config.user.trim().isEmpty && config.pass.isEmpty) {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(config);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      context.showMessage(message: "Saved Failed".tl);
    } else {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
    }
  }
}

class _WebDavComicLibrarySetting extends StatefulWidget {
  const _WebDavComicLibrarySetting();

  @override
  State<_WebDavComicLibrarySetting> createState() =>
      _WebDavComicLibrarySettingState();
}

class _WebDavComicLibrarySettingState
    extends State<_WebDavComicLibrarySetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool isTesting = false;
  bool isSyncing = false;
  late bool autoSyncEnabled;
  late int syncIntervalMinutes;
  late bool configSyncEnabled;

  @override
  void initState() {
    super.initState();
    final config = WebDavLibraryConfig.fromSettings();
    _connectionControllers = WebDavConnectionControllers(
      url: config.url,
      user: config.user,
      password: config.pass,
      remotePath: config.remotePath,
    );
    WebDavLibrarySource.updateSyncStatusFromCache();
    autoSyncEnabled =
        appdata.settings['webdavComicLibraryAutoSync'] as bool? ?? true;
    syncIntervalMinutes =
        (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
            ?.round() ??
        360;
    configSyncEnabled =
        appdata.settings['webdavComicLibrarySyncEnabled'] as bool? ?? false;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "WebDAV Comic Library".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            WebDavConnectionFields(
              controllers: _connectionControllers,
              remotePathHint: '/venera_comics/',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              key: const Key('webdav-comic-library-config-sync-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text('Sync comic library config'.tl),
              subtitle: Text(
                'Sync the WebDAV comic library URL, username, password, remote path, automatic updates and update interval. Credentials will be stored in remote sync storage.'
                    .tl,
              ),
              value: configSyncEnabled,
              onChanged: (value) {
                setState(() {
                  configSyncEnabled = value;
                });
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Automatic library updates'.tl),
              subtitle: Text(
                'Refresh the cached WebDAV library while the app is running.'
                    .tl,
              ),
              value: autoSyncEnabled,
              onChanged: (value) {
                setState(() {
                  autoSyncEnabled = value;
                });
              },
            ),
            if (autoSyncEnabled) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: syncIntervalMinutes,
                decoration: InputDecoration(
                  labelText: 'Update interval'.tl,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 15,
                    child: Text('Every 15 minutes'.tl),
                  ),
                  DropdownMenuItem(value: 60, child: Text('Every hour'.tl)),
                  DropdownMenuItem(value: 360, child: Text('Every 6 hours'.tl)),
                  DropdownMenuItem(value: 1440, child: Text('Every day'.tl)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      syncIntervalMinutes = value;
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            ValueListenableBuilder<WebDavLibrarySyncStatus>(
              valueListenable: WebDavLibrarySource.syncStatus,
              builder: (context, status, _) {
                final text = switch (status) {
                  WebDavLibrarySyncStatus(isSyncing: true, total: > 0) =>
                    'Updating WebDAV library: @current/@total'.tlParams({
                      'current': status.processed,
                      'total': status.total,
                    }),
                  WebDavLibrarySyncStatus(isSyncing: true) =>
                    'Updating WebDAV library'.tl,
                  WebDavLibrarySyncStatus(errorMessage: != null) =>
                    'Last sync failed'.tl,
                  WebDavLibrarySyncStatus(lastSuccessfulSync: > 0) =>
                    '${'Last synced'.tl}: '
                        '${status.formattedLastSuccessfulSync}',
                  _ => 'Not synced yet'.tl,
                };
                return Row(
                  children: [
                    Icon(
                      status.errorMessage == null
                          ? Icons.sync_outlined
                          : Icons.sync_problem_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(text)),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (WebDavLibraryConfig.fromSettings().isValid) ...[
              Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      isLoading: isSyncing,
                      onPressed: syncNow,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.sync, size: 18),
                          const SizedBox(width: 8),
                          Text('Sync now'.tl),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting && !isSyncing,
                    onPressed: save,
                    child: Text('Save and sync'.tl),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  WebDavLibraryConfig get currentConfig => WebDavLibraryConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() async {
    if (isTesting || isSyncing) return;
    setState(() {
      isTesting = true;
    });
    final result = await WebDavLibrarySource.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  Future<void> save() async {
    if (isTesting || isSyncing) return;
    if (!await _persistConfiguration()) return;
    final config = WebDavLibraryConfig.fromSettings();
    if (config.isValid) {
      unawaited(WebDavLibrarySource.synchronize(force: true));
    }
    if (!mounted) return;
    context.showMessage(message: 'Saved'.tl);
    App.rootPop();
  }

  Future<void> syncNow() async {
    if (isTesting || isSyncing) return;
    if (!await _persistConfiguration()) return;
    if (!WebDavLibraryConfig.fromSettings().isValid) return;
    setState(() {
      isSyncing = true;
    });
    final result = await WebDavLibrarySource.synchronize(force: true);
    if (!mounted) return;
    setState(() {
      isSyncing = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
    } else {
      context.showMessage(message: 'WebDAV library updated'.tl);
    }
  }

  Future<bool> _persistConfiguration() async {
    final config = currentConfig;
    Future<void> persist() async {
      appdata.settings['webdavComicLibraryAutoSync'] = autoSyncEnabled;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] =
          syncIntervalMinutes;
      appdata.settings['webdavComicLibrarySyncEnabled'] = configSyncEnabled;
      await WebDavLibraryConfig.saveToSettings(config);
    }

    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      await persist();
      await _refreshWebDavLibrarySource(enabled: false);
      return true;
    }
    setState(() {
      isTesting = true;
    });
    final result = await WebDavLibrarySource.testConnection(config);
    if (!mounted) return false;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      context.showMessage(message: "Saved Failed".tl);
      return false;
    }
    await persist();
    await _refreshWebDavLibrarySource(enabled: true);
    return true;
  }

  Future<void> _refreshWebDavLibrarySource({required bool enabled}) async {
    final manager = ComicSourceManager();
    manager.remove(WebDavLibrarySource.sourceKey);
    final pages = List<String>.from(appdata.settings['explore_pages']);
    pages.remove(WebDavLibrarySource.explorePageTitle);
    if (enabled) {
      manager.add(WebDavLibrarySource.create());
      pages.add(WebDavLibrarySource.explorePageTitle);
    }
    appdata.settings['explore_pages'] = pages;
    await appdata.saveData(false);
  }
}
