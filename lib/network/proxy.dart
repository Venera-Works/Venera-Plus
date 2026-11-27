import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/extensions.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

String? _cachedProxySetting;

Future<String?> getProxy() async {
  final setting = appdata.settings['proxy'] as String;
  if (_cachedProxySetting == setting &&
      _cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  final proxy = await _getProxy(setting);
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  _cachedProxySetting = setting;
  return proxy;
}

Future<String?> _getProxy(String setting) async {
  if (setting.removeAllBlank == 'direct') return null;
  if (setting != 'system') return setting;

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return proxy.substring(6);
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return res;
}
