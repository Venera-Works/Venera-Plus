import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'google_drive_login.dart';
import 'token_import.dart';
import 'openlist_login.dart';
import 'quark_login.dart';

enum StorageAccountPurpose { library, sync, archive }

Future<StorageAccount?> showStorageAccountEditor(
  BuildContext context, {
  StorageAccount? initial,
  RemoteStorageAccounts? accounts,
  bool useRootNavigator = true,
}) async {
  final storage = accounts ?? RemoteStorageAccounts.instance;
  final page = initial == null
      ? _StorageProviderPage(accounts: storage)
      : _StorageAccountPage(
          initial: initial,
          accounts: storage,
          driver: initial.backend == StorageBackend.webdav
              ? 'WebDAV'
              : initial.driver == 'QuarkOpen'
              ? 'Quark'
              : initial.driver,
        );
  final result = useRootNavigator
      ? await Navigator.of(
          context,
          rootNavigator: true,
        ).push<StorageAccount>(AppPageRoute(builder: (_) => page))
      : await context.to<StorageAccount>(
          () => page,
          animatePreviousPage: false,
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
  final _testingIds = <String>{};

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
    if (_testingIds.contains(account.id)) return;
    setState(() => _testingIds.add(account.id));
    final accounts = widget.accounts;
    RemoteFileStore? store;
    try {
      StorageAccount result;
      try {
        store = accounts.storeFor(account.id);
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
      }
      await accounts.updateStatus(result);
    } finally {
      if (store != null) accounts.release(store);
      if (mounted) setState(() => _testingIds.remove(account.id));
    }
  }

  Future<void> _edit([StorageAccount? initial]) async {
    final saved = await showStorageAccountEditor(
      context,
      initial: initial,
      accounts: widget.accounts,
      useRootNavigator: false,
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
  Widget build(BuildContext context) {
    final accounts = widget.accounts.accounts;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: Appbar(title: Text('Cloud Storage Accounts'.tl)),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add Cloud Storage Account'.tl,
        heroTag: 'storage_accounts_fab',
        onPressed: _edit,
        child: const Icon(Icons.add),
      ),
      body: accounts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_outlined,
                      size: 40,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No cloud storage accounts'.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add an account to browse cloud comics, sync app data or back up archives.'
                          .tl,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                final testing = _testingIds.contains(account.id);
                final hasError =
                    account.statusMessage != null ||
                    account.status == StorageAuthorizationStatus.invalid;
                return ListTile(
                  title: Text(account.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.statusMessage?.tl ??
                            '${account.driver.tl} · ${switch (account.status) {
                              StorageAuthorizationStatus.valid => 'Connected'.tl,
                              StorageAuthorizationStatus.invalid => 'Authorization invalid'.tl,
                              StorageAuthorizationStatus.unknown => 'Connection not verified'.tl,
                            }}',
                        style: hasError ? TextStyle(color: colors.error) : null,
                      ),
                      Text(_usage(account)),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete'.tl,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: testing
                        ? null
                        : () => showConfirmDialog(
                            context: context,
                            title: 'Delete'.tl,
                            content: account.name,
                            confirmText: 'Delete',
                            btnColor: colors.error,
                            onConfirm: () async {
                              await widget.accounts.remove(account.id);
                              if (mounted) setState(() {});
                            },
                          ),
                  ),
                  leading: IconButton(
                    icon: testing
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    tooltip: (testing ? 'Testing…' : 'Test connection').tl,
                    onPressed: testing ? null : () => _test(account),
                  ),
                  onTap: testing ? null : () => _edit(account),
                );
              },
            ),
    );
  }
}

class _StorageProviderPage extends StatelessWidget {
  const _StorageProviderPage({required this.accounts});

  final RemoteStorageAccounts accounts;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text('Add Cloud Storage Account'.tl)),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            children: [
              for (final driver in [...openListSupportedDrivers, 'WebDAV'])
                ListTile(
                  title: Text(driver.tl),
                  subtitle: Text(switch (driver) {
                    'WebDAV' =>
                      'Connect with a server address, username and password.'
                          .tl,
                    'GoogleDrive' =>
                      'Connect with your own Google OAuth credentials.'.tl,
                    _ => 'Log in to authorize and save automatically.'.tl,
                  }),
                  trailing: const Icon(Icons.arrow_right),
                  onTap: () async {
                    final result = await context.to<StorageAccount>(
                      () => _StorageAccountPage(
                        accounts: accounts,
                        driver: driver,
                      ),
                      animatePreviousPage: false,
                    );
                    if (context.mounted && result != null) {
                      Navigator.pop(context, result);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _StorageAccountPage extends StatefulWidget {
  const _StorageAccountPage({
    this.initial,
    required this.accounts,
    required this.driver,
  });
  final StorageAccount? initial;
  final RemoteStorageAccounts accounts;
  final String driver;
  @override
  State<_StorageAccountPage> createState() => _StorageAccountPageState();
}

class _StorageAccountPageState extends State<_StorageAccountPage> {
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
  late final Map<String, dynamic> _googleCredentials =
      _isGoogleDrive && _authorization['use_online_api'] == false
      ? normalizeOpenListAuthorization(_authorization, driver: _driver)
      : const {};
  late final TextEditingController _clientId = TextEditingController(
    text: _googleCredentials['client_id'] as String?,
  );
  late final TextEditingController _clientSecret = TextEditingController(
    text: _googleCredentials['client_secret'] as String?,
  );
  late final TextEditingController _refreshToken = TextEditingController(
    text: _tokenValue('refresh_token', 'RefreshToken'),
  );
  late final TextEditingController _cookie = TextEditingController(
    text: widget.initial?.authorization['cookie'] as String?,
  );
  String get _driver => widget.driver;
  bool get _isGoogleDrive => _driver == 'GoogleDrive';
  bool get _hasProviderLogin =>
      _driver == 'Quark' || openListLoginDrivers.containsKey(_driver);
  bool get _autoSaveAfterLogin =>
      _isGoogleDrive || (widget.initial == null && _hasProviderLogin);
  String? _error;
  bool _loggingIn = false;
  CancelToken? _googleLogin;
  final _visibleSecrets = <TextEditingController>{};

  InputDecoration _fieldDecoration(String label, {Widget? suffixIcon}) =>
      InputDecoration(
        labelText: label.tl,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        suffixIcon: suffixIcon,
      );

  Widget _secretField(
    TextEditingController controller,
    String label, {
    bool readOnly = false,
    ValueChanged<String>? onChanged,
  }) {
    final visible = _visibleSecrets.contains(controller);
    return TextField(
      controller: controller,
      readOnly: readOnly,
      onChanged: onChanged,
      obscureText: !visible,
      autocorrect: false,
      enableSuggestions: false,
      decoration: _fieldDecoration(
        label,
        suffixIcon: IconButton(
          tooltip: (visible ? 'Hide' : 'Show').tl,
          icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() {
            if (visible) {
              _visibleSecrets.remove(controller);
            } else {
              _visibleSecrets.add(controller);
            }
          }),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _googleLogin?.cancel();
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _accessToken.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    _refreshToken.dispose();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webdav = _driver == 'WebDAV';
    final quark = _driver == 'Quark';
    return Scaffold(
      appBar: Appbar(
        title: Text(
          (widget.initial == null
                  ? 'Add @provider Account'
                  : 'Edit @provider Account')
              .tlParams({'provider': _driver.tl}),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _name,
                    readOnly: _isGoogleDrive && _loggingIn,
                    decoration: _fieldDecoration('Name'),
                  ),
                  const SizedBox(height: 16),
                  if (webdav) ...[
                    TextField(
                      controller: _url,
                      decoration: _fieldDecoration('URL'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _user,
                      decoration: _fieldDecoration('Username'),
                    ),
                    const SizedBox(height: 16),
                    _secretField(_password, 'Password'),
                  ] else ...[
                    if (_isGoogleDrive) ...[
                      TextField(
                        controller: _clientId,
                        readOnly: _loggingIn,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: _fieldDecoration('Client ID'),
                      ),
                      const SizedBox(height: 16),
                      _secretField(
                        _clientSecret,
                        'Client Secret',
                        readOnly: _loggingIn,
                      ),
                    ],
                    if (_hasProviderLogin) ...[
                      const SizedBox(height: 16),
                      if (_googleLogin != null) ...[
                        Text(
                          'Finish Google authorization in the browser, then return here.'
                              .tl,
                        ),
                        TextButton(
                          onPressed: () => _googleLogin?.cancel(),
                          child: Text('Cancel'.tl),
                        ),
                      ] else
                        OutlinedButton.icon(
                          style: actionButtonStyle,
                          onPressed: _loggingIn
                              ? null
                              : _isGoogleDrive
                              ? _loginGoogleDrive
                              : _login,
                          icon: const Icon(Icons.login),
                          label: Text('Log in and authorize'.tl),
                        ),
                      const SizedBox(height: 16),
                    ],
                    if (!_autoSaveAfterLogin) ...[
                      if (quark)
                        _secretField(_cookie, 'Cookie')
                      else ...[
                        if (_driver == '115 Open') ...[
                          _secretField(_accessToken, 'Access Token'),
                          const SizedBox(height: 16),
                        ],
                        _secretField(
                          _refreshToken,
                          'Refresh Token',
                          onChanged: _driver == '115 Open'
                              ? null
                              : (_) => _accessToken.clear(),
                        ),
                      ],
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!.tl,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (!_autoSaveAfterLogin) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: actionButtonStyle,
                        onPressed: _loggingIn ? null : _save,
                        child: Text('Save and test connection'.tl),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _save({String? refreshToken}) {
    final webdav = _driver == 'WebDAV';
    final quark = _driver == 'Quark';
    try {
      final name = _validatedName();
      if (quark) {
        if (_cookie.text.trim().isEmpty) {
          throw const FormatException('Cookie is required');
        }
      } else if (!webdav && !_isGoogleDrive) {
        final clientId =
            _authorization['ClientID'] ?? _authorization['client_id'];
        final clientSecret =
            _authorization['ClientSecret'] ?? _authorization['client_secret'];
        final uses123ClientCredentials =
            _driver == '123 Open' &&
            clientId is String &&
            clientId.isNotEmpty &&
            clientSecret is String &&
            clientSecret.isNotEmpty;
        if (_refreshToken.text.trim().isEmpty && !uses123ClientCredentials) {
          throw const FormatException('Refresh Token is required');
        }
        if (_driver == '115 Open' && _accessToken.text.trim().isEmpty) {
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
              refreshToken: refreshToken ?? _refreshToken.text,
              clientId: _isGoogleDrive ? _clientId.text : '',
              clientSecret: _isGoogleDrive ? _clientSecret.text : '',
              cookie: _cookie.text,
              authorization: _authorization,
            );
      Navigator.pop(
        context,
        StorageAccount(
          id: widget.initial?.id ?? '',
          backend: webdav ? StorageBackend.webdav : StorageBackend.openlist,
          driver: webdav ? widget.initial?.driver ?? 'webdav' : _driver,
          name: name,
          oauthCallbackUrl: widget.initial?.oauthCallbackUrl ?? '',
          authorization: auth,
        ),
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  String _validatedName() {
    final name = _name.text.trim().isEmpty ? _driver.tl : _name.text.trim();
    if (widget.accounts.isNameInUse(name, excludingId: widget.initial?.id)) {
      throw const FormatException('An account with this name already exists.');
    }
    return name;
  }

  Future<void> _loginGoogleDrive() async {
    try {
      _validatedName();
      final clientId = _clientId.text.trim();
      final clientSecret = _clientSecret.text.trim();
      if (clientId.isEmpty || clientSecret.isEmpty) {
        throw const FormatException('Client ID and Client Secret are required');
      }
      final callback = googleDriveCallbackUri(
        widget.initial?.oauthCallbackUrl ?? '',
      );
      final cancelToken = callback == googleDriveDefaultCallback
          ? null
          : CancelToken();
      setState(() {
        _error = null;
        _loggingIn = true;
        _googleLogin = cancelToken;
      });
      final String? refreshToken;
      if (cancelToken == null) {
        final authorization = await showOpenListLogin(
          context,
          driver: _driver,
          clientId: clientId,
          clientSecret: clientSecret,
        );
        refreshToken = authorization?['refresh_token'] as String?;
      } else {
        refreshToken = await authorizeGoogleDrive(
          callback: callback,
          clientId: clientId,
          clientSecret: clientSecret,
          cancelToken: cancelToken,
        );
      }
      if (mounted &&
          cancelToken?.isCancelled != true &&
          refreshToken != null &&
          ModalRoute.of(context)?.isCurrent == true) {
        _save(refreshToken: refreshToken);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException {
      if (mounted) {
        setState(
          () => _error = _googleLogin == null
              ? 'Unable to start authorization'
              : 'Unable to open the browser.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _googleLogin = null;
          _loggingIn = false;
        });
      }
    }
  }

  Future<void> _login() async {
    if (_autoSaveAfterLogin) {
      final name = _name.text.trim().isEmpty ? _driver.tl : _name.text.trim();
      if (widget.accounts.isNameInUse(name)) {
        setState(() => _error = 'An account with this name already exists.'.tl);
        return;
      }
    }
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
        if (_autoSaveAfterLogin) _save();
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
