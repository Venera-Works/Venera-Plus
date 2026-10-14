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
          title: "Comic Libraries".tl,
          subtitle:
              "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                  .tl,
          callback: () async {
            context.to(() => const RemoteLibrarySettingsPage());
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
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Storage and Sync".tl)),
        SettingPartTitle(title: "Storage".tl, icon: Icons.storage),
        CallbackSetting(
          title: 'Cloud Storage Accounts'.tl,
          subtitle: 'Manage WebDAV and OpenList cloud accounts.'.tl,
          actionTitle: 'Open'.tl,
          callback: () => context.to(() => StorageAccountsPage()),
        ).toSliver(),
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
  if (sync.isSyncing) {
    context.showMessage(message: 'Sync is currently in progress'.tl);
    return;
  }
  await showPopUpWidget(context, const _WebdavSetting());
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";
  DataSyncMode syncMode = DataSyncMode.realtime;
  int syncInterval = 30;
  bool initialUpload = true;
  late final WebDavConnectionControllers _connectionControllers;
  late final TextEditingController fieldsController;

  bool isTesting = false;
  StorageAccount? remoteAccount;
  String remoteDirectory = '/VeneraPlus/';

  @override
  void initState() {
    super.initState();
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.length == 3 && configs.whereType<String>().length == 3) {
      url = configs[0];
      user = configs[1];
      pass = configs[2];
      syncMode = DataSync.mode;
    }
    syncInterval = DataSync.intervalMinutes;
    _connectionControllers = WebDavConnectionControllers(
      url: url,
      user: user,
      password: pass,
      remotePath: '/',
    );
    fieldsController = TextEditingController(text: disableSync);
    final raw = appdata.settings['syncRemoteLocation'];
    if (raw is Map) {
      final location = RemoteLocation.fromJson(raw);
      remoteAccount = RemoteStorageAccounts.instance.account(
        location.accountId,
      );
      remoteDirectory = location.directory;
      syncMode = DataSync.mode;
    }
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    fieldsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Data Sync".tl,
      body: AbsorbPointer(
        absorbing: isTesting,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: remoteAccount?.id,
                decoration: InputDecoration(
                  labelText: 'Cloud Storage Account'.tl,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('WebDAV (legacy)'),
                  ),
                  for (final account in RemoteStorageAccounts.instance.accounts)
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.name),
                    ),
                ],
                onChanged: (value) => setState(
                  () => remoteAccount = value == null
                      ? null
                      : RemoteStorageAccounts.instance.account(value),
                ),
              ),
              if (remoteAccount != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Remote Directory'.tl),
                  subtitle: Text(remoteDirectory),
                  onTap: () async {
                    final accounts = RemoteStorageAccounts.instance;
                    final store = accounts.storeFor(remoteAccount!.id);
                    final selected = await Navigator.of(context)
                        .push<List<String>>(
                          MaterialPageRoute(
                            builder: (_) => RemoteDirectoryPicker(
                              store: store,
                              disposeStore: true,
                              onDisposeStore: accounts.release,
                            ),
                          ),
                        );
                    if (selected?.isNotEmpty == true) {
                      setState(() => remoteDirectory = selected!.single);
                    }
                  },
                ),
              if (remoteAccount != null) const SizedBox(height: 8),
              if (remoteAccount == null)
                WebDavConnectionFields(
                  controllers: _connectionControllers,
                  remotePathHint: '/',
                  showRemotePath: false,
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
                  syncMode == DataSyncMode.manual
                      ? 'Sync only when you choose upload or download.'.tl
                      : 'Once saved, the app will automatically sync data according to the schedule.'
                            .tl,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('data-sync-encryption-notice'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.tertiaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Sync data is compressed but not encrypted.'.tl,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
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
                    final url = _connectionControllers.url.text.trim();
                    final user = _connectionControllers.user.text;
                    final pass = _connectionControllers.password.text;
                    final clear =
                        url.isEmpty &&
                        user.trim().isEmpty &&
                        pass.trim().isEmpty;
                    if (!mounted) return;
                    final testResult = await DataSync().configure(
                      config: remoteAccount == null && !clear
                          ? [url, user, pass]
                          : [],
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

  BackupConfig get currentConfig => BackupConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: '/',
  );

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    Res<bool> result;
    final account = remoteAccount;
    if (account == null) {
      result = await ComicBackupManager.testConnection(currentConfig);
    } else {
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
  const _BackupWebdavSetting();

  @override
  State<_BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends State<_BackupWebdavSetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool syncEnabled = false;
  bool isTesting = false;
  StorageAccount? remoteAccount;
  String remoteDirectory = '/venera_backup/';

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
    final raw = appdata.settings['backupRemoteLocation'];
    if (raw is Map) {
      final location = RemoteLocation.fromJson(raw);
      remoteAccount = RemoteStorageAccounts.instance.account(
        location.accountId,
      );
      remoteDirectory = location.directory;
    }
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
            DropdownButtonFormField<String?>(
              initialValue: remoteAccount?.id,
              decoration: InputDecoration(
                labelText: 'Cloud Storage Account'.tl,
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('WebDAV (legacy)'),
                ),
                for (final account in RemoteStorageAccounts.instance.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: Text(account.name),
                  ),
              ],
              onChanged: (value) => setState(
                () => remoteAccount = value == null
                    ? null
                    : RemoteStorageAccounts.instance.account(value),
              ),
            ),
            if (remoteAccount != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Remote Directory'.tl),
                subtitle: Text(remoteDirectory),
                onTap: () async {
                  final accounts = RemoteStorageAccounts.instance;
                  final store = accounts.storeFor(remoteAccount!.id);
                  final selected = await Navigator.of(context)
                      .push<List<String>>(
                        MaterialPageRoute(
                          builder: (_) => RemoteDirectoryPicker(
                            store: store,
                            disposeStore: true,
                            onDisposeStore: accounts.release,
                          ),
                        ),
                      );
                  if (selected?.isNotEmpty == true) {
                    setState(() => remoteDirectory = selected!.single);
                  }
                },
              ),
            if (remoteAccount == null)
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
    Res<bool> result;
    final account = remoteAccount;
    if (account == null) {
      result = await ComicBackupManager.testConnection(currentConfig);
    } else {
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
    final config = currentConfig;
    if (!config.isValid && config.user.trim().isEmpty && config.pass.isEmpty) {
      appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
      appdata.settings.remove('backupRemoteLocation');
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
      appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
      appdata.settings.remove('backupRemoteLocation');
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
    }
  }
}
