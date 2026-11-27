import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/favorites/favorite_sync_data.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

FavoriteData? getEnabledNetworkFavoriteData(String key) {
  return (appdata.settings['favorites'] as List).contains(key)
      ? getFavoriteDataOrNull(key)
      : null;
}

/// Open a dialog to create a new favorite folder.
Future<String?> newFolder({String? parentFolderId}) {
  final manager = LocalFavoritesManager();
  var name = '';
  String? error;
  return showDialog<String>(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: (parentFolderId == null ? 'New Folder' : 'New subfolder').tl,
            content: Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    hintText: "Folder Name".tl,
                    errorText: error,
                  ),
                  onChanged: (value) {
                    name = value;
                    if (error != null) {
                      setState(() {
                        error = null;
                      });
                    }
                  },
                ),
              ],
            ).paddingHorizontal(16),
            actions: [
              if (parentFolderId == null)
                TextButton(
                  child: Text("Import from file".tl),
                  onPressed: () async {
                    try {
                      final file = await selectFile(ext: ['json']);
                      if (file == null) return;
                      final data = await file.readAsBytes();
                      if (!context.mounted ||
                          ModalRoute.of(context)?.isCurrent != true) {
                        return;
                      }
                      final previousFolders = manager.folderNames.toSet();
                      manager.fromJson(utf8.decode(data));
                      final importedFolder = manager.folderNames.firstWhere(
                        (folder) => !previousFolders.contains(folder),
                      );
                      context.pop(importedFolder);
                    } catch (e) {
                      if (context.mounted &&
                          ModalRoute.of(context)?.isCurrent == true) {
                        context.showMessage(message: "Failed to import".tl);
                      }
                    }
                  },
                ).paddingRight(4),
              FilledButton(
                onPressed: () {
                  var e = validateFolderName(name);
                  if (parentFolderId != null &&
                      !manager.folders.any(
                        (folder) =>
                            folder.id == parentFolderId &&
                            folder.parentId == null,
                      )) {
                    e = 'Favorite folder no longer exists'.tl;
                  }
                  if (e != null) {
                    setState(() {
                      error = e;
                    });
                  } else {
                    final createdName = parentFolderId == null
                        ? manager.createFolder(name)
                        : manager.createSubfolder(name, parentFolderId);
                    Navigator.of(context).pop(createdName);
                  }
                },
                child: Text("Create".tl),
              ),
            ],
          );
        },
      );
    },
  );
}

String? validateFolderName(String newFolderName, {String? currentName}) {
  final folders = LocalFavoritesManager().folderNames;
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (isInternalFavoriteTable(newFolderName) ||
      hasFavoriteFolderName(folders, newFolderName, excluding: currentName)) {
    return "Folder already exists".tl;
  }
  return null;
}

Future<void> addFavorite(List<Comic> comics) async {
  final manager = LocalFavoritesManager();
  final selected = await showDialog<String>(
    context: App.rootContext,
    builder: (context) {
      String? selectedId = manager.getFolderId(
        appdata.settings['quickFavorite'] as String? ?? '',
      );
      var query = '';

      return StatefulBuilder(
        builder: (context, setState) {
          final folders = manager.folders;
          final selectedFolder = folders
              .where((f) => f.id == selectedId)
              .firstOrNull;
          final visibleFolders = folders.where(
            (folder) => folder.matchesPath(query),
          );
          return ContentDialog(
            title: "Select a folder".tl,
            content: Column(
              children: [
                FavoriteFolderSearchField(
                  onChanged: (value) => setState(() => query = value),
                ),
                for (final folder in visibleFolders)
                  ListTile(
                    leading: Icon(
                      selectedId == folder.id
                          ? Icons.check_circle_outline
                          : Icons.folder_outlined,
                    ),
                    selected: selectedId == folder.id,
                    title: Text(folder.path),
                    onTap: () => setState(() => selectedId = folder.id),
                  ),
              ],
            ),
            actions: [
              if (selectedFolder != null)
                Text(
                  'Selected folder: @path'.tlParams({
                    'path': selectedFolder.path,
                  }),
                ),
              FilledButton(
                onPressed: selectedFolder?.matchesPath(query) == true
                    ? () => Navigator.of(context).pop(selectedId)
                    : null,
                child: Text("Confirm".tl),
              ),
            ],
          );
        },
      );
    },
  );
  if (selected == null) return;
  final folder = manager.getFolderNameById(selected);
  if (folder == null) return;
  for (final comic in comics) {
    manager.addComic(
      folder,
      FavoriteItem(
        id: comic.id,
        name: comic.title,
        coverPath: comic.cover,
        author: comic.subtitle ?? '',
        type: ComicType(
          comic.sourceKey == 'local' ? 0 : comic.sourceKey.hashCode,
        ),
        tags: comic.tags ?? [],
      ),
    );
  }
}

class FavoriteFolderSearchField extends StatelessWidget {
  const FavoriteFolderSearchField({
    super.key,
    required this.onChanged,
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: TextField(
      autofocus: autofocus,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search folders'.tl,
        isDense: true,
      ),
      onChanged: onChanged,
    ),
  );
}

Future<List<FavoriteItem>> updateComicsInfo(String folder) async {
  var comics = LocalFavoritesManager().getFolderComics(folder);

  Future<void> updateSingleComic(int index) async {
    int retry = 3;

    while (true) {
      try {
        var c = comics[index];
        var comicSource = c.type.comicSource;
        if (comicSource == null) return;

        var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

        var newTags = <String>[];
        for (var entry in newInfo.tags.entries) {
          const shouldIgnore = ['author', 'artist', 'time'];
          var namespace = entry.key;
          if (shouldIgnore.contains(namespace.toLowerCase())) {
            continue;
          }
          for (var tag in entry.value) {
            newTags.add("$namespace:$tag");
          }
        }

        comics[index] = FavoriteItem(
          id: c.id,
          name: newInfo.title,
          coverPath: newInfo.cover,
          author:
              newInfo.subTitle ??
              newInfo.tags['author']?.firstOrNull ??
              c.author,
          type: c.type,
          tags: newTags,
        );

        LocalFavoritesManager().updateInfo(folder, comics[index]);
        return;
      } catch (e) {
        retry--;
        if (retry == 0) {
          rethrow;
        }
        continue;
      }
    }
  }

  var finished = ValueNotifier(0);

  var errors = 0;

  var index = 0;

  bool isCanceled = false;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      return ValueListenableBuilder(
        valueListenable: finished,
        builder: (context, value, child) {
          var isFinished = value == comics.length;
          return ContentDialog(
            title: isFinished ? "Finished".tl : "Updating".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(value: value / comics.length),
                const SizedBox(height: 4),
                Text("$value/${comics.length}"),
                const SizedBox(height: 4),
                if (errors > 0) Text('${"Error".tl}: $errors'),
              ],
            ).paddingHorizontal(16),
            actions: [
              Button.filled(
                color: isFinished ? null : context.colorScheme.error,
                onPressed: () {
                  isCanceled = true;
                  context.pop();
                },
                child: isFinished ? Text("OK".tl) : Text("Cancel".tl),
              ),
            ],
          );
        },
      );
    },
  ).then((_) {
    isCanceled = true;
  });

  while (index < comics.length) {
    var futures = <Future>[];
    const maxConcurrency = 4;

    if (isCanceled) {
      return comics;
    }

    for (var i = 0; i < maxConcurrency; i++) {
      if (index + i >= comics.length) break;
      futures.add(
        updateSingleComic(index + i).then(
          (v) {
            finished.value++;
          },
          onError: (_) {
            errors++;
            finished.value++;
          },
        ),
      );
    }

    await Future.wait(futures);
    index += maxConcurrency;
  }

  return comics;
}

Future<void> sortFolders({String? parentFolderId}) async {
  final manager = LocalFavoritesManager();
  final folders = manager.folders
      .where((folder) => folder.parentId == parentFolderId)
      .toList();
  var changed = false;

  await showPopUpWidget(
    App.rootContext,
    StatefulBuilder(
      builder: (context, setState) {
        return PopUpWidgetScaffold(
          title: (parentFolderId == null ? 'Sort' : 'Sort subfolders').tl,
          tailing: [
            Tooltip(
              message: "Help".tl,
              child: IconButton(
                icon: const Icon(Icons.help_outline),
                onPressed: () {
                  showInfoDialog(
                    context: context,
                    title: "Reorder".tl,
                    content: "Long press and drag to reorder.".tl,
                  );
                },
              ),
            ),
          ],
          body: ReorderableListView.builder(
            onReorder: (oldIndex, newIndex) {
              if (oldIndex < newIndex) {
                newIndex--;
              }
              setState(() {
                changed = changed || oldIndex != newIndex;
                var item = folders.removeAt(oldIndex);
                folders.insert(newIndex, item);
              });
            },
            itemCount: folders.length,
            itemBuilder: (context, index) {
              return ListTile(
                key: ValueKey(folders[index].id),
                title: Text(folders[index].name),
              );
            },
          ),
        );
      },
    ),
  );

  if (changed) {
    final currentNames = {
      for (final folder in manager.folders) folder.id: folder.name,
    };
    manager.updateOrder([
      for (final folder in folders) ?currentNames[folder.id],
    ], parentFolderId: parentFolderId);
  }
}

Future<void> moveFavoriteFolder(FavoriteFolder folder) async {
  final manager = LocalFavoritesManager();
  final destination = await showDialog<String>(
    context: App.rootContext,
    builder: (context) => ContentDialog(
      title: 'Move folder'.tl,
      content: Column(
        children: [
          if (folder.parentId != null)
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text('Top level'.tl),
              onTap: () => Navigator.of(context).pop(''),
            ),
          for (final target in manager.folders)
            if (target.parentId == null &&
                target.id != folder.id &&
                target.id != folder.parentId)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(target.name),
                onTap: () => Navigator.of(context).pop(target.id),
              ),
        ],
      ),
    ),
  );
  if (destination == null) return;
  final currentFolders = manager.folders;
  if (!currentFolders.any((item) => item.id == folder.id) ||
      (destination.isNotEmpty &&
          (!currentFolders.any(
                (item) => item.id == destination && item.parentId == null,
              ) ||
              currentFolders.any((item) => item.parentId == folder.id)))) {
    App.rootContext.showMessage(message: 'Favorite folder no longer exists'.tl);
    return;
  }
  manager.moveFolder(folder.id, destination.isEmpty ? null : destination);
}

class NetworkFavoriteDialogRoute<T> extends DialogRoute<T> {
  NetworkFavoriteDialogRoute({required super.context, required super.builder});

  bool blockPop = false;

  @override
  RoutePopDisposition get popDisposition =>
      blockPop ? RoutePopDisposition.doNotPop : super.popDisposition;

  // 桌面快捷键直接调用 Navigator.pop，会绕过 popDisposition。
  @override
  bool didPop(T? result) => !blockPop && super.didPop(result);
}

Future<void> importNetworkFolder(
  String source,
  int updatePageNum,
  String? folder,
  String? folderID,
) async {
  final comicSource = ComicSource.find(source);
  if (comicSource == null) return;
  final manager = LocalFavoritesManager();
  final resultName = folder == null || folder.isEmpty
      ? comicSource.name
      : folder;
  final networkFolder = folderID ?? '';
  final existingId = manager.getFolderId(resultName);
  final existingName = existingId == null
      ? null
      : manager.getFolderNameById(existingId);
  final rootContext = App.rootContext;
  if (existingName != null &&
      !manager.isLinkedToNetworkFolder(existingName, source, networkFolder)) {
    rootContext.showMessage(message: 'Folder already exists'.tl);
    return;
  }
  final favoriteData = comicSource.favoriteData;
  final isOldToNewSort = favoriteData?.isOldToNewSort ?? false;
  final loadComic = favoriteData?.loadComic;
  final loadNext = favoriteData?.loadNext;
  var importedCount = 0;
  var receivedComics = 0;
  var requestCount = 0;
  var completed = false;
  String? errorMessage;
  VoidCallback? updateDialog;
  final comics = <Comic>[];
  final navigator = Navigator.of(rootContext, rootNavigator: true);
  late final NetworkFavoriteDialogRoute<void> route;

  void closeDialog() {
    if (!navigator.mounted || !route.isCurrent) return;
    route.blockPop = false;
    navigator.pop();
  }

  route = NetworkFavoriteDialogRoute<void>(
    context: rootContext,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        updateDialog = () {
          if (context.mounted && route.isActive) setState(() {});
        };
        final failed = errorMessage != null;
        return ContentDialog(
          title: failed
              ? 'Failed to import'.tl
              : (completed ? 'Finished' : 'Importing').tl,
          onClose: closeDialog,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!failed) LinearProgressIndicator(value: completed ? 1 : null),
              const SizedBox(height: 4),
              Text(
                'Imported @a comics, loaded @b pages, received @c comics'
                    .tlParams({
                      'a': importedCount,
                      'b': requestCount,
                      'c': receivedComics,
                    }),
              ),
              if (errorMessage case final error?) Text(error),
            ],
          ).paddingHorizontal(16),
          actions: [
            Button.filled(
              color: completed || failed ? null : context.colorScheme.error,
              onPressed: closeDialog,
              child: Text((completed || failed ? 'OK' : 'Cancel').tl),
            ),
          ],
        );
      },
    ),
  );
  unawaited(
    navigator.push(route).then((_) {
      comics.clear();
      updateDialog = null;
    }),
  );

  Future<Res<List<Comic>>?> fetchPage(
    Future<Res<List<Comic>>> Function() load,
  ) async {
    for (var attempt = 1; route.isActive; attempt++) {
      try {
        final response = await load();
        if (!route.isActive) return null;
        if (response.error) throw StateError(response.errorMessage!);
        return response;
      } catch (_) {
        if (attempt == 3) rethrow;
      }
    }
    return null;
  }

  var page = 1;
  String? next;
  var pagesToLoad = updatePageNum;
  String? createdFolder;
  try {
    if (loadComic == null && loadNext == null) {
      throw StateError('Failed to load comics'.tl);
    }
    if (loadComic != null && isOldToNewSort && pagesToLoad > 0) {
      final probe = await fetchPage(() => loadComic(1, folderID));
      if (probe == null || !route.isActive) return;
      final lastPage = probe.subData;
      if (lastPage is! int || lastPage <= 0) {
        throw StateError('Failed to load comics'.tl);
      }
      // 正序同步取末尾几页，例如共十页、同步三页时从第八页开始。
      pagesToLoad = min(updatePageNum, lastPage);
      page = lastPage - pagesToLoad + 1;
    }
    while (requestCount < pagesToLoad) {
      final response = await fetchPage(
        loadComic != null
            ? () => loadComic(page, folderID)
            : () => loadNext!(next, folderID),
      );
      if (response == null || !route.isActive) return;
      final items = response.data;
      comics.addAll(items);
      requestCount++;
      receivedComics += items.length;
      updateDialog?.call();
      if (items.isEmpty) break;
      if (loadComic != null) {
        if (response.subData == page) break;
        page++;
      } else {
        next = response.subData as String?;
        if (next == null) break;
      }
    }

    // 所有页成功且弹窗仍有效时才提交，提交期间没有异步间隔。
    if (!route.isActive) return;
    if (comics.isNotEmpty) {
      final String target;
      if (existingId != null) {
        final name = manager.getFolderNameById(existingId);
        if (name == null ||
            !manager.isLinkedToNetworkFolder(name, source, networkFolder)) {
          throw StateError('Favorite folder no longer exists'.tl);
        }
        target = name;
      } else {
        if (manager.existsFolder(resultName)) {
          throw StateError('Folder already exists'.tl);
        }
        target = createdFolder = manager.createFolder(resultName, true);
      }

      final type = ComicType(source.hashCode);
      final insertAtStart = appdata.settings['newFavoriteAddTo'] == 'start';
      final order = insertAtStart && !isOldToNewSort ? comics.reversed : comics;
      for (final comic in order) {
        final added = manager.addComic(
          target,
          FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: comic.cover,
            type: type,
            author: comic.subtitle ?? '',
            tags: comic.tags ?? [],
          ),
        );
        if (added) importedCount++;
      }
      if (createdFolder != null) {
        manager.linkFolderToNetwork(target, source, networkFolder);
      }
    }
    completed = true;
    updateDialog?.call();
  } catch (error, stackTrace) {
    if (!route.isActive) return;
    if (createdFolder != null) {
      try {
        manager.deleteFolder(createdFolder);
        importedCount = 0;
      } catch (error, stackTrace) {
        Log.error('Import network favorites', error, stackTrace);
      }
    }
    Log.error('Import network favorites', error, stackTrace);
    errorMessage = error is StateError ? error.message : error.toString();
    route.blockPop = true;
    updateDialog?.call();
    return;
  } finally {
    comics.clear();
  }

  // 成功时短暂展示实际写入数量。
  await Future.delayed(const Duration(milliseconds: 500));
  closeDialog();
}
