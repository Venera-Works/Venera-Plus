import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/code.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/translations.dart';

class SourceScriptEditorRoute extends AppPageRoute<bool> {
  SourceScriptEditorRoute({
    required String script,
    required Future<void> Function(String script) onSave,
  }) : super(
         builder: (_) => SourceScriptEditor(script: script, onSave: onSave),
       );

  @override
  bool didPop(bool? result) {
    if (result == true || popDisposition != RoutePopDisposition.doNotPop) {
      return super.didPop(result);
    }
    // 桌面端的直接返回也应触发编辑器的放弃确认。
    scheduleMicrotask(() {
      if (isCurrent) onPopInvokedWithResult(false, result);
    });
    return false;
  }
}

class SourceScriptEditor extends StatefulWidget {
  const SourceScriptEditor({
    super.key,
    required this.script,
    required this.onSave,
  });

  final String script;
  final Future<void> Function(String script) onSave;

  @override
  State<SourceScriptEditor> createState() => _SourceScriptEditorState();
}

class _SourceScriptEditorState extends State<SourceScriptEditor> {
  late String current = widget.script;
  late String saved = widget.script;
  bool saving = false;
  bool confirmingExit = false;
  String? message;

  Future<void> save() async {
    if (saving) return;
    final snapshot = current;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await widget.onSave(snapshot);
      if (mounted) {
        setState(() {
          saved = snapshot;
          message = 'Source reloaded'.tl;
        });
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> confirmExit() async {
    if (saving || confirmingExit) return;
    confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard unsaved changes?'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep editing'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Discard changes'.tl),
          ),
        ],
      ),
    );
    confirmingExit = false;
    if (discard == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !saving && current == saved,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) confirmExit();
    },
    child: Scaffold(
      appBar: Appbar(title: Text('Edit'.tl)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: saving ? null : save,
                  child: Text(saving ? 'Loading'.tl : 'Save and reload'.tl),
                ),
              ),
            ),
            if (message != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .2,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(message!),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: CodeEditor(
                initialValue: widget.script,
                onChanged: (value) {
                  final wasDirty = current != saved;
                  current = value;
                  if (wasDirty != (current != saved)) {
                    setState(() {});
                  }
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
