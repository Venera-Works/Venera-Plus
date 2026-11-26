import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class NetworkSettings extends StatelessWidget {
  const NetworkSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appdata.settings,
      builder: (context, _) {
        final proxy = switch (appdata.settings['proxy']) {
          'direct' => 'Direct'.tl,
          'system' => 'System'.tl,
          _ => 'Manual'.tl,
        };
        final dns = appdata.settings['enableDnsOverrides'] == true
            ? 'Enabled · @count rules'.tlParams({
                'count': (appdata.settings['dnsOverrides'] as Map).length,
              })
            : 'Off'.tl;
        return SmoothCustomScrollView(
          slivers: [
            SliverAppbar(title: Text('Network'.tl)),
            PopupWindowSetting(
              title: 'Proxy'.tl,
              subtitle: proxy,
              builder: () => const _ProxySettingView(),
            ).toSliver(),
            PopupWindowSetting(
              title: 'DNS Overrides'.tl,
              subtitle: dns,
              builder: () => const _DNSOverrides(),
            ).toSliver(),
            SwitchSetting(
              title: 'Ignore Certificate Errors'.tl,
              subtitle:
                  'Skip HTTPS certificate verification. Enable only if needed.'
                      .tl,
              settingKey: 'ignoreBadCertificate',
            ).toSliver(),
          ],
        );
      },
    );
  }
}

class _ProxySettingView extends StatefulWidget {
  const _ProxySettingView();

  @override
  State<_ProxySettingView> createState() => _ProxySettingViewState();
}

class _ProxySettingViewState extends State<_ProxySettingView> {
  String type = '';
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  final _formKey = GlobalKey<FormState>();
  bool _passwordVisible = false;

  // USERNAME:PASSWORD@HOST:PORT
  String toProxyStr() {
    if (type == 'direct') {
      return 'direct';
    } else if (type == 'system') {
      return 'system';
    }
    final host = _hostController.text;
    final port = _portController.text;
    final username = _usernameController.text;
    final password = _passwordController.text;
    var res = '';
    if (username.isNotEmpty) {
      res += username;
      if (password.isNotEmpty) {
        res += ':$password';
      }
      res += '@';
    }
    res += host;
    if (port.isNotEmpty) {
      res += ':$port';
    }
    return res;
  }

  void parseProxyString(String proxy) {
    if (proxy == 'direct') {
      type = 'direct';
      return;
    } else if (proxy == 'system') {
      type = 'system';
      return;
    }
    type = 'manual';
    var parts = proxy.split('@');
    if (parts.length == 2) {
      var auth = parts[0].split(':');
      if (auth.length == 2) {
        _usernameController.text = auth[0];
        _passwordController.text = auth[1];
      }
      parts = parts[1].split(':');
      if (parts.length == 2) {
        _hostController.text = parts[0];
        _portController.text = parts[1];
      }
    } else {
      parts = proxy.split(':');
      if (parts.length == 2) {
        _hostController.text = parts[0];
        _portController.text = parts[1];
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController();
    _portController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    parseProxyString(appdata.settings['proxy']);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Proxy".tl,
      body: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: type,
          onChanged: (v) {
            setState(() {
              type = v ?? type;
            });
            if (type != 'manual') {
              appdata.settings['proxy'] = toProxyStr();
              appdata.saveData();
            }
          },
          child: Column(
            children: [
              RadioListTile<String>(title: Text("Direct".tl), value: 'direct'),
              RadioListTile<String>(title: Text("System".tl), value: 'system'),
              RadioListTile(title: Text("Manual".tl), value: 'manual'),
              if (type == 'manual') buildManualProxy(),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _proxyFieldDecoration(String label, {Widget? suffixIcon}) =>
      InputDecoration(
        labelText: label.tl,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        suffixIcon: suffixIcon,
      );

  Widget buildManualProxy() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          TextFormField(
            decoration: _proxyFieldDecoration('Host'),
            controller: _hostController,
            validator: (v) {
              if (v?.isEmpty ?? false) {
                return "Host cannot be empty".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            decoration: _proxyFieldDecoration('Port'),
            controller: _portController,
            validator: (v) {
              if (v?.isEmpty ?? true) {
                return null;
              }
              if (int.tryParse(v!) == null) {
                return "Port must be a number".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            decoration: _proxyFieldDecoration('Username'),
            controller: _usernameController,
            validator: (v) {
              if ((v?.isEmpty ?? false) &&
                  _passwordController.text.isNotEmpty) {
                return "Username cannot be empty".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordController,
            obscureText: !_passwordVisible,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _proxyFieldDecoration(
              'Password',
              suffixIcon: IconButton(
                tooltip:
                    (_passwordVisible ? 'Hide password' : 'Show password').tl,
                icon: Icon(
                  _passwordVisible ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _passwordVisible = !_passwordVisible),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () {
              if (_formKey.currentState?.validate() ?? false) {
                appdata.settings['proxy'] = toProxyStr();
                appdata.saveData();
                App.rootContext.pop();
              }
            },
            child: Text("Save".tl),
          ),
        ],
      ),
    ).paddingHorizontal(16).paddingTop(16);
  }
}

class _DNSOverrides extends StatefulWidget {
  const _DNSOverrides();

  @override
  State<_DNSOverrides> createState() => __DNSOverridesState();
}

class __DNSOverridesState extends State<_DNSOverrides> {
  var overrides = <(TextEditingController, TextEditingController)>[];

  @override
  void initState() {
    for (var entry in (appdata.settings['dnsOverrides'] as Map).entries) {
      if (entry.key is String && entry.value is String) {
        overrides.add((
          TextEditingController(text: entry.key),
          TextEditingController(text: entry.value),
        ));
      }
    }
    super.initState();
  }

  @override
  void dispose() {
    var map = <String, String>{};
    for (var entry in overrides) {
      map[entry.$1.text] = entry.$2.text;
    }
    // Updating the setting notifies the overview after the widget tree unlocks.
    scheduleMicrotask(() {
      appdata.settings['dnsOverrides'] = map;
      appdata.saveData();
      JsEngine().resetDio();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "DNS Overrides".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            SwitchSetting(
              title: "Enable DNS Overrides".tl,
              settingKey: "enableDnsOverrides",
            ),
            SwitchSetting(
              title: 'Server Name Indication'.tl,
              settingKey: 'sni',
            ),
            const SizedBox(height: 8),
            Container(
              height: 1,
              margin: EdgeInsets.symmetric(horizontal: 8),
              color: context.colorScheme.outlineVariant,
            ),
            for (var i = 0; i < overrides.length; i++) buildOverride(i),
            const SizedBox(height: 8),
            TextButton.icon(
              style: actionButtonStyle,
              onPressed: () {
                setState(() {
                  overrides.add((
                    TextEditingController(),
                    TextEditingController(),
                  ));
                });
              },
              icon: const Icon(Icons.add),
              label: Text("Add".tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildOverride(int index) {
    var entry = overrides[index];
    return Container(
      key: ValueKey(index),
      height: 48,
      margin: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.colorScheme.outlineVariant),
          left: BorderSide(color: context.colorScheme.outlineVariant),
          right: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "Domain".tl,
              ),
              controller: entry.$1,
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "IP".tl,
              ),
              controller: entry.$2,
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() {
                overrides.removeAt(index);
              });
            },
          ),
        ],
      ),
    );
  }
}
