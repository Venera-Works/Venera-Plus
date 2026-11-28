import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/components/setting_tile.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class SwitchSetting extends StatefulWidget {
  const SwitchSetting({
    super.key,
    required this.title,
    required this.settingKey,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.enabled = true,
  });

  final String title;

  final String settingKey;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final bool enabled;

  @override
  State<SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
        : appdata.settings[widget.settingKey];

    assert(value is bool);

    return ListTile(
      enabled: widget.enabled,
      title: SettingTitle(title: widget.title, help: widget.help),
      trailing: Switch(
        value: value,
        onChanged: widget.enabled ? _changeValue : null,
      ),
    );
  }

  void _changeValue(bool value) {
    setState(() {
      if (widget.comicId != null) {
        appdata.settings.setReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          widget.settingKey,
          value,
        );
      } else if (widget.useDeviceSettings) {
        appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
      } else {
        appdata.settings[widget.settingKey] = value;
      }
    });
    appdata.saveData().then((_) {
      widget.onChanged?.call();
    });
  }
}

class SelectSetting extends StatelessWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  Object? _getValue() {
    final id = comicId;
    if (id != null) {
      if (settingKey == 'readerMode') {
        return appdata.settings.comicReaderModeOverride(id, comicSource!) ??
            'default';
      }
      return appdata.settings.getReaderSetting(id, comicSource!, settingKey);
    }
    return useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(settingKey)
        : appdata.settings[settingKey];
  }

  void _setValue(String value) {
    final id = comicId;
    if (id != null) {
      if (settingKey == 'readerMode') {
        appdata.settings.setComicReaderModeOverride(
          id,
          comicSource!,
          value == 'default' ? null : value,
        );
      } else {
        appdata.settings.setReaderSetting(id, comicSource!, settingKey, value);
      }
    } else if (useDeviceSettings) {
      appdata.settings.setDeviceReaderSetting(settingKey, value);
    } else {
      appdata.settings[settingKey] = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 450) {
            return _DoubleLineSelectSettings(
              title: title,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              getValue: _getValue,
              setValue: _setValue,
            );
          } else {
            return _EndSelectorSelectSetting(
              title: title,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              getValue: _getValue,
              setValue: _setValue,
            );
          }
        },
      ),
    );
  }
}

class _DoubleLineSelectSettings extends StatefulWidget {
  const _DoubleLineSelectSettings({
    required this.title,
    required this.optionTranslation,
    required this.getValue,
    required this.setValue,
    this.onChanged,
    this.help,
  });

  final String title;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final Object? Function() getValue;

  final ValueChanged<String> setValue;

  @override
  State<_DoubleLineSelectSettings> createState() =>
      _DoubleLineSelectSettingsState();
}

class _DoubleLineSelectSettingsState extends State<_DoubleLineSelectSettings> {
  @override
  Widget build(BuildContext context) {
    final value = widget.getValue();

    return ListTile(
      title: SettingTitle(title: widget.title, help: widget.help),
      subtitle: Text(widget.optionTranslation[value] ?? 'None'.tl),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: widget.optionTranslation.isEmpty
          ? null
          : () => _selectOption(value),
    );
  }

  Future<void> _selectOption(Object? value) async {
    final renderBox = context.findRenderObject() as RenderBox;
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final screenSize = overlay.size;
    final colors = context.colorScheme;
    final maxWidth = math.max(0.0, math.min(280.0, screenSize.width - 32));
    final selection = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      elevation: 3,
      color: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        minWidth: math.min(136.0, maxWidth),
        maxWidth: maxWidth,
        maxHeight: math.min(360.0, screenSize.height * 0.6),
      ),
      position: RelativeRect.fromRect(
        offset & renderBox.size,
        Offset.zero & screenSize,
      ),
      initialValue: value is String ? value : null,
      items: [
        for (final option in widget.optionTranslation.entries)
          PopupMenuItem<String>(
            value: option.key,
            height: App.isMobile ? 46 : 40,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    option.value,
                    style: option.key == value
                        ? TextStyle(color: colors.primary)
                        : null,
                  ),
                ),
                if (option.key == value) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 18, color: colors.primary),
                ],
              ],
            ),
          ),
      ],
    );
    if (selection == null || !mounted) return;
    setState(() => widget.setValue(selection));
    appdata.saveData();
    widget.onChanged?.call();
  }
}

class _EndSelectorSelectSetting extends StatefulWidget {
  const _EndSelectorSelectSetting({
    required this.title,
    required this.optionTranslation,
    required this.getValue,
    required this.setValue,
    this.onChanged,
    this.help,
  });

  final String title;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final Object? Function() getValue;

  final ValueChanged<String> setValue;

  @override
  State<_EndSelectorSelectSetting> createState() =>
      _EndSelectorSelectSettingState();
}

class _EndSelectorSelectSettingState extends State<_EndSelectorSelectSetting> {
  @override
  Widget build(BuildContext context) {
    final options = widget.optionTranslation;
    final value = widget.getValue();
    return ListTile(
      title: SettingTitle(title: widget.title, help: widget.help),
      trailing: Select(
        current: options[value],
        values: options.values.toList(),
        selectedIndex: options.keys.toList().indexWhere((key) => key == value),
        minWidth: 64,
        onTap: (index) {
          setState(() => widget.setValue(options.keys.elementAt(index)));
          appdata.saveData();
          widget.onChanged?.call();
        },
      ),
    );
  }
}

class SliderSetting extends StatefulWidget {
  const SliderSetting({
    super.key,
    required this.title,
    required this.settingsIndex,
    required this.interval,
    required this.min,
    required this.max,
    this.onChanged,
    this.onCommit,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.valueFormatter,
  });

  final String title;

  final String settingsIndex;

  final double interval;

  final double min;

  final double max;

  final VoidCallback? onChanged;

  /// 提供时，拖动只更新预览，松手后由回调保存最终值。
  final Future<void> Function(double value)? onCommit;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final String Function(double value)? valueFormatter;

  @override
  State<SliderSetting> createState() => _SliderSettingState();
}

class _SliderSettingState extends State<SliderSetting> {
  double? _previewValue;
  bool _committing = false;

  Future<void> _commit(double value) async {
    if (_committing) return;
    setState(() {
      _previewValue = value;
      _committing = true;
    });
    try {
      await widget.onCommit!(value);
    } finally {
      if (mounted) {
        setState(() {
          _previewValue = null;
          _committing = false;
        });
      }
    }
  }

  void _changeValue(double value) {
    if (widget.onCommit != null) {
      setState(() => _previewValue = value);
      return;
    }
    final num settingValue = value.toInt() == value ? value.toInt() : value;
    setState(() {
      if (widget.comicId != null) {
        appdata.settings.setReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          widget.settingsIndex,
          settingValue,
        );
      } else if (widget.useDeviceSettings) {
        appdata.settings.setDeviceReaderSetting(
          widget.settingsIndex,
          settingValue,
        );
      } else {
        appdata.settings[widget.settingsIndex] = settingValue;
      }
      appdata.saveData();
    });
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final value =
        _previewValue ??
        (widget.comicId != null
                ? appdata.settings.getReaderSetting(
                    widget.comicId!,
                    widget.comicSource!,
                    widget.settingsIndex,
                  )
                : widget.useDeviceSettings
                ? appdata.settings.getDeviceReaderSetting(widget.settingsIndex)
                : appdata.settings[widget.settingsIndex])
            .toDouble();
    final divisions = ((widget.max - widget.min) / widget.interval).toInt();
    final decimalPlaces = widget.interval == widget.interval.truncateToDouble()
        ? 0
        : widget.interval.toString().split('.').last.length;
    String formatValue(double value) =>
        widget.valueFormatter?.call(value) ??
        value.toStringAsFixed(decimalPlaces);
    final valueLabels = List.generate(
      divisions + 1,
      (index) => formatValue(
        widget.min + (widget.max - widget.min) * index / divisions,
      ),
    );
    return ListTile(
      title: Text(widget.title, softWrap: true, maxLines: 2),
      subtitle: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Slider(
              value: value,
              onChanged: _committing ? null : _changeValue,
              onChangeEnd: widget.onCommit == null ? null : _commit,
              divisions: divisions,
              min: widget.min,
              max: widget.max,
            ),
          ),
          const SizedBox(width: 16),
          Builder(
            builder: (context) {
              // 一次测量所有档位，数值变化时保持占位宽度一致。
              final painter = TextPainter(
                text: TextSpan(
                  text: valueLabels.join('\n'),
                  style: DefaultTextStyle.of(context).style.merge(ts.s12),
                ),
                textScaler: MediaQuery.textScalerOf(context),
                textDirection: Directionality.of(context),
              )..layout();
              final width = painter.width.ceilToDouble();
              painter.dispose();
              return SizedBox(
                width: width,
                child: Text(
                  formatValue(value),
                  style: ts.s12,
                  textAlign: TextAlign.end,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class PopupWindowSetting extends StatelessWidget {
  const PopupWindowSetting({
    super.key,
    required this.title,
    required this.builder,
    this.subtitle,
  });

  final Widget Function() builder;

  final String title;

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        showPopUpWidget(App.rootContext, builder());
      },
    );
  }
}

class MultiPagesFilter extends StatefulWidget {
  const MultiPagesFilter({
    super.key,
    required this.title,
    required this.settingsIndex,
    required this.pages,
    this.initialKeys,
    this.onSelectionChanged,
  });

  final String title;

  final String settingsIndex;

  // key - name
  final Map<String, String> pages;
  final List<String>? initialKeys;
  final ValueChanged<List<String>>? onSelectionChanged;

  @override
  State<MultiPagesFilter> createState() => _MultiPagesFilterState();
}

class _MultiPagesFilterState extends State<MultiPagesFilter> {
  late List<String> keys;
  late final List<String> _initialKeys;

  @override
  void initState() {
    keys = List<String>.from(
      widget.initialKeys ??
          appdata.settings[widget.settingsIndex] ??
          const <String>[],
    );
    keys.remove("");
    _initialKeys = List<String>.of(keys);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    Future.microtask(() {
      updateSetting();
    });
  }

  var reorderWidgetKey = UniqueKey();
  var scrollController = ScrollController();
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    var tiles = keys.map((e) => buildItem(e)).toList();

    var view = ReorderableBuilder<String>(
      key: reorderWidgetKey,
      scrollController: scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      dragChildBoxDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 5,
            offset: Offset(0, 2),
            spreadRadius: 2,
          ),
        ],
      ),
      onReorder: (reorderFunc) {
        setState(() {
          keys = List.from(reorderFunc(keys));
        });
      },
      children: tiles,
      builder: (children) {
        return GridView(
          key: _key,
          controller: scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: 48,
          ),
          children: children,
        );
      },
    );

    return PopUpWidgetScaffold(
      title: widget.title,
      tailing: [
        if (widget.pages.keys.any((key) => !keys.contains(key)))
          TextButton.icon(
            style: actionButtonStyle,
            label: Text("Add".tl),
            icon: const Icon(Icons.add),
            onPressed: showAddDialog,
          ),
      ],
      body: view,
    );
  }

  Widget buildItem(String key) {
    Widget removeButton = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        onPressed: () {
          setState(() {
            keys.remove(key);
          });
        },
        icon: const Icon(Icons.delete_outline),
      ),
    );

    return ListTile(
      title: Text(
        widget.pages[key] ?? '(Invalid) @page'.tlParams({'page': key}),
      ),
      key: Key(key),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [removeButton, const Icon(Icons.drag_handle)],
      ),
    );
  }

  void showAddDialog() {
    var canAdd = <String, String>{};
    widget.pages.forEach((key, value) {
      if (!keys.contains(key)) {
        canAdd[key] = value;
      }
    });
    var selected = <String>[];
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Add".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: canAdd.entries
                    .map(
                      (e) => CheckboxListTile(
                        value: selected.contains(e.key),
                        title: Text(e.value),
                        key: Key(e.key),
                        onChanged: (value) {
                          setState(() {
                            if (value!) {
                              selected.add(e.key);
                            } else {
                              selected.remove(e.key);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              actions: [
                if (selected.length < canAdd.length)
                  TextButton(
                    style: actionButtonStyle,
                    child: Text("Select All".tl),
                    onPressed: () {
                      setState(() {
                        selected = canAdd.keys.toList();
                      });
                    },
                  )
                else
                  TextButton(
                    style: actionButtonStyle,
                    child: Text("Deselect All".tl),
                    onPressed: () {
                      setState(() {
                        selected.clear();
                      });
                    },
                  ),
                FilledButton(
                  style: actionButtonStyle,
                  onPressed: selected.isNotEmpty
                      ? () {
                          this.setState(() {
                            keys.addAll(selected);
                          });
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text("Add".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void updateSetting() {
    if (listEquals(keys, _initialKeys)) return;
    widget.onSelectionChanged?.call(keys);
    appdata.settings[widget.settingsIndex] = keys;
    appdata.saveData();
  }
}

class CallbackSetting extends StatelessWidget {
  const CallbackSetting({
    super.key,
    required this.title,
    required this.callback,
    required this.actionTitle,
    this.subtitle,
    this.isLoading = false,
  });

  final String title;

  final String? subtitle;

  final VoidCallback callback;

  final String actionTitle;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: FilledButton.tonal(
        style: actionButtonStyle,
        onPressed: isLoading ? null : callback,
        child: ButtonLoadingContent(
          isLoading: isLoading,
          child: Text(actionTitle),
        ),
      ),
      onTap: isLoading ? null : callback,
    );
  }
}

class SettingPartTitle extends StatelessWidget {
  const SettingPartTitle({super.key, required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(header: true, child: Text(title, style: ts.s18)),
            ),
          ],
        ),
      ),
    );
  }
}
