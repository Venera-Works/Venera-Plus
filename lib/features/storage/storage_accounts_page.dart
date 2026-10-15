import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'token_import.dart';

class StorageAccountsPage extends StatefulWidget {
  StorageAccountsPage({super.key, RemoteStorageAccounts? accounts})
    : accounts = accounts ?? RemoteStorageAccounts.instance;
  final RemoteStorageAccounts accounts;
  @override
  State<StorageAccountsPage> createState() => _StorageAccountsPageState();
}

class _StorageAccountsPageState extends State<StorageAccountsPage> {
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
    final result = await showDialog<StorageAccount>(
      context: context,
      builder: (_) => _StorageAccountDialog(initial: initial),
    );
    if (result == null) return;
    var saved = await widget.accounts.save(result);
    final store = widget.accounts.storeFor(saved.id);
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
      widget.accounts.release(store);
    }
    await widget.accounts.updateStatus(saved);
    if (mounted) setState(() {});
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
            subtitle: Text(
              account.statusMessage ??
                  '${account.driver} · ${account.status.name}',
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
  final TextEditingController _token = TextEditingController();
  late Map<String, dynamic> _authorization = {
    ...?widget.initial?.authorization,
  };
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
  late final TextEditingController _appId = TextEditingController(
    text: _tokenValue('app_id', 'AppID'),
  );
  late final TextEditingController _signKey = TextEditingController(
    text: _tokenValue('sign_key', 'SignKey'),
  );
  late String _driver = widget.initial?.backend == StorageBackend.webdav
      ? 'WebDAV'
      : widget.initial?.driver ?? 'BaiduNetdisk';
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _token.dispose();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _accessToken.dispose();
    _refreshToken.dispose();
    _appId.dispose();
    _signKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webdav = _driver == 'WebDAV';
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
                    (item) => DropdownMenuItem(value: item, child: Text(item)),
                  )
                  .toList(),
              onChanged: widget.initial == null
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
              if (_driver == 'QuarkOpen') ...[
                TextField(
                  controller: _appId,
                  decoration: InputDecoration(labelText: 'AppID'.tl),
                ),
                TextField(
                  controller: _signKey,
                  decoration: InputDecoration(labelText: 'SignKey'.tl),
                ),
                Text(
                  'Quark requires AppID and SignKey before it can connect.'.tl,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
              ExpansionTile(
                title: Text('Import token JSON or callback'.tl),
                children: [
                  TextField(
                    controller: _token,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: 'Token JSON or callback'.tl,
                      hintText: 'Paste the token JSON from api.oplist.org'.tl,
                    ),
                  ),
                  TextButton(onPressed: _importToken, child: Text('Import'.tl)),
                ],
              ),
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
          onPressed: () {
            try {
              if (!webdav) {
                final clientId =
                    _authorization['ClientID'] ?? _authorization['client_id'];
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
                  throw const FormatException('Refresh Token is required');
                }
                if (_driver == '115 Open' && _accessToken.text.trim().isEmpty) {
                  throw const FormatException('Access Token is required');
                }
                if (_driver == 'QuarkOpen' &&
                    (_appId.text.trim().isEmpty ||
                        _signKey.text.trim().isEmpty)) {
                  throw const FormatException(
                    'Quark requires AppID and SignKey before it can connect.',
                  );
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
                      appId: _driver == 'QuarkOpen' ? _appId.text : null,
                      signKey: _driver == 'QuarkOpen' ? _signKey.text : null,
                      authorization: _authorization,
                    );
              Navigator.pop(
                context,
                StorageAccount(
                  id: widget.initial?.id ?? '',
                  backend: webdav
                      ? StorageBackend.webdav
                      : StorageBackend.openlist,
                  driver: webdav ? widget.initial?.driver ?? 'webdav' : _driver,
                  name: _name.text.trim().isEmpty ? _driver : _name.text.trim(),
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

  void _importToken() {
    try {
      final authorization = parseOpenListAuthorization(
        _token.text,
        driver: _driver,
      );
      setState(() {
        _authorization = authorization;
        _accessToken.text =
            authorization['access_token'] as String? ??
            authorization['AccessToken'] as String? ??
            '';
        _refreshToken.text =
            authorization['refresh_token'] as String? ??
            authorization['RefreshToken'] as String? ??
            '';
        _appId.text = authorization['app_id'] as String? ?? '';
        _signKey.text = authorization['sign_key'] as String? ?? '';
        _token.clear();
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  String _tokenValue(String primary, String alternate) =>
      widget.initial?.authorization[primary] as String? ??
      widget.initial?.authorization[alternate] as String? ??
      '';
}
