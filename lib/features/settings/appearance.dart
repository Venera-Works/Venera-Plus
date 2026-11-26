import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Appearance'.tl)),
        SettingPartTitle(title: "Theme".tl, icon: Icons.palette_outlined),
        SelectSetting(
          title: "Theme Mode".tl,
          settingKey: "theme_mode",
          optionTranslation: {
            "system": "System".tl,
            "light": "Light".tl,
            "dark": "Dark".tl,
          },
          onChanged: () async {
            App.forceRebuild();
          },
        ).toSliver(),
        SelectSetting(
          title: "Theme Color".tl,
          settingKey: "color",
          optionTranslation: {
            "system": "System".tl,
            "red": "Red".tl,
            "pink": "Pink".tl,
            "purple": "Purple".tl,
            "green": "Green".tl,
            "orange": "Orange".tl,
            "blue": "Blue".tl,
          },
          onChanged: () async {
            await App.init();
            App.forceRebuild();
          },
        ).toSliver(),
        SettingPartTitle(
          title: 'Comic Cards'.tl,
          icon: Icons.grid_view_outlined,
        ),
        SelectSetting(
          title: 'Card style'.tl,
          settingKey: "comicDisplayMode",
          optionTranslation: {"detailed": "Detailed".tl, "brief": "Brief".tl},
        ).toSliver(),
        SliderSetting(
          title: 'Card scale'.tl,
          settingsIndex: "comicTileScale",
          interval: 0.05,
          min: 0.5,
          max: 1.5,
        ).toSliver(),
        SelectSetting(
          title: 'List loading mode'.tl,
          settingKey: "comicListDisplayMode",
          optionTranslation: {
            "paging": "Paging".tl,
            "Continuous": "Continuous".tl,
          },
        ).toSliver(),
        SettingPartTitle(title: "Status Badges".tl, icon: Icons.badge_outlined),
        SwitchSetting(
          title: 'Show favorite status'.tl,
          settingKey: "showFavoriteStatusOnTile",
        ).toSliver(),
        SwitchSetting(
          title: 'Show reading history'.tl,
          settingKey: "showHistoryStatusOnTile",
        ).toSliver(),
        SwitchSetting(
          title: 'Show detailed reading progress'.tl,
          settingKey: 'showDetailedReadingProgress',
        ).toSliver(),
        SwitchSetting(
          title: 'Show update status'.tl,
          settingKey: "showUpdateStatusOnTile",
        ).toSliver(),
      ],
    );
  }
}
