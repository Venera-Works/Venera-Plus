import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'content_sources_page.dart';
import 'data_sync_schedule_fields.dart';
import 'setting_components.dart';

class SyncSettings extends StatefulWidget {
  const SyncSettings({super.key});

  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<SyncSettings> {
  final _storage = RemoteStorageAccounts.instance;
  final _sync = DataSync();

  Future<void> _manageAccounts() async {
    final result = await context.to<(StorageAccount, StorageAccountPurpose)>(
      () => StorageAccountsPage(selectPurposeOnAdd: true),
    );
    if (!mounted || result == null) return;
    final (account, purpose) = result;
    switch (purpose) {
      case StorageAccountPurpose.library:
        context.to(() => ContentSourcesPage(initialAccountId: account.id));
      case StorageAccountPurpose.sync:
        await showDataSyncSettings(context, initialAccount: account);
      case StorageAccountPurpose.archive:
        await showPopUpWidget(
          context,
          _BackupWebdavSetting(initialAccount: account),
        );
    }
  }

  String _locationSummary(String key) {
    final raw = appdata.settings[key];
    if (raw is! Map) return 'Not Configured'.tl;
    final location = RemoteLocation.fromJson(raw);
    final account = _storage.account(location.accountId);
    return '${account?.name ?? 'Account unavailable'.tl} · ${location.directory}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_storage, _sync, appdata.settings]),
      builder: (context, _) {
        final accounts = _storage.accounts;
        final rawBangumiUsername = appdata.settings['bangumiUsername'];
        final bangumiUsername = rawBangumiUsername is String
            ? rawBangumiUsername
            : '';
        final status = _sync.statusSnapshot;
        final mode = switch (DataSync.mode) {
          DataSyncMode.manual => 'Manual'.tl,
          DataSyncMode.realtime => 'Real-time'.tl,
          DataSyncMode.scheduled => 'Scheduled'.tl,
        };
        final syncStatus = status.isSyncing
            ? 'Syncing Data'.tl
            : status.lastError != null
            ? '${'Last sync failed'.tl}: ${status.lastError}'
            : status.lastSyncTime > 0
            ? '${'Last synced'.tl}: ${status.formattedLastSyncTime}'
            : 'Not synced yet'.tl;
        return SmoothCustomScrollView(
          slivers: [
            SliverAppbar(title: Text('Sync'.tl)),
            SettingPartTitle(
              title: 'Cloud Accounts'.tl,
              icon: Icons.cloud_outlined,
            ),
            ListTile(
              title: Text(
                '@count accounts'.tlParams({'count': accounts.length}),
              ),
              subtitle: Text(
                accounts.isEmpty
                    ? 'Add Cloud Storage Account'.tl
                    : accounts.map((account) => account.name).join(' · '),
              ),
              trailing: const Icon(Icons.arrow_right),
              onTap: _manageAccounts,
            ).toSliver(),
            SettingPartTitle(
              title: 'Cloud Services'.tl,
              icon: Icons.cloud_sync_outlined,
            ),
            ListTile(
              key: const Key('data-sync-entry'),
              title: Text('App Data Sync'.tl),
              subtitle: Text(
                '${_locationSummary('syncRemoteLocation')}'
                '${status.isConfigured ? '\n$mode · $syncStatus' : ''}',
              ),
              trailing: const Icon(Icons.arrow_right),
              onTap: () => showDataSyncSettings(context),
            ).toSliver(),
            ListTile(
              key: const Key('comic-backup-entry'),
              title: Text('Comic Archive Backup'.tl),
              subtitle: Text(_locationSummary('backupRemoteLocation')),
              trailing: const Icon(Icons.arrow_right),
              onTap: () async {
                await _storage.migrateLegacyWebDavLocations();
                if (context.mounted) {
                  await showPopUpWidget(context, const _BackupWebdavSetting());
                }
              },
            ).toSliver(),
            SettingPartTitle(
              title: 'Progress Tracking'.tl,
              icon: Icons.track_changes_outlined,
            ),
            CallbackSetting(
              key: const Key('bangumi-settings-entry'),
              title: 'Bangumi',
              subtitle: bangumiUsername.isEmpty
                  ? 'Not connected'.tl
                  : bangumiUsername,
              callback: () => showPopUpWidget(
                context,
                BangumiSettingsPage(
                  onConnectionChanged: () {
                    if (BangumiService().isConnected) {
                      unawaited(RemoteLibraryEngines.refreshAll());
                    }
                  },
                ),
              ),
              actionTitle: 'Set'.tl,
            ).toSliver(),
            SettingPartTitle(
              title: 'Local Backup'.tl,
              icon: Icons.save_alt_outlined,
            ),
            CallbackSetting(
              title: 'Export App Data'.tl,
              callback: () async {
                final controller = showLoadingDialog(context);
                final file = await exportAppData(false);
                await saveFile(filename: 'data.venera', file: file);
                controller.close();
              },
              actionTitle: 'Export'.tl,
            ).toSliver(),
            CallbackSetting(
              title: 'Import App Data'.tl,
              subtitle:
                  'This overwrites local app data. If import fails, already-applied changes are not rolled back.'
                      .tl,
              callback: () async {
                final controller = showLoadingDialog(context);
                final file = await selectFile(ext: ['venera', 'picadata']);
                if (file != null) {
                  final cacheFile = File(
                    FilePath.join(App.cachePath, 'import_data_temp'),
                  );
                  await file.saveTo(cacheFile.path);
                  try {
                    if (file.name.endsWith('picadata')) {
                      await importPicaData(cacheFile);
                    } else {
                      await importAppData(cacheFile);
                    }
                  } catch (e, s) {
                    Log.error('Import data', e.toString(), s);
                    if (context.mounted) {
                      context.showMessage(message: 'Failed to import data'.tl);
                    }
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
      },
    );
  }
}

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting({this.initialAccount});
  final StorageAccount? initialAccount;

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

Future<void> showDataSyncSettings(
  BuildContext context, {
  StorageAccount? initialAccount,
}) async {
  final sync = DataSync();
  if (sync.isSyncing) {
    context.showMessage(message: 'Sync is currently in progress'.tl);
    return;
  }
  await RemoteStorageAccounts.instance.migrateLegacyWebDavLocations();
  if (context.mounted) {
    await showPopUpWidget(
      context,
      _WebdavSetting(initialAccount: initialAccount),
    );
  }
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String disableSync = '';
  DataSyncMode syncMode = DataSyncMode.realtime;
  int syncInterval = 30;
  bool initialUpload = true;
  late final TextEditingController fieldsController;
  bool isTesting = false;
  StorageAccount? remoteAccount;
  String remoteDirectory = '/VeneraPlus/';

  @override
  void initState() {
    super.initState();
    disableSync = appdata.settings['disableSyncFields'] as String? ?? '';
    fieldsController = TextEditingController(text: disableSync);
    syncInterval = DataSync.intervalMinutes;
    final raw = appdata.settings['syncRemoteLocation'];
    if (raw is Map) {
      final location = RemoteLocation.fromJson(raw);
      remoteAccount = RemoteStorageAccounts.instance.account(
        location.accountId,
      );
      remoteDirectory = location.directory;
      syncMode = DataSync.mode;
    }
    if (widget.initialAccount != null) {
      remoteAccount = widget.initialAccount;
      remoteDirectory = '/VeneraPlus/';
    }
  }

  @override
  void dispose() {
    fieldsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "App Data Sync".tl,
      body: AbsorbPointer(
        absorbing: isTesting,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              RemoteLocationFields(
                accountId: remoteAccount?.id,
                directories: remoteAccount == null
                    ? const []
                    : [remoteDirectory],
                allowNone: true,
                onChanged: (account, directories) => setState(() {
                  remoteAccount = account;
                  remoteDirectory = directories.isEmpty
                      ? '/VeneraPlus/'
                      : directories.single;
                }),
              ),
              const SizedBox(height: 12),
              DataSyncScheduleFields(
                mode: syncMode,
                minutes: syncInterval,
                onModeChanged: (value) => setState(() => syncMode = value),
                onIntervalChanged: (value) =>
                    setState(() => syncInterval = value),
              ),
              if (syncMode != DataSyncMode.manual) ...[
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Upload local data first'.tl),
                  subtitle: Text(
                    'For the first automatic sync, choose whether to upload local data or download remote data.'
                        .tl,
                  ),
                  value: initialUpload,
                  onChanged: (value) => setState(() => initialUpload = value),
                ),
              ],
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Advanced field exclusions'.tl),
                children: [
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
                            builder: (_) => ContentDialog(
                              title: "Skip Setting Fields".tl,
                              content: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Column(
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
                            ),
                          );
                        },
                      ),
                    ),
                    controller: fieldsController,
                    onChanged: (value) => disableSync = value,
                  ),
                ],
              ),
              if (syncMode == DataSyncMode.manual)
                Container(
                  key: const Key('data-sync-mode-notice'),
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
                  child: Text(
                    'Sync only when you choose upload or download.'.tl,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: actionButtonStyle,
                      onPressed: isTesting ? null : testConnection,
                      child: ButtonLoadingContent(
                        isLoading: isTesting,
                        child: Text("Test Connection".tl),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: actionButtonStyle,
                  key: const Key('data-sync-save'),
                  onPressed: isTesting
                      ? null
                      : () async {
                          if (isTesting) return;
                          setState(() {
                            isTesting = true;
                          });
                          if (!mounted) return;
                          final testResult = await DataSync().configure(
                            config: const [],
                            excludedFields: disableSync,
                            syncMode: syncMode,
                            minutes: syncInterval,
                            initialUpload: initialUpload,
                            remoteLocation: remoteAccount == null
                                ? null
                                : RemoteLocation(
                                    accountId: remoteAccount!.id,
                                    directory: remoteDirectory,
                                  ),
                          );
                          if (!mounted) return;
                          setState(() => isTesting = false);
                          if (testResult.error) {
                            context.showMessage(
                              message:
                                  testResult.errorMessage?.tl ??
                                  'Saved Failed'.tl,
                            );
                            context.showMessage(message: "Saved Failed".tl);
                          } else {
                            context.showMessage(message: "Saved".tl);
                            App.rootPop();
                          }
                        },
                  child: ButtonLoadingContent(
                    isLoading: isTesting,
                    child: Text("Save".tl),
                  ),
                ),
              ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  Future<void> testConnection() async {
    if (isTesting) return;
    final account = remoteAccount;
    if (account == null) {
      context.showMessage(message: 'Select an account'.tl);
      return;
    }
    setState(() => isTesting = true);
    Res<bool> result;
    final accounts = RemoteStorageAccounts.instance;
    final store = accounts.storeFor(account.id);
    try {
      await store.list(remoteDirectory);
      result = const Res(true);
    } catch (error) {
      result = Res.error(error.toString());
    } finally {
      accounts.release(store);
    }
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
  const _BackupWebdavSetting({this.initialAccount});
  final StorageAccount? initialAccount;

  @override
  State<_BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends State<_BackupWebdavSetting> {
  bool syncEnabled = false;
  bool isTesting = false;
  StorageAccount? remoteAccount;
  String remoteDirectory = '/venera_backup/';

  @override
  void initState() {
    super.initState();
    syncEnabled = appdata.settings['backupWebdavSyncEnabled'] == true;
    final location = BackupConfig.remoteLocation;
    if (location != null) {
      remoteAccount = RemoteStorageAccounts.instance.account(
        location.accountId,
      );
      remoteDirectory = location.directory;
    }
    if (widget.initialAccount != null) {
      remoteAccount = widget.initialAccount;
      remoteDirectory = '/venera_backup/';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Archive Backup".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            RemoteLocationFields(
              accountId: remoteAccount?.id,
              directories: remoteAccount == null ? const [] : [remoteDirectory],
              allowNone: true,
              onChanged: (account, directories) => setState(() {
                remoteAccount = account;
                remoteDirectory = directories.isEmpty
                    ? '/venera_backup/'
                    : directories.single;
              }),
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
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text('Browse Backed-up Comics'.tl),
              subtitle: Text('Use the saved backup location.'.tl),
              trailing: const Icon(Icons.arrow_right),
              enabled: BackupConfig.fromSettings().isValid,
              onTap: BackupConfig.fromSettings().isValid
                  ? () => context.to(() => const ComicArchivePage())
                  : null,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Sync archive config".tl),
              subtitle: Text(
                "Sync the archive account and directory with app data.".tl,
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
                  child: OutlinedButton(
                    style: actionButtonStyle,
                    onPressed: isTesting ? null : testConnection,
                    child: ButtonLoadingContent(
                      isLoading: isTesting,
                      child: Text("Test Connection".tl),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: actionButtonStyle,
                    onPressed: isTesting ? null : save,
                    child: ButtonLoadingContent(
                      isLoading: isTesting,
                      child: Text("Save".tl),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  Future<void> testConnection() async {
    if (isTesting) return;
    final account = remoteAccount;
    if (account == null) {
      context.showMessage(message: 'Select an account'.tl);
      return;
    }
    setState(() => isTesting = true);
    Res<bool> result;
    final accounts = RemoteStorageAccounts.instance;
    final store = accounts.storeFor(account.id);
    try {
      await store.list(remoteDirectory);
      result = const Res(true);
    } catch (error) {
      result = Res.error(error.toString());
    } finally {
      accounts.release(store);
    }
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
    await ComicBackupManager.cancelActiveTasks();
    final account = remoteAccount;
    if (account != null) {
      final location = RemoteLocation(
        accountId: account.id,
        directory: remoteDirectory,
      );
      setState(() => isTesting = true);
      final accounts = RemoteStorageAccounts.instance;
      final store = accounts.storeFor(location.accountId);
      try {
        await store.list(location.directory);
      } catch (error) {
        if (mounted) {
          setState(() => isTesting = false);
          context.showMessage(message: error.toString());
        }
        return;
      } finally {
        accounts.release(store);
      }
      appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
      appdata.settings['backupRemoteLocation'] = location.toJson();
      await appdata.saveData(false);
      if (!mounted) return;
      context.showMessage(message: 'Saved'.tl);
      App.rootPop();
      return;
    }
    appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
    appdata.settings.remove('backupRemoteLocation');
    appdata.settings['backupWebdav'] = const [];
    await appdata.saveData(false);
    if (!mounted) return;
    context.showMessage(message: 'Saved'.tl);
    App.rootPop();
  }
}
