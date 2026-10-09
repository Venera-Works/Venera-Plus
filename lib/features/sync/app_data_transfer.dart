import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:zip_flutter/zip_flutter.dart';

FutureOr<void> Function()? _appDataSettingsChangedHandler;

void registerAppDataSettingsChangedHandler(FutureOr<void> Function()? handler) {
  _appDataSettingsChangedHandler = handler;
}

Future<void> notifyAppDataSettingsChanged() async {
  final handler = _appDataSettingsChangedHandler;
  if (handler != null) {
    await Future.sync(handler);
  }
}

Future<File> exportAppData([bool sync = true]) async {
  await HistoryManager().waitForAsyncWrites();
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var appdata = FilePath.join(
      dataPath,
      sync ? "syncdata.json" : "appdata.json",
    );
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("local_favorite.db", localFavoriteFile);
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
    for (var file in Directory(
      FilePath.join(dataPath, "comic_source"),
    ).listSync()) {
      if (file is File) {
        zipFile.addFile("comic_source/${file.name}", file.path);
      }
    }
    zipFile.close();
  });
  return cacheFile;
}

Future<void> importAppData(File file, {bool checkVersion = false}) async {
  final cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  final cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  var dataApplied = false;
  try {
    try {
      await Isolate.run(() {
        ZipFile.openAndExtract(file.path, cacheDirPath);
      });
      final historyFile = cacheDir.joinFile('history.db');
      final localFavoriteFile = cacheDir.joinFile('local_favorite.db');
      final appdataFile = cacheDir.joinFile('appdata.json');
      final cookieFile = cacheDir.joinFile('cookie.db');

      if (checkVersion && appdataFile.existsSync()) {
        final data = jsonDecode(await appdataFile.readAsString());
        final version = data['settings']['dataVersion'];
        if (version is int && version <= appdata.settings['dataVersion']) {
          return;
        }
      }

      if (await historyFile.exists()) {
        final historyManager = HistoryManager.cache;
        if (historyManager != null) {
          await historyManager.waitForAsyncWrites();
          if (historyManager.isInitialized) {
            historyManager.close();
          }
        }
        final target = File(FilePath.join(App.dataPath, 'history.db'));
        if (await target.exists()) {
          await target.delete();
          dataApplied = true;
        }
        await historyFile.rename(target.path);
        dataApplied = true;
        await HistoryManager().init();
      }

      if (await localFavoriteFile.exists()) {
        final favoritesManager = LocalFavoritesManager.cache;
        if (favoritesManager != null) {
          await favoritesManager.waitForPendingReads();
          favoritesManager.close();
        }
        final target = File(FilePath.join(App.dataPath, 'local_favorite.db'));
        if (await target.exists()) {
          await target.delete();
          dataApplied = true;
        }
        await localFavoriteFile.rename(target.path);
        dataApplied = true;
        await LocalFavoritesManager().init();
      }

      if (await appdataFile.exists()) {
        final data = jsonDecode(await appdataFile.readAsString());
        final importedSettings = data['settings'];
        if (importedSettings is Map) {
          const localSettings = {
            'proxy',
            'authorizationRequired',
            'customImageProcessing',
            'webdav',
            'disableSyncFields',
            'deviceId',
          };
          final customDisabledSettings = appdata.splitField(
            appdata.settings['disableSyncFields'] as String,
          );
          for (final key in importedSettings.keys) {
            if (!localSettings.contains(key) &&
                !customDisabledSettings.contains(key)) {
              dataApplied = true;
              appdata.settings[key] = importedSettings[key];
            }
          }
        }
        appdata.searchHistory = List.from(data['searchHistory'] ?? []);
        dataApplied = true;
        await appdata.saveData(false);
      }

      if (await cookieFile.exists()) {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
        final target = File(FilePath.join(App.dataPath, 'cookie.db'));
        if (await target.exists()) {
          await target.delete();
          dataApplied = true;
        }
        await cookieFile.rename(target.path);
        dataApplied = true;
        SingleInstanceCookieJar.instance = SingleInstanceCookieJar(target.path);
      }

      final comicSourceDir = Directory(
        FilePath.join(cacheDirPath, 'comic_source'),
      );
      if (comicSourceDir.existsSync()) {
        final target = Directory(FilePath.join(App.dataPath, 'comic_source'));
        if (await target.exists()) {
          await target.delete(recursive: true);
          dataApplied = true;
        }
        await target.create();
        dataApplied = true;
        for (final source in comicSourceDir.listSync()) {
          if (source is File) {
            await source.copy(FilePath.join(target.path, source.name));
          }
        }
        await ComicSourceManager().reload();
      }
    } finally {
      await cacheDir.deleteIgnoreError(recursive: true);
    }
  } catch (error, stackTrace) {
    if (dataApplied) {
      try {
        await notifyAppDataSettingsChanged();
      } catch (notificationError, notificationStackTrace) {
        Log.error(
          'Import Data',
          'Failed to notify app data settings changed: $notificationError',
          notificationStackTrace,
        );
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
  if (dataApplied) {
    await notifyAppDataSettingsChanged();
  }
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"] as String)
            .toList();
        folderNames.removeWhere(
          (e) => e == "folder_order" || e == "folder_sync",
        );
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          var folderName = folderSyncValue["folder_name"];
          String sourceKey = folderSyncValue["key"];
          sourceKey = sourceKey.toLowerCase() == "htmanga"
              ? "wnacg"
              : sourceKey;
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(
              folderName,
              sourceKey,
              jsonDecode(folderSyncValue["sync_data"])["folderId"],
            );
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (var folderName in folderNames) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var comic in db.select("SELECT * FROM \"$folderName\";")) {
            LocalFavoritesManager().addComic(
              folderName,
              FavoriteItem(
                id: comic['target'],
                name: comic['name'],
                coverPath: comic['cover_path'],
                author: comic['author'],
                type: ComicType(switch (comic['type']) {
                  0 => 'picacg'.hashCode,
                  1 => 'ehentai'.hashCode,
                  2 => 'jm'.hashCode,
                  3 => 'hitomi'.hashCode,
                  4 => 'wnacg'.hashCode,
                  6 => 'nhentai'.hashCode,
                  _ => comic['type'],
                }),
                tags: comic['tags'].split(','),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.dispose();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": switch (comic['type']) {
                0 => 'picacg'.hashCode,
                1 => 'ehentai'.hashCode,
                2 => 'jm'.hashCode,
                3 => 'hitomi'.hashCode,
                4 => 'wnacg'.hashCode,
                5 => 'nhentai'.hashCode,
                _ => comic['type'],
              },
              "id": comic['target'],
              "max_page": comic["max_page"],
              "ep": comic["ep"],
              "page": comic["page"],
              "time": comic["time"],
              "title": comic["title"],
              "subtitle": comic["subtitle"],
              "cover": comic["cover"],
              "readEpisode": [comic["ep"].toString()],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = comic["id"].split("-")[0];
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = comic["id"].split("-")[1];
          int page = comic["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = comic["ep"] == 0 ? 1 : comic["ep"];
          String title = comic["title"];
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.dispose();
      }
    }
  } finally {
    await cacheDir.deleteIgnoreError(recursive: true);
  }
}
