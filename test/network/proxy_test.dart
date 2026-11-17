import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('venera/method_channel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String previousSetting;

  setUp(() {
    previousSetting = appdata.settings['proxy'] as String;
  });

  tearDown(() {
    appdata.settings['proxy'] = previousSetting;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('切换直连和手动代理端口时立即更新缓存', () async {
    appdata.settings['proxy'] = '127.0.0.1:7890';
    expect(await getProxy(), '127.0.0.1:7890');
    appdata.settings['proxy'] = 'direct';
    expect(await getProxy(), isNull);
    appdata.settings['proxy'] = '127.0.0.1:7891';
    expect(await getProxy(), '127.0.0.1:7891');
  });

  test('切回系统模式时重新读取代理而不沿用手动配置', () async {
    var systemProxy = '127.0.0.1:7892';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getProxy');
      return systemProxy;
    });

    appdata.settings['proxy'] = '127.0.0.1:7890';
    expect(await getProxy(), '127.0.0.1:7890');
    appdata.settings['proxy'] = 'system';
    expect(await getProxy(), App.isLinux ? null : systemProxy);
    appdata.settings['proxy'] = 'direct';
    expect(await getProxy(), isNull);
    systemProxy = 'No Proxy';
    appdata.settings['proxy'] = 'system';
    expect(await getProxy(), isNull);
  });
}
