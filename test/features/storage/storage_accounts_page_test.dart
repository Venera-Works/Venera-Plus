import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
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

class _Accounts extends RemoteStorageAccounts {
  StorageAccount? saved;
  String? saveError;
  final rpc = _Rpc();

  @override
  List<StorageAccount> get accounts => [?saved];

  @override
  Future<StorageAccount> save(StorageAccount value) async {
    final result = value.copyWith(statusMessage: saveError);
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
