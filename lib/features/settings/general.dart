import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/window_hotkey_scope.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'setting_components.dart';
import 'window_hotkey_setting.dart';

class GeneralSettings extends StatefulWidget {
  const GeneralSettings({super.key});

  @override
  State<GeneralSettings> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends State<GeneralSettings> {
  @override
  Widget build(BuildContext context) {
    final windowHotkey = App.isWindows
        ? WindowHotkeyScope.maybeOf(context)
        : null;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('General'.tl)),
        SettingPartTitle(title: 'Basics'.tl, icon: Icons.tune),
        SelectSetting(
          title: 'Language'.tl,
          settingKey: 'language',
          optionTranslation: {
            'system': 'System'.tl,
            'zh-CN': '简体中文',
            'zh-TW': '繁體中文',
            'en-US': 'English',
          },
          onChanged: App.forceRebuild,
        ).toSliver(),
        SelectSetting(
          title: 'Startup Page'.tl,
          settingKey: 'initialPage',
          optionTranslation: {
            StartupPage.home.id: 'Home'.tl,
            StartupPage.library.id: 'Library (restore last)'.tl,
            StartupPage.favorites.id: 'Comic Favorites'.tl,
            StartupPage.browse.id: 'Explore / Browse'.tl,
            StartupPage.categories.id: 'Explore / Categories'.tl,
          },
        ).toSliver(),
        if (!App.isLinux) ...[
          SettingPartTitle(title: 'Security'.tl, icon: Icons.lock_outline),
          SwitchSetting(
            title: 'App Lock'.tl,
            settingKey: 'authorizationRequired',
            onChanged: () async {
              if (appdata.settings['authorizationRequired'] != true) return;
              final auth = LocalAuthentication();
              final canAuthenticate =
                  await auth.canCheckBiometrics ||
                  await auth.isDeviceSupported();
              if (canAuthenticate) return;
              appdata.settings['authorizationRequired'] = false;
              appdata.saveData();
              if (mounted) {
                context.showMessage(message: 'Biometrics not supported'.tl);
                setState(() {});
              }
            },
          ).toSliver(),
        ],
        if (windowHotkey != null) ...[
          SettingPartTitle(title: 'Window'.tl, icon: Icons.window),
          WindowHotkeySetting(controller: windowHotkey).toSliver(),
        ],
      ],
    );
  }
}
