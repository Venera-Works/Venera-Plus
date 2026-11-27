import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/logs.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class AdvancedSettings extends StatefulWidget {
  const AdvancedSettings({super.key});

  @override
  State<AdvancedSettings> createState() => _AdvancedSettingsState();
}

class _AdvancedSettingsState extends State<AdvancedSettings> {
  bool _isReloading = false;

  Future<void> _reloadSources() async {
    if (_isReloading) return;
    setState(() => _isReloading = true);
    String message;
    try {
      await ComicSourceManager().reload();
      message = 'Source reloaded'.tl;
    } catch (error) {
      message = '${'Error'.tl}: ${error.toString().tl}';
    }
    if (!mounted) return;
    setState(() => _isReloading = false);
    context.showMessage(message: message);
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Advanced'.tl)),
        SettingPartTitle(
          title: 'Diagnostics'.tl,
          icon: Icons.bug_report_outlined,
        ),
        ListTile(
          title: Text('Logs'.tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => context.to(() => const LogsPage()),
        ).toSliver(),
        CallbackSetting(
          title: 'Reload Comic Sources'.tl,
          actionTitle: 'Reload'.tl,
          isLoading: _isReloading,
          callback: _reloadSources,
        ).toSliver(),
        SettingPartTitle(title: 'Developer'.tl, icon: Icons.code),
        ListTile(
          title: Text('JS Evaluator'.tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => context.to(() => const _JsEvaluatorPage()),
        ).toSliver(),
      ],
    );
  }
}

class _JsEvaluatorPage extends StatefulWidget {
  const _JsEvaluatorPage();

  @override
  State<_JsEvaluatorPage> createState() => _JsEvaluatorPageState();
}

class _JsEvaluatorPageState extends State<_JsEvaluatorPage> {
  final _controller = TextEditingController();
  var _result = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('JS Evaluator'.tl)),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                SizedBox(
                  height: 200,
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlign: TextAlign.start,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(8),
                    ),
                  ),
                ),
                TextButton(
                  style: actionButtonStyle,
                  onPressed: () {
                    String result;
                    try {
                      result = JsEngine()
                          .runCode(_controller.text, '<debug>')
                          .toString();
                    } catch (error) {
                      result = error.toString();
                    }
                    setState(() => _result = result);
                  },
                  child: Text('Run'.tl),
                ).toAlign(Alignment.centerRight),
                Text('Result'.tl, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(color: context.colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(
                    child: Text(_result).paddingAll(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
