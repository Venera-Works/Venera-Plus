import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:venera_plus/routing/webview.dart';

void main() {
  testWidgets('provider pages show matching fields and return without saving', (
    tester,
  ) async {
    final accounts = _Accounts();
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Add Cloud Storage Account'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);

    for (final (driver, fields) in [
      ('WebDAV', ['URL', 'Username', 'Password']),
      ('Quark', ['Cookie']),
      ('115 Open', ['Access Token', 'Refresh Token']),
      ('BaiduNetdisk', ['Refresh Token']),
      ('123 Open', ['Refresh Token']),
      ('Onedrive', ['Refresh Token']),
      ('GoogleDrive', ['Refresh Token']),
    ]) {
      final provider = find.widgetWithText(ListTile, driver);
      await tester.ensureVisible(provider);
      await tester.tap(provider);
      await tester.pumpAndSettle();
      expect(find.text('Add $driver Account'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(TextField), findsNWidgets(fields.length + 1));
      for (final label in fields) {
        expect(find.widgetWithText(TextField, label), findsOneWidget);
      }
      expect(
        find.widgetWithText(OutlinedButton, 'Log in and authorize'),
        driver == 'WebDAV' || driver == 'GoogleDrive'
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        find.text('Open OpenList token page'),
        driver == 'GoogleDrive' ? findsOneWidget : findsNothing,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Add Cloud Storage Account'), findsOneWidget);
      expect(accounts.saved, isNull);
    }

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Cloud Storage Accounts'), findsOneWidget);
    expect(accounts.saved, isNull);
    expect(accounts.rpc.testCalls, 0);
  });

  for (final size in [const Size(320, 640), const Size(1200, 800)]) {
    testWidgets('save stays above the keyboard at ${size.width}', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPadding);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      final accounts = _Accounts();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(size.width < 600 ? 1.3 : 1),
            ),
            child: child!,
          ),
          home: StorageAccountsPage(accounts: accounts),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      final provider = find.widgetWithText(ListTile, 'WebDAV');
      await tester.scrollUntilVisible(provider, 200);
      await tester.pumpAndSettle();
      await tester.tap(provider);
      await tester.pumpAndSettle();

      final save = find.widgetWithText(
        FilledButton,
        'Save and test connection',
      );
      final url = find.widgetWithText(TextField, 'URL');
      final password = find.widgetWithText(TextField, 'Password');
      expect(tester.widget<AppBar>(find.byType(AppBar)).actions, isNull);
      final originalSaveRect = tester.getRect(save);
      expect(originalSaveRect.height, greaterThanOrEqualTo(52));
      expect(originalSaveRect.width, tester.getRect(url).width);
      expect(originalSaveRect.left, tester.getRect(url).left);
      expect(originalSaveRect.bottom, closeTo(size.height - 24 - 16, 0.01));

      await tester.showKeyboard(password);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.ensureVisible(password);
      await tester.pumpAndSettle();

      final saveRect = tester.getRect(save);
      expect(saveRect.bottom, closeTo(size.height - 280 - 16, 0.01));
      expect(tester.getRect(password).bottom, lessThan(saveRect.top));
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('WebDAV selection saves the server credentials', (tester) async {
    final accounts = _Accounts();
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final provider = find.widgetWithText(ListTile, 'WebDAV');
    await tester.ensureVisible(provider);
    await tester.tap(provider);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'My WebDAV');
    await tester.enterText(
      find.widgetWithText(TextField, 'URL'),
      'https://example.com/dav/',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Username'),
      'reader',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      ' password ',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();

    expect(find.text('Cloud Storage Accounts'), findsOneWidget);
    expect(find.text('Add Cloud Storage Account'), findsNothing);
    expect(accounts.saved!.backend, StorageBackend.webdav);
    expect(accounts.saved!.driver, 'webdav');
    expect(accounts.saved!.authorization, {
      'url': 'https://example.com/dav/',
      'user': 'reader',
      'password': ' password ',
    });
    expect(accounts.rpc.testCalls, 1);
  });

  testWidgets('duplicate account names stay in the editor until renamed', (
    tester,
  ) async {
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: 'existing',
        backend: StorageBackend.openlist,
        driver: 'BaiduNetdisk',
        name: 'My Drive',
        authorization: {'refresh_token': 'existing'},
      );
    final previous = accounts.saved;
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      ' my DRIVE ',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'new',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(
      find.text('An account with this name already exists.'),
      findsOneWidget,
    );
    expect(find.text('Add BaiduNetdisk Account'), findsOneWidget);
    expect(accounts.saved, same(previous));
    expect(accounts.rpc.testCalls, 0);

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Other Drive',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(find.text('Add BaiduNetdisk Account'), findsNothing);
    expect(accounts.saved?.name, 'Other Drive');
    expect(accounts.rpc.testCalls, 1);
  });

  testWidgets('first connection can continue to a selected purpose', (
    tester,
  ) async {
    final accounts = _Accounts();
    (StorageAccount, StorageAccountPurpose)? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => selected = await Navigator.of(context)
                  .push<(StorageAccount, StorageAccountPurpose)>(
                    MaterialPageRoute(
                      builder: (_) => StorageAccountsPage(
                        accounts: accounts,
                        selectPurposeOnAdd: true,
                      ),
                    ),
                  ),
              child: const Text('Accounts'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(find.text('Use this account for'), findsOneWidget);
    await tester.tap(find.text('App Data Sync'));
    await tester.pumpAndSettle();
    expect(selected?.$1.id, 'new-account');
    expect(selected?.$2, StorageAccountPurpose.sync);
    expect(find.byType(StorageAccountsPage), findsNothing);
  });

  testWidgets('adding an account opens above a popup and returns to its form', (
    tester,
  ) async {
    final accounts = _Accounts();
    final name = TextEditingController(text: 'Unfinished library');
    addTearDown(name.dispose);
    StorageAccount? selected;
    var directories = <String>['/previous/'];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPopUpWidget(
                context,
                Scaffold(
                  body: StatefulBuilder(
                    builder: (context, setState) => Column(
                      children: [
                        TextField(controller: name),
                        RemoteLocationFields(
                          accounts: accounts,
                          accountId: selected?.id,
                          directories: directories,
                          onChanged: (account, paths) => setState(() {
                            selected = account;
                            directories = paths;
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Configure location'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Configure location'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Cloud Storage Account').last);
    await tester.pumpAndSettle();
    final pageWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byType(AppBar)).width, pageWidth);
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppBar)).width, pageWidth);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'New Drive');
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(selected?.name, 'New Drive');
    expect(find.text('New Drive'), findsOneWidget);
    expect(name.text, 'Unfinished library');
    expect(directories, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Cloud Storage Account').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Discarded account',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Add Cloud Storage Account'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(selected?.name, 'New Drive');
    expect(name.text, 'Unfinished library');
    expect(accounts.saved?.name, 'New Drive');
    expect(accounts.rpc.testCalls, 1);
  });

  testWidgets('Baidu login shows required tokens and validates them', (
    tester,
  ) async {
    final accounts = _Accounts();
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();

    expect(find.text('Refresh Token'), findsOneWidget);
    expect(find.text('Access Token'), findsNothing);
    expect(find.text('AppID'), findsNothing);
    expect(find.text('Log in and authorize'), findsOneWidget);
    expect(find.text('Open OpenList token page'), findsNothing);
    expect(find.text('Import token JSON or callback'), findsNothing);
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh Token is required'), findsOneWidget);
    expect(accounts.saved, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(accounts.saved!.authorization['refresh_token'], 'refresh');
    expect(accounts.saved!.authorization['use_online_api'], isTrue);
  });

  testWidgets('manual token edits replace old tokens and preserve settings', (
    tester,
  ) async {
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: 'baidu',
        backend: StorageBackend.openlist,
        driver: 'BaiduNetdisk',
        name: 'BaiduNetdisk',
        authorization: {
          'refresh_token': 'saved-refresh',
          'AccessToken': 'old-access',
          'root_folder_path': '/Comics',
        },
      );
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.text('BaiduNetdisk'));
    await tester.pumpAndSettle();
    final refresh = find.widgetWithText(TextField, 'Refresh Token');
    expect(tester.widget<TextField>(refresh).controller!.text, 'saved-refresh');
    await tester.ensureVisible(refresh);
    await tester.enterText(refresh, 'edited');
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();

    expect(accounts.saved!.authorization['refresh_token'], 'edited');
    expect(accounts.saved!.authorization['AccessToken'], isNull);
    expect(accounts.saved!.authorization['root_folder_path'], '/Comics');

    await tester.tap(find.text('BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'edited-again',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(accounts.saved!.authorization['refresh_token'], 'edited-again');
    expect(accounts.saved!.authorization['root_folder_path'], '/Comics');
  });

  testWidgets('123 client credentials remain editable without refresh tokens', (
    tester,
  ) async {
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: '123',
        backend: StorageBackend.openlist,
        driver: '123 Open',
        name: '123',
        authorization: {'ClientID': 'client', 'ClientSecret': 'secret'},
      );
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.text('123'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Renamed');
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(accounts.saved!.name, 'Renamed');
    expect(accounts.saved!.authorization['ClientID'], 'client');
    expect(accounts.saved!.authorization['ClientSecret'], 'secret');
  });

  testWidgets('legacy Quark accounts switch to Cookie login on save', (
    tester,
  ) async {
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: 'quark',
        backend: StorageBackend.openlist,
        driver: 'QuarkOpen',
        name: 'Quark account',
        authorization: {'refresh_token': 'refresh', 'root_folder_id': '123'},
      );
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.text('Quark account'));
    await tester.pumpAndSettle();
    expect(find.text('Log in and authorize'), findsOneWidget);
    expect(find.text('AppID'), findsNothing);
    expect(find.text('SignKey'), findsNothing);
    expect(find.text('Refresh Token'), findsNothing);
    expect(find.text('Import token JSON or callback'), findsNothing);
    expect(find.text('Cookie'), findsOneWidget);
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(find.text('Cookie is required'), findsOneWidget);
    expect(accounts.saved!.driver, 'QuarkOpen');

    await tester.enterText(
      find.widgetWithText(TextField, 'Cookie'),
      ' __pus=session; __puus=secret ',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(accounts.saved!.id, 'quark');
    expect(accounts.saved!.driver, 'Quark');
    expect(accounts.saved!.authorization, {
      'cookie': '__pus=session; __puus=secret',
      'root_folder_id': '123',
    });
    expect(accounts.rpc.testCalls, 1);
  });

  testWidgets('authorization callback fills tokens and replaces old app keys', (
    tester,
  ) async {
    final controller = _WebviewController();
    String? desktopUrl;
    var desktopClosed = false;
    if (Platform.isLinux) {
      App.dataPath = Directory.systemTemp.path;
      const channel = MethodChannel('webview_window');
      const codec = StandardMethodCodec();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'create':
            return 1;
          case 'launch':
            desktopUrl = call.arguments['url'] as String;
            return null;
          case 'evaluateJavaScript':
            final script = call.arguments['javaScriptString'] as String;
            if (script.contains('function collect()')) {
              return jsonEncode({
                'id': 'document_created',
                'data': {'title': 'Login', 'ua': 'test'},
              });
            }
            return controller.evaluateJavascript(source: script);
          case 'close':
            desktopClosed = true;
            tester.binding.channelBuffers.push(
              channel.name,
              codec.encodeMethodCall(
                const MethodCall('onWindowClose', {'id': 1}),
              ),
              (_) {},
            );
            return null;
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: 'onedrive',
        backend: StorageBackend.openlist,
        driver: 'Onedrive',
        name: 'My OneDrive',
        authorization: {
          'refresh_token': 'old-refresh',
          'client_id': 'old-client',
          'client_secret': 'old-secret',
          'use_online_api': false,
          'root_folder_path': '/Comics',
        },
      );
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.text('My OneDrive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log in and authorize'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final login = Platform.isLinux
        ? null
        : tester.widget<AppWebview>(find.byType(AppWebview));
    final loginUrl = Platform.isLinux ? desktopUrl! : login!.initialUrl;
    expect(Uri.parse(loginUrl).queryParameters['driver_txt'], 'onedrive_pr');
    controller.page = {
      'url': loginUrl,
      'body': '{"text":"https://login.microsoftonline.com/authorize"}',
    };
    if (Platform.isLinux) {
      await tester.pump(const Duration(seconds: 2));
    } else {
      login!.onLoadStop!(controller);
      await tester.pump();
    }
    expect(
      controller.scripts.last,
      contains(
        'location.replace("https://login.microsoftonline.com/authorize")',
      ),
    );
    final payload = base64Encode(
      utf8.encode(
        jsonEncode({
          'driver_txt': 'onedrive_pr',
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
        }),
      ),
    );
    controller.page = jsonEncode({
      'url': 'https://api.oplist.org/#$payload',
      'body': null,
    });
    if (Platform.isLinux) {
      await tester.pump(const Duration(seconds: 2));
    } else {
      login!.onLoadStop!(controller);
    }
    await tester.pumpAndSettle();

    if (Platform.isLinux) expect(desktopClosed, isTrue);
    expect(find.byType(AppWebview), findsNothing);
    final refresh = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Refresh Token'),
    );
    expect(refresh.controller!.text, 'new-refresh');
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(accounts.saved!.authorization['refresh_token'], 'new-refresh');
    expect(accounts.saved!.authorization['client_id'], isEmpty);
    expect(accounts.saved!.authorization['client_secret'], isEmpty);
    expect(accounts.saved!.authorization['use_online_api'], isTrue);
    expect(accounts.saved!.authorization['root_folder_path'], '/Comics');
    expect(accounts.rpc.testCalls, 1);
  });

  testWidgets('account initialization errors are not replaced by list errors', (
    tester,
  ) async {
    const originalError =
        'failed init storage: init get access token error: refresh request failed';
    final accounts = _Accounts()..saveError = originalError;
    accounts.rpc.testError = 'failed to list objs: Authentication expired';
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();

    expect(find.text(originalError), findsOneWidget);
    expect(accounts.rpc.testCalls, 0);
    expect(accounts.saved!.statusMessage, originalError);
    expect(accounts.saved!.status, StorageAuthorizationStatus.unknown);

    accounts.saveError = null;
    accounts.rpc.testError = null;
    await tester.tap(find.text('BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save and test connection'));
    await tester.pumpAndSettle();
    expect(accounts.rpc.testCalls, 1);
    expect(accounts.saved!.statusMessage, isNull);
    expect(accounts.saved!.status, StorageAuthorizationStatus.valid);
  });
}

class _WebviewController extends Fake implements InAppWebViewController {
  Object? page;
  final scripts = <String>[];

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    return page;
  }
}

class _Accounts extends RemoteStorageAccounts {
  StorageAccount? saved;
  String? saveError;
  final rpc = _Rpc();

  @override
  List<StorageAccount> get accounts => [?saved];

  @override
  Future<StorageAccount> save(StorageAccount value) async {
    final result = StorageAccount(
      id: value.id.isEmpty ? 'new-account' : value.id,
      backend: value.backend,
      driver: value.driver,
      name: value.name,
      authorization: value.authorization,
      status: value.status,
      statusMessage: saveError,
    );
    saved = result;
    return result;
  }

  @override
  RemoteFileStore storeFor(String accountId) => OpenListFileStore(saved!, rpc);

  @override
  Future<void> updateStatus(StorageAccount value) async => saved = value;
}

class _Rpc implements OpenListRpcClient {
  String? testError;
  var testCalls = 0;

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'test') {
      testCalls++;
      if (testError != null) {
        return {
          'error': {'code': 'operation_failed', 'message': testError},
        };
      }
    }
    return const {'data': {}};
  }
}
