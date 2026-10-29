import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/file_system.dart'
    show bytesToReadableString;
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/app_dio.dart'
    show CancelToken, DioException;

import 'app_release.dart';
import 'app_update_service.dart';

final appUpdatePrompt = AppUpdatePrompt();

class AppUpdatePrompt {
  AppUpdatePrompt({AppUpdateService? service})
    : service = service ?? AppUpdateService();

  final AppUpdateService service;
  Future<AppRelease?>? _checking;
  Future<void>? _dialog;

  Future<void> check({bool manual = true, bool delay = false}) async {
    final checking = _checking ??= service.check(App.version);
    try {
      final release = await checking;
      if (release == null) {
        if (manual) _message('No new version available'.tl);
        return;
      }
      final existing = _dialog;
      if (existing != null) {
        await existing;
        return;
      }
      final dialog = _show(release, delay);
      _dialog = dialog;
      try {
        await dialog;
      } finally {
        _dialog = null;
      }
    } catch (error, stack) {
      Log.error('Check Update', error.toString(), stack);
      if (manual) _message('Failed to check for updates'.tl);
    } finally {
      if (identical(_checking, checking)) _checking = null;
    }
  }

  void _message(String message) {
    final context = App.rootNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      context.showMessage(message: message);
    }
  }

  Future<void> _show(AppRelease release, bool delay) async {
    if (delay) await Future<void>.delayed(const Duration(seconds: 2));
    final context = App.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AppUpdateDialog(
        release: release,
        currentVersion: App.version,
        service: service,
      ),
    );
  }
}

enum _UpdateStage { ready, downloading, installing }

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.release,
    required this.currentVersion,
    required this.service,
  });

  final AppRelease release;
  final String currentVersion;
  final AppUpdateService service;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  AppReleaseAsset? _apk;
  bool _loadingApk = false;
  bool _downloaded = false;
  _UpdateStage _stage = _UpdateStage.ready;
  CancelToken? _cancelToken;
  int _received = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _loadingApk = true;
      _loadApk();
    }
  }

  Future<void> _loadApk() async {
    try {
      final abis = await widget.service.supportedAbis();
      if (!mounted) return;
      setState(() {
        _apk = widget.release.androidAssetFor(abis);
        _loadingApk = false;
      });
    } catch (error, stack) {
      Log.error('App Update', error.toString(), stack);
      if (!mounted) return;
      setState(() {
        _loadingApk = false;
        _error = 'Failed to find a compatible installation package'.tl;
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final apk = _apk;
    if (apk == null || _stage != _UpdateStage.ready) return;
    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _stage = _UpdateStage.downloading;
      _received = 0;
      _total = apk.size;
      _error = null;
    });
    try {
      final file = await widget.service.downloadApk(
        apk,
        cancelToken: token,
        onProgress: (received, total) {
          if (!mounted || token.isCancelled) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _downloaded = true;
        _stage = _UpdateStage.installing;
      });
      final permitted = await widget.service.requestInstallPermission();
      if (!mounted || token.isCancelled) return;
      if (!permitted) {
        setState(
          () => _error = 'Allow installing apps from VeneraPlus to continue'.tl,
        );
        return;
      }
      await widget.service.installApk(file);
    } catch (error, stack) {
      if (error is DioException && CancelToken.isCancel(error)) return;
      Log.error('App Update', error.toString(), stack);
      if (!mounted) return;
      setState(() {
        _error =
            (_stage == _UpdateStage.installing
                    ? 'Failed to start installation. Please try again.'
                    : 'Failed to download update. Please try again.')
                .tl;
      });
    } finally {
      if (mounted) {
        setState(() {
          _stage = _UpdateStage.ready;
          _cancelToken = null;
        });
      }
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      if (await launchUrlString(url, mode: LaunchMode.externalApplication)) {
        return;
      }
      throw StateError('Cannot open $url');
    } catch (error, stack) {
      Log.error('App Update', error.toString(), stack);
      if (mounted) setState(() => _error = 'Failed to open link'.tl);
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Update dialog closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final arm64 = Abi.current() == Abi.windowsArm64;
    final installer = widget.release.windowsAsset(
      portable: false,
      arm64: arm64,
    );
    final portable = widget.release.windowsAsset(portable: true, arm64: arm64);
    final packageUnavailable = isAndroid
        ? !_loadingApk && _apk == null
        : isWindows && (installer == null || portable == null);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'New version available'.tl,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  CloseButton(onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          Text(
                            'Current version: @v'.tlParams({
                              'v': widget.currentVersion,
                            }),
                          ),
                          Text(
                            'New version: @v'.tlParams({
                              'v': widget.release.version,
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      MarkdownBody(
                        data: widget.release.notes.isEmpty
                            ? 'No release notes provided.'.tl
                            : widget.release.notes,
                        styleSheet: MarkdownStyleSheet.fromTheme(theme)
                            .copyWith(
                              h1: theme.textTheme.titleLarge,
                              h2: theme.textTheme.titleMedium,
                              p: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.4,
                              ),
                            ),
                        onTapLink: (_, href, _) {
                          if (href != null) {
                            _openUrl(
                              Uri.parse(
                                widget.release.pageUrl,
                              ).resolve(href).toString(),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loadingApk) Text('Finding installation package...'.tl),
                  if (packageUnavailable)
                    Text('The installation package is not available yet.'.tl),
                  if (_stage == _UpdateStage.downloading) ...[
                    LinearProgressIndicator(
                      value: _total > 0
                          ? (_received / _total).clamp(0.0, 1.0)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${bytesToReadableString(_received)} / ${bytesToReadableString(_total)}',
                    ),
                  ],
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (isAndroid)
                        if (_stage == _UpdateStage.downloading)
                          OutlinedButton(
                            onPressed: () => _cancelToken?.cancel(
                              'Update download canceled',
                            ),
                            child: Text('Cancel download'.tl),
                          )
                        else
                          FilledButton(
                            onPressed:
                                _apk != null && _stage == _UpdateStage.ready
                                ? _downloadAndInstall
                                : null,
                            child: _stage == _UpdateStage.installing
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    (_downloaded
                                            ? 'Install update'
                                            : 'Download and install')
                                        .tl,
                                  ),
                          ),
                      if (isWindows) ...[
                        FilledButton(
                          onPressed: installer == null
                              ? null
                              : () => _openUrl(installer.url),
                          child: Text('Download installer'.tl),
                        ),
                        OutlinedButton(
                          onPressed: portable == null
                              ? null
                              : () => _openUrl(portable.url),
                          child: Text('Download ZIP'.tl),
                        ),
                      ],
                      TextButton(
                        onPressed: () => _openUrl(widget.release.pageUrl),
                        child: Text('View release'.tl),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
