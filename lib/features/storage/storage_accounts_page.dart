import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'token_import.dart';
import 'openlist_login.dart';
import 'quark_login.dart';

enum StorageAccountPurpose { library, sync, archive }

Future<StorageAccount?> showStorageAccountEditor(
  BuildContext context, {
  StorageAccount? initial,
  RemoteStorageAccounts? accounts,
}) async {
  final storage = accounts ?? RemoteStorageAccounts.instance;
  final result = await showDialog<StorageAccount>(
    context: context,
    builder: (_) => _StorageAccountDialog(initial: initial),
  );
  if (result == null) return null;
  var saved = await storage.save(result);
  if (saved.statusMessage != null) return saved;
  final store = storage.storeFor(saved.id);
  try {
    await store.test();
    saved = saved.copyWith(
      status: StorageAuthorizationStatus.valid,
      clearStatusMessage: true,
    );
  } on RemoteStorageException catch (error) {
    saved = saved.copyWith(
      status: error.isAuthorizationFailure
          ? StorageAuthorizationStatus.invalid
          : StorageAuthorizationStatus.unknown,
      statusMessage: error.message,
    );
  } finally {
    storage.release(store);
  }
  await storage.updateStatus(saved);
  return saved;
}

class StorageAccountsPage extends StatefulWidget {
  StorageAccountsPage({
    super.key,
    RemoteStorageAccounts? accounts,
    this.selectPurposeOnAdd = false,
  }) : accounts = accounts ?? RemoteStorageAccounts.instance;
  final RemoteStorageAccounts accounts;
  final bool selectPurposeOnAdd;
  @override
  State<StorageAccountsPage> createState() => _StorageAccountsPageState();
}

class _StorageAccountsPageState extends State<StorageAccountsPage> {
  String _usage(StorageAccount account) {
    final libraries = widget.accounts.libraries
        .where((library) => library.accountId == account.id)
        .length;
    final uses = <String>[
      if (libraries > 0)
        '@count comic libraries'.tlParams({'count': libraries}),
      for (final (key, title) in [
        ('syncRemoteLocation', 'App Data Sync'),
        ('backupRemoteLocation', 'Comic Archive Backup'),
      ])
        if (appdata.settings[key] is Map &&
            appdata.settings[key]['accountId'] == account.id)
          title.tl,
    ];
    return uses.isEmpty ? 'Not in use'.tl : uses.join(' · ');
  }

  Future<void> _test(StorageAccount account) async {
    var result = account;
    final store = widget.accounts.storeFor(account.id);
    try {
      await store.test();
      result = account.copyWith(
        status: StorageAuthorizationStatus.valid,
        clearStatusMessage: true,
      );
    } on RemoteStorageException catch (error) {
      result = account.copyWith(
        status: error.isAuthorizationFailure
            ? StorageAuthorizationStatus.invalid
            : StorageAuthorizationStatus.unknown,
        statusMessage: error.message,
      );
    } finally {
      widget.accounts.release(store);
    }
    await widget.accounts.updateStatus(result);
    if (mounted) setState(() {});
  }

  Future<void> _edit([StorageAccount? initial]) async {
    final saved = await showStorageAccountEditor(
      context,
      initial: initial,
      accounts: widget.accounts,
    );
    if (mounted) setState(() {});
    if (!mounted ||
        initial != null ||
        saved == null ||
        saved.status != StorageAuthorizationStatus.valid ||
        !widget.selectPurposeOnAdd) {
      return;
    }
    final purpose = await showDialog<StorageAccountPurpose>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Use this account for'.tl),
        children: [
          for (final (value, label) in [
            (StorageAccountPurpose.library, 'Online Comic Libraries'),
            (StorageAccountPurpose.sync, 'App Data Sync'),
            (StorageAccountPurpose.archive, 'Comic Archive Backup'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text(label.tl),
            ),
        ],
      ),
    );
    if (mounted && purpose != null) Navigator.pop(context, (saved, purpose));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Cloud Storage Accounts'.tl)),
    floatingActionButton: FloatingActionButton(
      onPressed: _edit,
      child: const Icon(Icons.add),
    ),
    body: ListView(
      children: [
        for (final account in widget.accounts.accounts)
          ListTile(
            title: Text(account.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.statusMessage ??
                      '${account.driver.tl} · ${switch (account.status) {
                        StorageAuthorizationStatus.valid => 'Connected'.tl,
                        StorageAuthorizationStatus.invalid => 'Authorization invalid'.tl,
                        StorageAuthorizationStatus.unknown => 'Connection not verified'.tl,
                      }}',
                ),
                Text(_usage(account)),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await widget.accounts.remove(account.id);
                if (mounted) setState(() {});
              },
            ),
            leading: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Test connection'.tl,
              onPressed: () => _test(account),
            ),
            onTap: () => _edit(account),
          ),
      ],
    ),
  );
}

class _StorageAccountDialog extends StatefulWidget {
  const _StorageAccountDialog({this.initial});
  final StorageAccount? initial;
  @override
  State<_StorageAccountDialog> createState() => _StorageAccountDialogState();
}

class _StorageAccountDialogState extends State<_StorageAccountDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name,
  );
  late Map<String, dynamic> _authorization =
      widget.initial?.driver == 'QuarkOpen'
      ? {
          'root_folder_id':
              widget.initial?.authorization['root_folder_id'] ?? '0',
        }
      : {...?widget.initial?.authorization};
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.authorization['url'] as String?,
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial?.authorization['user'] as String?,
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.initial?.authorization['password'] as String?,
  );
  late final TextEditingController _accessToken = TextEditingController(
    text: _tokenValue('access_token', 'AccessToken'),
  );
  late final TextEditingController _refreshToken = TextEditingController(
    text: _tokenValue('refresh_token', 'RefreshToken'),
  );
  late final TextEditingController _cookie = TextEditingController(
    text: widget.initial?.authorization['cookie'] as String?,
  );
  late String _driver = widget.initial?.backend == StorageBackend.webdav
      ? 'WebDAV'
      : widget.initial?.driver == 'QuarkOpen'
      ? 'Quark'
      : widget.initial?.driver ?? 'BaiduNetdisk';
  String? _error;
  bool _loggingIn = false;
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _accessToken.dispose();
    _refreshToken.dispose();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webdav = _driver == 'WebDAV';
    final quark = _driver == 'Quark';
    final hasLogin = quark || openListLoginDrivers.containsKey(_driver);
    return AlertDialog(
      title: Text('Cloud Storage Account'.tl),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: 'Name'.tl),
            ),
            DropdownButtonFormField<String>(
              initialValue: _driver,
              decoration: InputDecoration(labelText: 'Provider'.tl),
              items: ['WebDAV', ...openListSupportedDrivers]
                  .map(
                    (item) =>
                        DropdownMenuItem(value: item, child: Text(item.tl)),
                  )
                  .toList(),
              onChanged: widget.initial == null && !_loggingIn
                  ? (value) {
                      if (value != null) setState(() => _driver = value);
                    }
                  : null,
            ),
            if (webdav) ...[
              TextField(
                controller: _url,
                decoration: InputDecoration(labelText: 'URL'.tl),
              ),
              TextField(
                controller: _user,
                decoration: InputDecoration(labelText: 'Username'.tl),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(labelText: 'Password'.tl),
              ),
            ] else ...[
              if (hasLogin) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _loggingIn ? null : _login,
                    icon: const Icon(Icons.login),
                    label: Text('Log in and authorize'.tl),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (quark)
                TextField(
                  controller: _cookie,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: 'Cookie'.tl),
                )
              else ...[
                if (_driver == '115 Open')
                  TextField(
                    controller: _accessToken,
                    decoration: InputDecoration(labelText: 'Access Token'.tl),
                  ),
                TextField(
                  controller: _refreshToken,
                  onChanged: _driver == '115 Open'
                      ? null
                      : (_) => _accessToken.clear(),
                  decoration: InputDecoration(labelText: 'Refresh Token'.tl),
                ),
                if (!hasLogin) ...[
                  Text(
                    'Use parameters provided by OpenList on the token page, then fill in the required tokens.'
                        .tl,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://api.oplist.org/'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: Text('Open OpenList token page'.tl),
                  ),
                ],
              ],
              if (_error != null)
                Text(
                  _error!.tl,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: _loggingIn
              ? null
              : () {
                  try {
                    if (quark) {
                      if (_cookie.text.trim().isEmpty) {
                        throw const FormatException('Cookie is required');
                      }
                    } else if (!webdav) {
                      final clientId =
                          _authorization['ClientID'] ??
                          _authorization['client_id'];
                      final clientSecret =
                          _authorization['ClientSecret'] ??
                          _authorization['client_secret'];
                      final uses123ClientCredentials =
                          _driver == '123 Open' &&
                          clientId is String &&
                          clientId.isNotEmpty &&
                          clientSecret is String &&
                          clientSecret.isNotEmpty;
                      if (_refreshToken.text.trim().isEmpty &&
                          !uses123ClientCredentials) {
                        throw const FormatException(
                          'Refresh Token is required',
                        );
                      }
                      if (_driver == '115 Open' &&
                          _accessToken.text.trim().isEmpty) {
                        throw const FormatException('Access Token is required');
                      }
                    }
                    final auth = webdav
                        ? <String, dynamic>{
                            'url': _url.text.trim(),
                            'user': _user.text.trim(),
                            'password': _password.text,
                          }
                        : buildOpenListAuthorization(
                            driver: _driver,
                            accessToken: _accessToken.text,
                            refreshToken: _refreshToken.text,
                            cookie: _cookie.text,
                            authorization: _authorization,
                          );
                    Navigator.pop(
                      context,
                      StorageAccount(
                        id: widget.initial?.id ?? '',
                        backend: webdav
                            ? StorageBackend.webdav
                            : StorageBackend.openlist,
                        driver: webdav
                            ? widget.initial?.driver ?? 'webdav'
                            : _driver,
                        name: _name.text.trim().isEmpty
                            ? _driver.tl
                            : _name.text.trim(),
                        authorization: auth,
                      ),
                    );
                  } on FormatException catch (error) {
                    setState(() => _error = error.message);
                  }
                },
          child: Text('Save'.tl),
        ),
      ],
    );
  }

  Future<void> _login() async {
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final authorization = _driver == 'Quark'
          ? await showQuarkLogin(context)
          : await showOpenListLogin(context, driver: _driver);
      if (mounted && authorization != null) {
        _applyAuthorization({..._authorization, ...authorization});
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  void _applyAuthorization(Map<String, dynamic> authorization) {
    setState(() {
      _authorization = authorization;
      _cookie.text = authorization['cookie'] as String? ?? '';
      _accessToken.text =
          authorization['access_token'] as String? ??
          authorization['AccessToken'] as String? ??
          '';
      _refreshToken.text =
          authorization['refresh_token'] as String? ??
          authorization['RefreshToken'] as String? ??
          '';
      _error = null;
    });
  }

  String _tokenValue(String primary, String alternate) =>
      widget.initial?.authorization[primary] as String? ??
      widget.initial?.authorization[alternate] as String? ??
      '';
}
