import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class SettingTitle extends StatelessWidget {
  const SettingTitle({super.key, required this.title, this.help});

  final String title;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final label = Text(title);
    final description = help;
    if (description == null) return label;

    return Row(
      children: [
        Flexible(child: label),
        const SizedBox(width: 4),
        SettingHelpButton(help: description),
      ],
    );
  }
}

class SettingHelpButton extends StatelessWidget {
  const SettingHelpButton({super.key, required this.help});

  final String help;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Button.icon(
        size: 18,
        icon: const Icon(Icons.help_outline),
        tooltip: 'Help'.tl,
        onPressed: () {
          showDialog<void>(
            context: context,
            builder: (context) => ContentDialog(
              title: 'Help'.tl,
              content: Text(
                help,
              ).paddingHorizontal(16).fixWidth(double.infinity),
              actions: [
                FilledButton(
                  style: actionButtonStyle,
                  onPressed: context.pop,
                  child: Text('OK'.tl),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SettingSwitchTile extends StatelessWidget {
  const SettingSwitchTile({
    super.key,
    required this.title,
    required this.help,
    required this.value,
    required this.onChanged,
    this.contentPadding,
    this.adaptive = false,
  });

  final String title;
  final String help;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;
  final bool adaptive;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final buildSwitch = adaptive ? Switch.adaptive : Switch.new;

    // 标题里的问号和整行的开关操作需要各自可访问。
    return ListTile(
      contentPadding: contentPadding,
      enabled: onChanged != null,
      title: SettingTitle(title: title, help: help),
      trailing: ExcludeFocus(
        child: buildSwitch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      onTap: onChanged == null ? null : () => onChanged(!value),
    );
  }
}
