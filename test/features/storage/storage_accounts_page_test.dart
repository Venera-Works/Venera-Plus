import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:venera_plus/routing/webview.dart';

void main() {
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
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Use this account for'), findsOneWidget);
    await tester.tap(find.text('App Data Sync'));
    await tester.pumpAndSettle();
    expect(selected?.$1.id, 'new-account');
    expect(selected?.$2, StorageAccountPurpose.sync);
    expect(find.byType(StorageAccountsPage), findsNothing);
  });

  testWidgets('adding an account returns to the current location form', (
    tester,
  ) async {
    final accounts = _Accounts();
    final name = TextEditingController(text: 'Unfinished library');
    addTearDown(name.dispose);
    StorageAccount? selected;
    var directories = <String>['/previous/'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Cloud Storage Account').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'New Drive');
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save'));
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
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(selected?.name, 'New Drive');
    expect(name.text, 'Unfinished library');
  });

  testWidgets('default login shows required tokens and validates them', (
    tester,
  ) async {
    final accounts = _Accounts();
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Refresh Token'), findsOneWidget);
    expect(find.text('Access Token'), findsNothing);
    expect(find.text('AppID'), findsNothing);
    expect(find.text('Log in and authorize'), findsOneWidget);
    expect(find.text('Open OpenList token page'), findsNothing);
    expect(find.text('Token JSON or callback'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh Token is required'), findsOneWidget);
    expect(accounts.saved, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(accounts.saved!.authorization['refresh_token'], 'refresh');
    expect(accounts.saved!.authorization['use_online_api'], isTrue);
  });

  testWidgets('import fills fields and later token edits take precedence', (
    tester,
  ) async {
    final accounts = _Accounts();
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import token JSON or callback'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Token JSON or callback'),
      '{"refresh_token":"imported","AccessToken":"old-access",'
      '"root_folder_path":"/Comics"}',
    );
    await tester.ensureVisible(find.text('Import'));
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    final refresh = find.widgetWithText(TextField, 'Refresh Token');
    expect(tester.widget<TextField>(refresh).controller!.text, 'imported');
    await tester.ensureVisible(refresh);
    await tester.enterText(refresh, 'edited');
    await tester.tap(find.text('Save'));
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
    await tester.tap(find.text('Save'));
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
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(accounts.saved!.name, 'Renamed');
    expect(accounts.saved!.authorization['ClientID'], 'client');
    expect(accounts.saved!.authorization['ClientSecret'], 'secret');
  });

  testWidgets('Quark saves official tokens without application keys', (
    tester,
  ) async {
    final accounts = _Accounts()
      ..saved = const StorageAccount(
        id: 'quark',
        backend: StorageBackend.openlist,
        driver: 'QuarkOpen',
        name: 'Quark account',
        authorization: {'refresh_token': 'refresh'},
      );
    await tester.pumpWidget(
      MaterialApp(home: StorageAccountsPage(accounts: accounts)),
    );
    await tester.tap(find.text('Quark account'));
    await tester.pumpAndSettle();
    expect(find.text('Log in and authorize'), findsOneWidget);
    expect(find.text('AppID'), findsNothing);
    expect(find.text('SignKey'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(accounts.saved!.authorization['refresh_token'], 'refresh');
    expect(accounts.saved!.authorization['use_online_api'], isTrue);
    expect(accounts.saved!.authorization['app_id'], isNull);
    expect(accounts.saved!.authorization['sign_key'], isNull);
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
    await tester.tap(find.text('Save'));
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
    await tester.enterText(
      find.widgetWithText(TextField, 'Refresh Token'),
      'refresh',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text(originalError), findsOneWidget);
    expect(accounts.rpc.testCalls, 0);
    expect(accounts.saved!.statusMessage, originalError);
    expect(accounts.saved!.status, StorageAuthorizationStatus.unknown);

    accounts.saveError = null;
    accounts.rpc.testError = null;
    await tester.tap(find.text('BaiduNetdisk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
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
