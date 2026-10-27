import 'package:venera_plus/foundation/startup_timing.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/log_redaction.dart';
import 'package:venera_plus/foundation/translations.dart';

/// Does not open stores or retry a bootstrap whose cleanup may have failed.
class StartupFailureApp extends StatefulWidget {
  const StartupFailureApp({
    required this.error,
    required this.stack,
    this.onRetry,
    super.key,
  });

  final Object error;
  final StackTrace stack;
  final VoidCallback? onRetry;

  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp> {
  bool _copied = false;
  bool _copyFailed = false;

  String get _diagnostic => redactLogText(
    'VeneraPlus ${App.version} (${Platform.operatingSystem})\n'
    '${StartupTiming.failedStage ?? ''}\n${widget.error}\n${widget.stack}',
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      AppTranslation.init().then<void>((_) {
        if (mounted) setState(() {});
      }, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _diagnostic));
      if (mounted) {
        setState(() {
          _copied = true;
          _copyFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _copied = false;
          _copyFailed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'VeneraPlus',
    theme: ThemeData(colorSchemeSeed: Colors.blue),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.blue,
      brightness: Brightness.dark,
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('VeneraPlus')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Startup failed'.tl,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Initialization could not finish. Keep your existing data and copy the diagnostic details for troubleshooting. Do not delete databases or reset settings first.'
                      .tl,
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _copy,
                    icon: Icon(_copied ? Icons.check : Icons.copy),
                    label: Text(
                      (_copied ? 'Copied' : 'Copy diagnostic details').tl,
                    ),
                  ),
                ),
                if (widget.onRetry != null)
                  TextButton(
                    onPressed: widget.onRetry,
                    child: Text('Retry'.tl),
                  ),
                if (_copyFailed) Text('Failed to copy diagnostic details'.tl),
                const SizedBox(height: 8),
                Text(
                  'Review personal information before sharing diagnostic details.'
                      .tl,
                ),
                const SizedBox(height: 16),
                SelectableText(_diagnostic),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
