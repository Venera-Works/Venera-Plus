import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  setUp(() {
    appdata.settings['bangumiServer'] = bangumiOfficialServer.apiUrl;
    appdata.settings['bangumiCustomServers'] = <Map<String, String>>[];
  });

  tearDown(() {
    appdata.settings['bangumiServer'] = bangumiOfficialServer.apiUrl;
    appdata.settings['bangumiCustomServers'] = <Map<String, String>>[];
  });

  testWidgets(
    'list probes on opening and updates each result without reordering',
    (tester) async {
      final pending = <String, Completer<BangumiProbeResult>>{};
      await _openList(
        tester,
        probe: (server, token) {
          final completer = Completer<BangumiProbeResult>();
          pending[server.apiUrl] = completer;
          return completer.future;
        },
      );
      expect(pending.keys, bangumiPresetServers.map((server) => server.apiUrl));
      expect(find.text('Testing…'), findsNWidgets(3));
      pending[bangumiPresetServers.last.apiUrl]!.complete(
        const BangumiProbeResult(
          BangumiProbeStatus.available,
          elapsed: Duration(milliseconds: 286),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Available · 286 ms'), findsOneWidget);
      expect(
        tester.getTopLeft(_entry(bangumiPresetServers.first)).dy,
        lessThan(tester.getTopLeft(_entry(bangumiPresetServers.last)).dy),
      );
      pending[bangumiPresetServers.first.apiUrl]!.complete(
        const BangumiProbeResult(BangumiProbeStatus.timeout),
      );
      pending[bangumiPresetServers[1].apiUrl]!.complete(
        const BangumiProbeResult(BangumiProbeStatus.verificationRequired),
      );
      await tester.pumpAndSettle();
      expect(find.text('Timed out'), findsOneWidget);
      expect(find.text('Verification required'), findsOneWidget);
    },
  );

  testWidgets('choosing the lat preset switches its Token page as well', (
    tester,
  ) async {
    Uri? launched;
    await _openList(
      tester,
      launch: (uri) async {
        launched = uri;
        return true;
      },
    );
    await tester.tap(_entry(bangumiPresetServers[1]));
    await tester.pumpAndSettle();
    expect(currentBangumiServer.apiUrl, 'https://api.bangumi.lat');
    await tester.tap(find.byKey(const Key('bangumi-apply-token')));
    await tester.pumpAndSettle();
    expect(launched.toString(), 'https://next.bangumi.lat/demo/access-token');
  });

  testWidgets('custom endpoints append, persist and use independent hosts', (
    tester,
  ) async {
    Uri? launched;
    await _openList(
      tester,
      launch: (uri) async {
        launched = uri;
        return true;
      },
    );
    await _add(
      tester,
      name: 'Custom',
      api: 'bgmapi.example.com/proxy/',
      image: 'bgmimg.example.com',
      token: 'accounts.example.com/token/new',
    );
    expect(bangumiServers.map((server) => server.name), [
      'bgm.tv',
      'bangumi.lat',
      'anibt.net',
      'Custom',
    ]);
    expect(currentBangumiServer, same(bangumiOfficialServer));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-server-list')));
    await tester.pumpAndSettle();
    final server = bangumiServers.last;
    await tester.ensureVisible(_entry(server));
    await tester.tap(_entry(server));
    await tester.pumpAndSettle();
    expect(currentBangumiServer.apiUrl, 'https://bgmapi.example.com/proxy');
    expect(currentBangumiServer.imageUrl, 'https://bgmimg.example.com');
    await tester.tap(find.byKey(const Key('bangumi-apply-token')));
    await tester.pumpAndSettle();
    expect(launched.toString(), 'https://accounts.example.com/token/new');
  });

  testWidgets(
    'editing preserves order and deleting the active custom server restores official',
    (tester) async {
      await _openList(tester);
      await _add(tester, name: 'First', api: 'first.example.com');
      await _add(tester, name: 'Second', api: 'second.example.com');
      final first = bangumiServers[3];
      await tester.ensureVisible(_entry(first));
      await tester.tap(_entry(first));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bangumi-server-list')));
      await tester.pumpAndSettle();
      final menu = find.descendant(
        of: _entry(bangumiServers[3]),
        matching: find.byType(PopupMenuButton<String>),
      );
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bangumi-server-api')),
        'renamed.example.com',
      );
      await tester.tap(find.byKey(const Key('bangumi-server-save')));
      await tester.pumpAndSettle();
      expect(bangumiServers.map((server) => server.name), [
        'bgm.tv',
        'bangumi.lat',
        'anibt.net',
        'First',
        'Second',
      ]);
      expect(currentBangumiServer.apiUrl, 'https://renamed.example.com');
      final renamed = bangumiServers[3];
      final deleteMenu = find.descendant(
        of: _entry(renamed),
        matching: find.byType(PopupMenuButton<String>),
      );
      await tester.ensureVisible(deleteMenu);
      await tester.tap(deleteMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(currentBangumiServer, same(bangumiOfficialServer));
      expect(bangumiServers.last.name, 'Second');
      expect(bangumiServers, hasLength(4));
    },
  );

  testWidgets(
    'duplicate API URLs are not appended and failed saves restore settings',
    (tester) async {
      var fail = false;
      await _openList(
        tester,
        save: () async {
          if (fail) throw StateError('Disk full');
        },
      );
      await _add(tester, api: 'first.example.com');
      await _add(tester, api: 'https://FIRST.example.com/');
      expect(bangumiServers, hasLength(4));
      expect(
        find.text('This API address is already in the list'),
        findsOneWidget,
      );
      fail = true;
      await tester.tap(_entry(bangumiPresetServers[1]));
      await tester.pumpAndSettle();
      expect(currentBangumiServer, same(bangumiOfficialServer));
      expect(
        find.textContaining('Failed to save Bangumi settings:'),
        findsOneWidget,
      );
      await _add(tester, api: 'second.example.com');
      expect(bangumiServers, hasLength(4));
      expect(bangumiServers.last.apiUrl, 'https://first.example.com');
    },
  );

  testWidgets(
    'closing cancels pending probes and reopening starts a fresh test',
    (tester) async {
      final tokens = <CancelToken>[];
      final pending = <Completer<BangumiProbeResult>>[];
      await _openList(
        tester,
        probe: (_, token) {
          tokens.add(token);
          final result = Completer<BangumiProbeResult>();
          pending.add(result);
          return result.future;
        },
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tokens, hasLength(3));
      expect(tokens.every((token) => token.isCancelled), isTrue);
      for (final result in pending) {
        result.complete(const BangumiProbeResult(BangumiProbeStatus.available));
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('bangumi-server-list')));
      await tester.pumpAndSettle();
      expect(tokens, hasLength(6));
      await tester.pumpWidget(const SizedBox());
      expect(tokens.every((token) => token.isCancelled), isTrue);
      for (final result in pending.skip(3)) {
        result.complete(const BangumiProbeResult(BangumiProbeStatus.available));
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'address editor remains usable on a small screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openList(tester, textScale: 1.5);
      expect(tester.takeException(), isNull);
      await _add(tester, api: 'small.example.com');
      expect(bangumiServers.last.apiUrl, 'https://small.example.com');
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _entry(BangumiServer server) =>
    find.byKey(ValueKey('bangumi-server-${server.apiUrl}'));

Future<void> _openList(
  WidgetTester tester, {
  BangumiServerProbe? probe,
  Future<void> Function()? save,
  Future<bool> Function(Uri)? launch,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: BangumiSettingsPage(
        service: BangumiService.forTesting(
          gatewayFactory: (_) => _UnusedGateway(),
        ),
        saveSettings: save ?? () async {},
        launchTokenPage: launch ?? (_) async => true,
        probeServer:
            probe ??
            (_, _) async => const BangumiProbeResult(
              BangumiProbeStatus.available,
              elapsed: Duration(milliseconds: 12),
            ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('bangumi-server-list')));
  await tester.pumpAndSettle();
}

Future<void> _add(
  WidgetTester tester, {
  required String api,
  String name = '',
  String image = '',
  String token = '',
}) async {
  await tester.tap(find.byKey(const Key('bangumi-server-add')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('bangumi-server-name')), name);
  await tester.enterText(find.byKey(const Key('bangumi-server-api')), api);
  await tester.enterText(find.byKey(const Key('bangumi-server-images')), image);
  await tester.enterText(
    find.byKey(const Key('bangumi-server-token-page')),
    token,
  );
  await tester.tap(find.byKey(const Key('bangumi-server-save')));
  await tester.pumpAndSettle();
}

class _UnusedGateway implements BangumiGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('These settings must not request the account API');
}
