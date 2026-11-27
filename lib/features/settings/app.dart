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
  bool _importing = false;

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

  Future<void> _importData() async {
    if (_importing) return;
    _importing = true;
    Directory? workspace;
    LoadingDialogController? progress;
    var reload = false;
    String? message;
    try {
      final source = await selectFile(ext: ['venera', 'picadata']);
      if (source == null || !mounted) return;
      final pica = source.name.toLowerCase().endsWith('.picadata');
      var confirmed = false;
      await showConfirmDialog(
        context: context,
        title: 'Import App Data'.tl,
        content: [
          source.name,
          if (pica)
            'This backup merges local favorites and image favorites and may update matching reading history.'
                .tl
          else
            'This backup can replace app settings, reading history, local favorites, login cookies and comic sources.'
                .tl,
        ].join('\n\n'),
        confirmText: 'Import',
        btnColor: context.colorScheme.error,
        onConfirm: () => confirmed = true,
      );
      if (!confirmed || !mounted) return;
      progress = showLoadingDialog(
        context,
        allowCancel: false,
        barrierDismissible: false,
      );
      workspace = await Directory(App.cachePath).createTemp('import-data-');
      final copy = File(FilePath.join(workspace.path, 'backup'));
      await source.saveTo(copy.path);
      reload = true;
      if (pica) {
        await importPicaData(copy);
      } else {
        await importAppData(copy);
      }
      message = 'Import complete'.tl;
    } catch (error, stack) {
      Log.error('Import data', error.toString(), stack);
      message = 'Failed to import data'.tl;
    } finally {
      await workspace?.deleteIgnoreError(recursive: true);
      progress?.close();
      _importing = false;
      if (message != null && mounted) context.showMessage(message: message);
      if (reload) App.forceRebuild();
    }
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
              callback: _importData,
              actionTitle: 'Import'.tl,
            ).toSliver(),
          ],
        );
      },
    );
  }
}

Widget _cloudSettingsNotice(BuildContext context, String message, {Key? key}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return Container(
    key: key,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: colors.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 20, color: colors.onPrimaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
      ],
    ),
  );
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

  RemoteLocation? get _location {
    final account = remoteAccount;
    return account == null
        ? null
        : RemoteLocation(
            accountId: account.id,
            directory: remoteDirectory,
          ).normalized();
  }

  bool get _needsInitialTransfer {
    final location = _location;
    if (location == null || syncMode == DataSyncMode.manual) return false;
    final raw = appdata.settings['syncRemoteLocation'];
    final previous = raw is Map ? RemoteLocation.fromJson(raw) : null;
    return DataSync.mode == DataSyncMode.manual ||
        previous?.accountId != location.accountId ||
        previous?.directory != location.directory;
  }

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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
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
              if (_needsInitialTransfer) ...[
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
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      suffixIcon: IconButton(
                        tooltip: 'Help'.tl,
                        icon: const Icon(Icons.help_outline),
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
                                            tooltip: 'Open in Browser'.tl,
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
                _cloudSettingsNotice(
                  context,
                  'Sync only when you choose upload or download.'.tl,
                  key: const Key('data-sync-mode-notice'),
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
                  onPressed: isTesting ? null : _save,
                  child: ButtonLoadingContent(
                    isLoading: isTesting,
                    child: Text("Save".tl),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (isTesting) return;
    setState(() => isTesting = true);
    try {
      final location = _location;
      final needsInitialTransfer = _needsInitialTransfer;
      if (needsInitialTransfer && !initialUpload) {
        var confirmed = false;
        await showConfirmDialog(
          context: context,
          title: 'Restore from Cloud'.tl,
          content: [
            'Sync target: @target'.tlParams({
              'target': '${remoteAccount!.name} · ${location!.directory}',
            }),
            'Restoring the cloud snapshot will overwrite local app data, including reading history and local favorites.'
                .tl,
          ].join('\n\n'),
          btnColor: context.colorScheme.error,
          onConfirm: () => confirmed = true,
        );
        if (!confirmed || !mounted) return;
      }
      final sync = DataSync();
      if (sync.isSyncing) {
        context.showMessage(message: 'Sync is currently in progress'.tl);
        return;
      }
      if (location != null &&
          syncMode != DataSyncMode.manual &&
          !needsInitialTransfer &&
          sync.hasConfiguration) {
        await _saveAutomaticOptions(sync);
      } else {
        final result = await sync.configure(
          config: const [],
          excludedFields: disableSync,
          syncMode: syncMode,
          minutes: syncInterval,
          initialUpload: initialUpload,
          remoteLocation: location,
        );
        if (!mounted) return;
        if (result.error) {
          context.showMessage(
            message: result.errorMessage?.tl ?? 'Saved Failed'.tl,
          );
          return;
        }
      }
      if (!mounted) return;
      context.showMessage(message: 'Saved'.tl);
      Navigator.of(context, rootNavigator: true).pop();
    } catch (error, stack) {
      Log.error('Data Sync', error.toString(), stack);
      if (mounted) context.showMessage(message: 'Saved Failed'.tl);
    } finally {
      if (mounted) setState(() => isTesting = false);
    }
  }

  Future<void> _saveAutomaticOptions(DataSync sync) async {
    final previousMode = DataSync.mode;
    final implicit = appdata.implicitData;
    // 重设现有定时任务时，从保存时刻起等待完整的间隔。
    if (syncMode == DataSyncMode.scheduled) {
      implicit['webdavSyncLastAttempt'] = DateTime.now().millisecondsSinceEpoch;
    } else if (previousMode == DataSyncMode.scheduled) {
      // 同步检查先取消定时器。在手动模式下调用时不会发起传输。
      implicit['webdavSyncMode'] = DataSyncMode.manual.name;
      sync.checkForAutomaticSync();
    }
    implicit['webdavSyncMode'] = syncMode.name;
    implicit['webdavAutoSync'] = true;
    implicit['webdavSyncIntervalMinutes'] = syncInterval;
    appdata.settings['disableSyncFields'] = disableSync;
    if (syncMode == DataSyncMode.scheduled) {
      sync.checkForAutomaticSync();
    }
    await appdata.writeImplicitData();
    await appdata.saveData(false);
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
    final canBrowseBackups = BackupConfig.fromSettings().isValid;
    return PopUpWidgetScaffold(
      title: "Comic Archive Backup".tl,
      body: AbsorbPointer(
        absorbing: isTesting,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RemoteLocationFields(
                accountId: remoteAccount?.id,
                directories: remoteAccount == null
                    ? const []
                    : [remoteDirectory],
                allowNone: true,
                onChanged: (account, directories) => setState(() {
                  remoteAccount = account;
                  remoteDirectory = directories.isEmpty
                      ? '/venera_backup/'
                      : directories.single;
                }),
              ),
              const SizedBox(height: 16),
              _cloudSettingsNotice(
                context,
                'This is only used for CBZ archive backup and restore.'.tl,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.archive_outlined),
                title: Text('Browse Backed-up Comics'.tl),
                subtitle: Text('Use the saved backup location.'.tl),
                trailing: const Icon(Icons.arrow_right),
                enabled: canBrowseBackups,
                onTap: canBrowseBackups
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
              OutlinedButton(
                style: actionButtonStyle,
                onPressed: isTesting ? null : testConnection,
                child: ButtonLoadingContent(
                  isLoading: isTesting,
                  child: Text("Test Connection".tl),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: actionButtonStyle,
                onPressed: isTesting ? null : save,
                child: ButtonLoadingContent(
                  isLoading: isTesting,
                  child: Text("Save".tl),
                ),
              ),
            ],
          ),
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

  Future<void> save() async {
    if (isTesting) return;
    setState(() => isTesting = true);
    final account = remoteAccount;
    final location = account == null
        ? null
        : RemoteLocation(accountId: account.id, directory: remoteDirectory);
    try {
      await ComicBackupManager.cancelActiveTasks();
      if (!mounted) return;
      if (location != null) {
        final accounts = RemoteStorageAccounts.instance;
        final store = accounts.storeFor(location.accountId);
        try {
          await store.list(location.directory);
        } finally {
          accounts.release(store);
        }
      }
      appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
      if (location == null) {
        appdata.settings.remove('backupRemoteLocation');
        appdata.settings['backupWebdav'] = const [];
      } else {
        appdata.settings['backupRemoteLocation'] = location.toJson();
      }
      await appdata.saveData(false);
      if (!mounted) return;
      context.showMessage(message: 'Saved'.tl);
      App.rootPop();
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString().tl);
    } finally {
      if (mounted) setState(() => isTesting = false);
    }
  }
}
