import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/setting_tile.dart';
import 'package:venera_plus/features/bangumi/bangumi_api.dart';
import 'package:venera_plus/features/bangumi/bangumi_service.dart';
import 'package:venera_plus/features/bangumi/bangumi_server.dart';
import 'package:venera_plus/features/bangumi/bangumi_server_settings.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

Future<void> _saveBangumiSettings() => appdata.saveData();

class BangumiSettingsPage extends StatefulWidget {
  const BangumiSettingsPage({
    super.key,
    this.service,
    this.saveSettings = _saveBangumiSettings,
    this.launchTokenPage = _launchTokenPage,
    this.onConnectionChanged,
    this.probeServer = probeBangumiServer,
  });

  final BangumiService? service;
  final Future<void> Function() saveSettings;
  final Future<bool> Function(Uri uri) launchTokenPage;
  final VoidCallback? onConnectionChanged;
  final BangumiServerProbe probeServer;

  static Future<bool> _launchTokenPage(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  State<BangumiSettingsPage> createState() => _BangumiSettingsPageState();
}

class _BangumiSettingsPageState extends State<BangumiSettingsPage> {
  late final TextEditingController _tokenController;
  late bool _autoSyncEnabled;
  late bool _autoMetadataScrapeEnabled;
  bool _isConnecting = false;
  bool _isSavingAutoSync = false;
  bool _isSavingAutoMetadataScrape = false;
  bool _tokenVisible = false;
  late bool _savedConnectionInvalid;
  String? _tokenError;
  String? _errorMessage;

  BangumiService get _service => widget.service ?? BangumiService();

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(
      text: _settingString('bangumiAccessToken'),
    );
    _autoSyncEnabled = _settingBool('bangumiAutoSyncEnabled', true);
    _autoMetadataScrapeEnabled = _settingBool(
      'bangumiAutoMetadataScrapeEnabled',
      false,
    );
    _savedConnectionInvalid = _service.isAuthenticationPaused;
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final username = _settingString('bangumiUsername');
    final errorStyle = TextStyle(color: Theme.of(context).colorScheme.error);
    return PopUpWidgetScaffold(
      title: 'Bangumi',
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            BangumiServerSetting(
              saveSettings: widget.saveSettings,
              enabled: !_isConnecting,
              probe: widget.probeServer,
              onChanged: () {
                if (!mounted) return;
                setState(() {
                  _savedConnectionInvalid = _service.isAuthenticationPaused;
                  _tokenError = null;
                  _errorMessage = null;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('bangumi-token-field'),
              controller: _tokenController,
              enabled: !_isConnecting,
              obscureText: !_tokenVisible,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) {
                if (_tokenError != null) setState(() => _tokenError = null);
              },
              decoration: InputDecoration(
                labelText: 'Bangumi Access Token'.tl,
                errorText: _tokenError,
                errorMaxLines: 3,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                suffixIcon: IconButton(
                  tooltip: (_tokenVisible ? 'Hide token' : 'Show token').tl,
                  icon: Icon(
                    _tokenVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _tokenVisible = !_tokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: actionButtonStyle,
                    key: const Key('bangumi-apply-token'),
                    onPressed: _applyForToken,
                    child: Text('Apply for Access Token'.tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('bangumi-auto-sync'),
              contentPadding: EdgeInsets.zero,
              title: Text('Automatically sync after completing a chapter'.tl),
              value: _autoSyncEnabled,
              onChanged: _isSavingAutoSync ? null : _setAutoSyncEnabled,
            ),
            SettingSwitchTile(
              key: const Key('bangumi-auto-metadata-scrape'),
              contentPadding: EdgeInsets.zero,
              title: 'Automatic metadata scraping'.tl,
              help:
                  'When enabled, Bangumi will be used to scrape comic metadata.'
                      .tl,
              value: _autoMetadataScrapeEnabled,
              onChanged: _isSavingAutoMetadataScrape
                  ? null
                  : _setAutoMetadataScrapeEnabled,
            ),
            if (_savedConnectionInvalid) ...[
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'Bangumi connection is invalid. Please check your Access Token.'
                      .tl,
                  style: errorStyle,
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(_errorMessage!, style: errorStyle),
              ),
            ],
            if (username.isNotEmpty && !_savedConnectionInvalid) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Text('${'Connected as'.tl}: '),
                    Expanded(
                      child: Text(username, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: actionButtonStyle,
                    key: const Key('bangumi-connect'),
                    onPressed: _isConnecting ? null : _connect,
                    child: ButtonLoadingContent(
                      isLoading: _isConnecting,
                      child: Text(
                        username.isEmpty
                            ? 'Connect'.tl
                            : 'Verify connection'.tl,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (username.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: actionButtonStyle,
                      key: const Key('bangumi-disconnect'),
                      onPressed: _isConnecting ? null : _disconnect,
                      child: ButtonLoadingContent(
                        isLoading: _isConnecting,
                        child: Text('Disconnect'.tl),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  Future<void> _connect() async {
    if (_isConnecting) return;
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _tokenError = 'Access Token cannot be empty'.tl);
      return;
    }
    setState(() {
      _isConnecting = true;
      _tokenError = null;
      _errorMessage = null;
    });
    try {
      await _service.connect(token);
      widget.onConnectionChanged?.call();
      if (mounted) {
        setState(() => _savedConnectionInvalid = false);
        context.showMessage(message: 'Connection successful'.tl);
      }
    } catch (error) {
      if (!mounted) return;
      final isSavedToken = token == _settingString('bangumiAccessToken').trim();
      setState(() {
        if (error is BangumiApiException &&
            (error.statusCode == 401 || error.statusCode == 403)) {
          if (isSavedToken) {
            _savedConnectionInvalid = true;
          } else {
            _tokenError = 'Invalid Access Token'.tl;
          }
        } else {
          _tokenError = '${'Failed to connect to Bangumi'.tl}: $error';
        }
      });
      if (isSavedToken) {
        context.showMessage(message: 'Failed to connect to Bangumi'.tl);
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _applyForToken() async {
    try {
      final launched = await widget.launchTokenPage(
        Uri.parse(currentBangumiServer.tokenUrl),
      );
      if (!launched && mounted) {
        setState(() => _errorMessage = 'Failed to open Access Token page'.tl);
      } else if (launched && mounted) {
        setState(() => _errorMessage = null);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to open Access Token page'.tl);
      }
    }
  }

  Future<void> _setAutoSyncEnabled(bool value) async {
    if (_isSavingAutoSync) return;
    final previous = _autoSyncEnabled;
    setState(() {
      _autoSyncEnabled = value;
      _isSavingAutoSync = true;
    });
    appdata.settings['bangumiAutoSyncEnabled'] = value;
    try {
      await widget.saveSettings();
      if (mounted) setState(() => _errorMessage = null);
    } catch (error) {
      appdata.settings['bangumiAutoSyncEnabled'] = previous;
      if (mounted) {
        setState(() {
          _autoSyncEnabled = previous;
          _errorMessage = '${'Failed to save Bangumi settings'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isSavingAutoSync = false);
    }
  }

  Future<void> _setAutoMetadataScrapeEnabled(bool value) async {
    if (_isSavingAutoMetadataScrape) return;
    final previous = _autoMetadataScrapeEnabled;
    setState(() {
      _autoMetadataScrapeEnabled = value;
      _isSavingAutoMetadataScrape = true;
    });
    appdata.settings['bangumiAutoMetadataScrapeEnabled'] = value;
    try {
      await widget.saveSettings();
      if (mounted) setState(() => _errorMessage = null);
    } catch (error) {
      appdata.settings['bangumiAutoMetadataScrapeEnabled'] = previous;
      if (mounted) {
        setState(() {
          _autoMetadataScrapeEnabled = previous;
          _errorMessage = '${'Failed to save Bangumi settings'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isSavingAutoMetadataScrape = false);
    }
  }

  String _settingString(String key) {
    final value = appdata.settings[key];
    return value is String ? value : '';
  }

  bool _settingBool(String key, bool fallback) {
    final value = appdata.settings[key];
    return value is bool ? value : fallback;
  }

  Future<void> _disconnect() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      await _service.disconnect();
      widget.onConnectionChanged?.call();
      if (!mounted) return;
      _tokenController.clear();
      setState(() {
        _savedConnectionInvalid = false;
        _tokenError = null;
        _errorMessage = null;
        _tokenVisible = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = '${'Failed to disconnect from Bangumi'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }
}
