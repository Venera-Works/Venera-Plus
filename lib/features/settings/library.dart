import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'setting_components.dart';

class LibrarySettings extends StatelessWidget {
  const LibrarySettings({super.key});

  Future<void> _cleanUnavailableFavorites(BuildContext context) async {
    final favorites = LocalFavoritesManager();
    bool unavailable(FavoriteItem comic) => comic.type == ComicType.local
        ? LocalManager().find(comic.id, comic.type) == null
        : comic.type.comicSource == null;

    final candidates = favorites.allComics().where(unavailable).toList();
    if (candidates.isEmpty) {
      context.showMessage(message: 'No unavailable favorites to delete.'.tl);
      return;
    }
    await showConfirmDialog(
      context: context,
      title: 'Clean unavailable local favorites'.tl,
      content:
          'Delete @count unavailable favorite items? Source availability is based on the comic sources currently loaded.'
              .tlParams({'count': candidates.length}),
      confirmText: 'Delete',
      btnColor: context.colorScheme.error,
      onConfirm: () {
        final byFolder = <String, List<FavoriteItem>>{};
        final folders = favorites.folderNames.toSet();
        var count = 0;
        for (final comic in candidates) {
          if (!folders.contains(comic.folder) ||
              !unavailable(comic) ||
              !favorites.comicExists(comic.folder, comic.id, comic.type)) {
            continue;
          }
          (byFolder[comic.folder] ??= []).add(comic);
          count++;
        }
        byFolder.forEach(favorites.batchDeleteComics);
        if (context.mounted) {
          context.showMessage(
            message: 'Deleted @a favorite items'.tlParams({'a': count}),
          );
        }
      },
    );
  }

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
        ListTile(
          title: Text('Clean unavailable local favorites'.tl),
          trailing: FilledButton.tonal(
            style: actionButtonStyle,
            onPressed: () => _cleanUnavailableFavorites(context),
            child: Text('Delete'.tl),
          ),
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
          onCommit: (value) async {
            final retentionDays = value.round();
            final previousDays =
                (appdata.settings['historyRetentionDays'] as num).round();
            if (retentionDays == previousDays) return;
            final shouldClear =
                retentionDays > 0 &&
                (previousDays == 0 || retentionDays < previousDays);
            if (shouldClear) {
              var confirmed = false;
              await showConfirmDialog(
                context: context,
                title: 'Clear History'.tl,
                content:
                    'History records older than @days days will be permanently deleted.'
                        .tlParams({'days': retentionDays}),
                btnColor: context.colorScheme.error,
                onConfirm: () => confirmed = true,
              );
              if (!confirmed || !context.mounted) return;
            }
            appdata.settings['historyRetentionDays'] = retentionDays;
            await appdata.saveData();
            if (shouldClear) {
              HistoryManager().clearExpiredHistory(retentionDays);
            }
          },
        ).toSliver(),
      ],
    );
  }
}
