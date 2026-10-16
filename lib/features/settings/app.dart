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
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

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
                    unawaited(WebDavLibraryEngines.refreshAll());
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
  final _storage = RemoteStorageAccounts.instance;
  final _sync = DataSync();

  Future<void> _manageAccounts() async {
    final result = await Navigator.of(context)
        .push<(StorageAccount, StorageAccountPurpose)>(
          MaterialPageRoute(
            builder: (_) => StorageAccountsPage(selectPurposeOnAdd: true),
          ),
        );
    if (!mounted || result == null) return;
    final (account, purpose) = result;
    switch (purpose) {
      case StorageAccountPurpose.library:
        context.to(
          () => RemoteLibrarySettingsPage(initialAccountId: account.id),
        );
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

  Widget _group(List<Widget> children) => SliverList.list(children: children);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_storage, _sync, appdata.settings]),
      builder: (context, _) {
        final accounts = _storage.accounts;
        final libraries = _storage.libraries;
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
            SliverAppbar(title: Text('Storage and Sync'.tl)),
            SettingPartTitle(
              title: 'Cloud Storage Accounts'.tl,
              icon: Icons.cloud_outlined,
            ),
            _group([
              ListTile(
                title: Text(
                  '@count accounts'.tlParams({'count': accounts.length}),
                ),
                subtitle: Text(
                  accounts.isEmpty
                      ? 'Add Cloud Storage Account'.tl
                      : accounts.map((a) => a.name).join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _manageAccounts,
              ),
            ]),
            SettingPartTitle(
              title: 'Cloud Storage Uses'.tl,
              icon: Icons.folder_open_outlined,
            ),
            _group([
              ListTile(
                key: const Key('comic-libraries-entry'),
                title: Text('Online Comic Libraries'.tl),
                subtitle: Text(
                  '@count comic libraries'.tlParams({
                    'count': libraries.length,
                  }),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    context.to(() => const RemoteLibrarySettingsPage()),
              ),
              ListTile(
                key: const Key('data-sync-entry'),
                title: Text('App Data Sync'.tl),
                subtitle: Text(
                  '${_locationSummary('syncRemoteLocation')}'
                  '${status.isConfigured ? '\n$mode · $syncStatus' : ''}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDataSyncSettings(context),
              ),
              ListTile(
                key: const Key('comic-backup-entry'),
                title: Text('Comic Archive Backup'.tl),
                subtitle: Text(_locationSummary('backupRemoteLocation')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await _storage.migrateLegacyWebDavLocations();
                  if (context.mounted) {
                    await showPopUpWidget(
                      context,
                      const _BackupWebdavSetting(),
                    );
                  }
                },
              ),
            ]),
            SettingPartTitle(
              title: 'On This Device'.tl,
              icon: Icons.devices_outlined,
            ),
            _group([
              ListTile(
                title: Text('Local Storage and Downloads'.tl),
                subtitle: Text(
                  'Comic storage path, cache and download threads.'.tl,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.to(() => const _LocalStorageSettings()),
              ),
              ListTile(
                title: Text('App Data Import and Export'.tl),
                subtitle: Text('Save or restore a local app-data file.'.tl),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.to(() => const _AppDataTransferSettings()),
              ),
            ]),
          ],
        );
      },
    );
  }
}

class _LocalStorageSettings extends StatefulWidget {
  const _LocalStorageSettings();

  @override
  State<_LocalStorageSettings> createState() => _LocalStorageSettingsState();
}

class _LocalStorageSettingsState extends State<_LocalStorageSettings> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Local Storage and Downloads'.tl)),
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
        SliderSetting(
          title: "Download Threads".tl,
          settingsIndex: 'downloadThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
      ],
    ),
  );
}

class _AppDataTransferSettings extends StatelessWidget {
  const _AppDataTransferSettings();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('App Data Import and Export'.tl)),
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
          subtitle:
              "This overwrites local app data. If import fails, already-applied changes are not rolled back."
                  .tl,
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
    ),
  );
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
                            testResult.errorMessage?.tl ?? 'Saved Failed'.tl,
                      );
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
                    child: Text("Save".tl),
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
