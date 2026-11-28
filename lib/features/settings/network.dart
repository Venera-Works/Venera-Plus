import 'dart:io' show InternetAddress;

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
              help:
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

  // [USERNAME[:PASSWORD]@]HOST[:PORT]
  String toProxyStr() {
    if (type == 'direct') {
      return 'direct';
    } else if (type == 'system') {
      return 'system';
    }
    final host = _hostController.text.trim();
    final rawPort = _portController.text.trim();
    final port = rawPort.isEmpty ? '' : int.parse(rawPort).toString();
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
    final at = proxy.lastIndexOf('@');
    if (at >= 0) {
      final auth = proxy.substring(0, at);
      final separator = auth.indexOf(':');
      _usernameController.text = separator < 0
          ? auth
          : auth.substring(0, separator);
      _passwordController.text = separator < 0
          ? ''
          : auth.substring(separator + 1);
    }
    final address = proxy.substring(at + 1);
    final separator = address.startsWith('[')
        ? address.indexOf(':', address.indexOf(']') + 1)
        : address.indexOf(':');
    _hostController.text = separator < 0
        ? address
        : address.substring(0, separator);
    _portController.text = separator < 0
        ? ''
        : address.substring(separator + 1);
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
              if (v == null || v.trim().isEmpty) {
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
              final value = v?.trim() ?? '';
              if (value.isEmpty) return null;
              final port = int.tryParse(value, radix: 10);
              if (port == null || port < 1 || port > 65535) {
                return 'Port must be between 1 and 65535.'.tl;
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
  static final _domainPattern = RegExp(
    r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$',
  );
  final overrides = <(TextEditingController, TextEditingController)>[];
  final _formKey = GlobalKey<FormState>();
  final _duplicates = <String>{};
  late bool _enabled = appdata.settings['enableDnsOverrides'] == true;
  late bool _sni = appdata.settings['sni'] != false;
  bool _saving = false;

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
    for (final (domain, ip) in overrides) {
      domain.dispose();
      ip.dispose();
    }
    super.dispose();
  }

  String _domainKey(String input) =>
      input.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  bool _isBlank((TextEditingController, TextEditingController) entry) =>
      entry.$1.text.trim().isEmpty && entry.$2.text.trim().isEmpty;

  Future<void> _save() async {
    if (_saving) return;
    _duplicates.clear();
    final rules = <String, String>{};
    for (final entry in overrides) {
      if (_isBlank(entry)) continue;
      final domain = _domainKey(entry.$1.text);
      if (rules.containsKey(domain)) _duplicates.add(domain);
      rules[domain] = entry.$2.text.trim();
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    appdata.settings['dnsOverrides'] = rules;
    appdata.settings['enableDnsOverrides'] = _enabled;
    appdata.settings['sni'] = _sni;
    try {
      await appdata.saveData();
      JsEngine().resetDio();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (_) {
      if (mounted) context.showMessage(message: 'Saved Failed'.tl);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "DNS Overrides".tl,
      body: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              SwitchListTile(
                title: Text('Enable DNS Overrides'.tl),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              SwitchListTile(
                title: Text('Server Name Indication'.tl),
                value: _sni,
                onChanged: (value) => setState(() => _sni = value),
              ),
              const SizedBox(height: 8),
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: context.colorScheme.outlineVariant,
              ),
              for (final entry in overrides) buildOverride(entry),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      style: actionButtonStyle,
                      onPressed: () => setState(() {
                        overrides.add((
                          TextEditingController(),
                          TextEditingController(),
                        ));
                      }),
                      icon: const Icon(Icons.add),
                      label: Text('Add'.tl),
                    ),
                    FilledButton(
                      style: actionButtonStyle,
                      onPressed: _saving ? null : _save,
                      child: Text('Save'.tl),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildOverride((TextEditingController, TextEditingController) entry) {
    return Container(
      key: ObjectKey(entry.$1),
      margin: const EdgeInsets.symmetric(horizontal: 8),
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
            child: TextFormField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "Domain".tl,
              ),
              controller: entry.$1,
              validator: (_) {
                if (_isBlank(entry)) return null;
                final domain = _domainKey(entry.$1.text);
                if (domain.length > 253 || !_domainPattern.hasMatch(domain)) {
                  return 'Enter a valid domain name.'.tl;
                }
                if (_duplicates.contains(domain)) {
                  return 'Duplicate domain name.'.tl;
                }
                return null;
              },
            ).paddingHorizontal(8),
          ),
          Expanded(
            child: TextFormField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "IP".tl,
              ),
              controller: entry.$2,
              validator: (_) {
                if (_isBlank(entry)) return null;
                if (InternetAddress.tryParse(entry.$2.text.trim()) == null) {
                  return 'Enter a valid IP address.'.tl;
                }
                return null;
              },
            ).paddingHorizontal(8),
          ),
          IconButton(
            tooltip: 'Delete'.tl,
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() => overrides.remove(entry));
              entry.$1.dispose();
              entry.$2.dispose();
            },
          ),
        ],
      ),
    );
  }
}
