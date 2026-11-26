import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'setting_components.dart';

class LibrarySettings extends StatelessWidget {
  const LibrarySettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Library'.tl)),
        SettingPartTitle(title: 'Favorites'.tl, icon: Icons.favorite_border),
        SwitchSetting(
          title: 'Show local favorites first'.tl,
          settingKey: 'localFavoritesFirst',
        ).toSliver(),
        SwitchSetting(
          title: 'Auto close favorite panel after operation'.tl,
          settingKey: 'autoCloseFavoritePanel',
        ).toSliver(),
        SelectSetting(
          title: 'Add new favorite to'.tl,
          settingKey: 'newFavoriteAddTo',
          optionTranslation: {'start': 'Start'.tl, 'end': 'End'.tl},
        ).toSliver(),
        SelectSetting(
          title: 'Move favorite after reading'.tl,
          settingKey: 'moveFavoriteAfterRead',
          optionTranslation: {
            'none': 'None'.tl,
            'end': 'End'.tl,
            'start': 'Start'.tl,
          },
        ).toSliver(),
        SelectSetting(
          title: 'Quick Favorite'.tl,
          settingKey: 'quickFavorite',
          help:
              'Long press on the favorite button to quickly add to this folder'
                  .tl,
          optionTranslation: {
            for (final folder in LocalFavoritesManager().folders)
              folder.name: folder.path,
          },
        ).toSliver(),
        SelectSetting(
          title: 'Favorite tap action'.tl,
          settingKey: 'onClickFavorite',
          optionTranslation: {
            'viewDetail': 'View Detail'.tl,
            'read': 'Read'.tl,
          },
        ).toSliver(),
        CallbackSetting(
          title: 'Clean unavailable local favorites'.tl,
          callback: () async {
            final controller = showLoadingDialog(context);
            final count = await LocalFavoritesManager().removeInvalid();
            controller.close();
            if (context.mounted) {
              context.showMessage(
                message: 'Deleted @a favorite items'.tlParams({'a': count}),
              );
            }
          },
          actionTitle: 'Delete'.tl,
        ).toSliver(),
        SettingPartTitle(title: 'History'.tl, icon: Icons.history),
        SliderSetting(
          title: 'Auto Clear History'.tl,
          settingsIndex: 'historyRetentionDays',
          interval: 7,
          min: 0,
          max: 182,
          valueFormatter: (value) => value.round() == 0
              ? 'Off'.tl
              : '@days days'.tlParams({'days': value.round()}),
          onChanged: () {
            final retentionDays =
                (appdata.settings['historyRetentionDays'] as num).round();
            HistoryManager().clearExpiredHistory(retentionDays);
          },
        ).toSliver(),
      ],
    );
  }
}
