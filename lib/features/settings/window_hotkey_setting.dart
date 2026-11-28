import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/setting_tile.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/window_hotkey.dart';
import 'package:venera_plus/foundation/window_hotkey_controller.dart';

class WindowHotkeySetting extends StatefulWidget {
  const WindowHotkeySetting({super.key, required this.controller});
  final WindowHotkeyController controller;
  @override
  State<WindowHotkeySetting> createState() => _WindowHotkeySettingState();
}

class _WindowHotkeySettingState extends State<WindowHotkeySetting> {
  String? _error;
  bool _editing = false;

  Future<void> _save(WindowHotkeyConfiguration next) async {
    try {
      await widget.controller.configure(next);
      if (mounted) setState(() => _error = null);
    } on WindowHotkeyFailure catch (error) {
      if (mounted) setState(() => _error = error.message.tl);
    }
  }

  Future<void> _edit({bool? enabled}) async {
    setState(() => _editing = true);
    void Function()? release;
    try {
      release = await widget.controller.hold();
      if (!mounted) return;
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _HotkeyDialog(
          configure: widget.controller.configure,
          configuration: WindowHotkeyConfiguration(
            enabled: enabled ?? widget.controller.configuration.enabled,
            hotkey: widget.controller.configuration.hotkey,
          ),
        ),
      );
      if (saved == true && mounted) setState(() => _error = null);
    } on WindowHotkeyFailure catch (error) {
      if (mounted) setState(() => _error = error.message.tl);
    } finally {
      release?.call();
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final config = controller.configuration;
      final ready =
          controller.initialized &&
          !controller.isClosed &&
          !controller.busy &&
          !_editing;
      final error = _error ?? controller.error?.message.tl;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingSwitchTile(
            title: 'Global hide/restore shortcut'.tl,
            help: 'Only the main window. Stored on this device.'.tl,
            value: config.enabled,
            onChanged: ready
                ? (enabled) {
                    if (enabled && config.hotkey == null) {
                      _edit(enabled: true);
                    } else {
                      _save(
                        WindowHotkeyConfiguration(
                          enabled: enabled,
                          hotkey: config.hotkey,
                        ),
                      );
                    }
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(config.hotkey?.label ?? 'Not set'.tl),
                TextButton(
                  style: actionButtonStyle,
                  onPressed: ready ? _edit : null,
                  child: Text('Set'.tl),
                ),
                if (config.hotkey != null)
                  TextButton(
                    style: actionButtonStyle,
                    onPressed: ready
                        ? () => _save(const WindowHotkeyConfiguration())
                        : null,
                    child: Text('Clear'.tl),
                  ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      );
    },
  );
}

class _HotkeyDialog extends StatefulWidget {
  const _HotkeyDialog({required this.configuration, required this.configure});
  final WindowHotkeyConfiguration configuration;
  final Future<void> Function(WindowHotkeyConfiguration) configure;
  @override
  State<_HotkeyDialog> createState() => _HotkeyDialogState();
}

class _HotkeyDialogState extends State<_HotkeyDialog> {
  late WindowHotkey _hotkey =
      widget.configuration.hotkey ?? WindowHotkey.suggested;
  late bool _enabled = widget.configuration.enabled;
  bool _valid = true;
  bool _saving = false;
  String? _error;
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _record(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (const [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.metaRight,
        ].contains(key) ||
        (!keyboard.isControlPressed &&
            !keyboard.isAltPressed &&
            !keyboard.isMetaPressed &&
            const [
              LogicalKeyboardKey.tab,
              LogicalKeyboardKey.escape,
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.numpadEnter,
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowLeft,
              LogicalKeyboardKey.arrowRight,
            ].contains(key))) {
      return KeyEventResult.ignored;
    }
    if (_saving) return KeyEventResult.handled;
    final label = key.keyLabel.toUpperCase();
    final function = RegExp(r'^F([1-9]|10|11)$').firstMatch(label);
    final letter = RegExp(r'^[A-Z0-9]$').hasMatch(label);
    final next = WindowHotkey(
      modifiers:
          (keyboard.isControlPressed ? WindowHotkey.control : 0) |
          (keyboard.isAltPressed ? WindowHotkey.alt : 0) |
          (keyboard.isShiftPressed ? WindowHotkey.shift : 0),
      keyCode: letter
          ? label.codeUnitAt(0)
          : function == null
          ? 0
          : 0x70 + int.parse(function.group(1)!) - 1,
    );
    setState(() {
      _valid = next.isValid && !keyboard.isMetaPressed;
      if (_valid) _hotkey = next;
      _error = null;
    });
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.configure(
        WindowHotkeyConfiguration(enabled: _enabled, hotkey: _hotkey),
      );
      if (mounted) Navigator.pop(context, true);
    } on WindowHotkeyFailure catch (error) {
      if (mounted) {
        setState(() => _error = error.message.tl);
        _focus.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: ContentDialog(
      title: 'Global hide/restore shortcut'.tl,
      dismissible: !_saving,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Focus(
              autofocus: true,
              focusNode: _focus,
              onKeyEvent: _record,
              child: InkWell(
                onTap: _focus.requestFocus,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_hotkey.label),
                ),
              ),
            ),
            Text('Use Ctrl or Alt with a letter, number or F1-F11.'.tl),
            TextButton(
              style: actionButtonStyle,
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _hotkey = WindowHotkey.suggested;
                      _valid = true;
                      _error = null;
                    }),
              child: Text('Use Ctrl + Alt + H'.tl),
            ),
            SwitchListTile(
              title: Text('Enable after saving'.tl),
              value: _enabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            if (!_valid || _error != null)
              Text(
                _error ?? 'Invalid shortcut'.tl,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: actionButtonStyle,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          style: actionButtonStyle,
          onPressed: _valid && !_saving ? _save : null,
          child: ButtonLoadingContent(
            isLoading: _saving,
            child: Text('Save'.tl),
          ),
        ),
      ],
    ),
  );
}
