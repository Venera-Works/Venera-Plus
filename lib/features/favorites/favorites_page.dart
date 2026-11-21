import 'dart:math';

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/features/favorites/favorites_constants.dart';
import 'package:venera_plus/features/favorites/local_favorites_page.dart';
import 'package:venera_plus/features/favorites/network_favorites_page.dart';
import 'package:venera_plus/features/favorites/side_bar.dart';

const _kLeftBarWidth = 256.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.isRoot = false, this.isActive = true});

  final bool isRoot;
  final bool isActive;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;
  String? _folderId;

  bool isNetwork = false;

  FolderList? folderList;

  void _saveFolderSelection() {
    appdata.implicitData['favoriteFolder'] = {
      'name': folder,
      'isNetwork': isNetwork,
      if (_folderId != null) 'id': _folderId,
    };
    appdata.writeImplicitData();
  }

  void setFolder(bool isNetwork, String? folder) {
    var selectedNetwork =
        isNetwork &&
        folder != null &&
        folder.isNotEmpty &&
        folder != localAllFolderLabel;
    var selectedFolder = folder == null || folder.isEmpty
        ? localAllFolderLabel
        : folder;
    if (selectedNetwork && getFavoriteDataOrNull(selectedFolder) == null) {
      selectedNetwork = false;
      selectedFolder = localAllFolderLabel;
    } else if (!selectedNetwork &&
        selectedFolder != localAllFolderLabel &&
        !LocalFavoritesManager().existsFolder(selectedFolder)) {
      selectedFolder = localAllFolderLabel;
    }
    setState(() {
      this.isNetwork = selectedNetwork;
      this.folder = selectedFolder;
      _folderId = selectedNetwork || selectedFolder == localAllFolderLabel
          ? null
          : LocalFavoritesManager().getFolderId(selectedFolder);
    });
    folderList?.update();
    _saveFolderSelection();
  }

  void _restoreFolderSelection() {
    final data = appdata.implicitData['favoriteFolder'];
    if (data is Map) {
      final storedFolder = data['name'];
      final storedId = data['id'];
      final storedIsNetwork = data['isNetwork'] == true;
      if (!storedIsNetwork && storedId is String) {
        final resolved = LocalFavoritesManager().getFolderNameById(storedId);
        if (resolved != null) {
          folder = resolved;
          _folderId = storedId;
          return;
        }
      }
      if (storedFolder is String && storedFolder.isNotEmpty) {
        if (storedFolder == localAllFolderLabel) {
          folder = localAllFolderLabel;
          isNetwork = false;
          return;
        }
        if (storedIsNetwork) {
          if (getFavoriteDataOrNull(storedFolder) != null) {
            folder = storedFolder;
            isNetwork = true;
            return;
          }
        } else if (storedId is! String) {
          final id = LocalFavoritesManager().getFolderId(storedFolder);
          if (id != null) {
            folder = LocalFavoritesManager().getFolderNameById(id);
            _folderId = id;
            return;
          }
        }
      }
    }
    folder = localAllFolderLabel;
    isNetwork = false;
    _saveFolderSelection();
  }

  void _refreshSelectedFolder() {
    final id = _folderId;
    if (id == null || !mounted) return;
    final currentName = LocalFavoritesManager().getFolderNameById(id);
    if (currentName != folder) setFolder(false, currentName);
  }

  void _fallbackToAllAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentFolder = folder;
      final isInvalid =
          currentFolder == null ||
          (isNetwork
              ? getFavoriteDataOrNull(currentFolder) == null
              : currentFolder != localAllFolderLabel &&
                    !LocalFavoritesManager().existsFolder(currentFolder));
      if (isInvalid) {
        setFolder(false, localAllFolderLabel);
      }
    });
  }

  Widget _buildLocalPage(String folder) {
    return LocalFavoritesPage(
      folder: folder,
      key: PageStorageKey("local_$folder"),
      showFolders: showFolderSelector,
      onFolderSelected: setFolder,
      updateFolderList: () {
        folderList?.updateFolders();
      },
      isActive: widget.isActive,
    );
  }

  @override
  void initState() {
    super.initState();
    _restoreFolderSelection();
    LocalFavoritesManager().addListener(_refreshSelectedFolder);
  }

  @override
  void dispose() {
    LocalFavoritesManager().removeListener(_refreshSelectedFolder);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(color: Theme.of(context).colorScheme.secondary),
      child: Stack(
        children: [
          AnimatedPositioned(
            left: context.width <= favoritesTwoPanelChangeWidth
                ? -_kLeftBarWidth
                : 0,
            top: 0,
            bottom: 0,
            duration: const Duration(milliseconds: 200),
            child: FavoritesFolderSidebar(
              selectedFolder: folder,
              isNetworkSelected: isNetwork,
              onFolderSelected: setFolder,
              onFolderListReady: (list) {
                folderList = list;
              },
            ).fixWidth(_kLeftBarWidth),
          ),
          Positioned(
            top: 0,
            left: context.width <= favoritesTwoPanelChangeWidth
                ? 0
                : _kLeftBarWidth,
            right: 0,
            bottom: 0,
            child: buildBody(),
          ),
        ],
      ),
    );
  }

  void showFolderSelector() {
    Navigator.of(App.rootContext).push(
      PageRouteBuilder(
        barrierDismissible: true,
        fullscreenDialog: true,
        opaque: false,
        barrierColor: Colors.black.toOpacity(0.36),
        pageBuilder: (context, animation, secondary) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Material(
              child: SizedBox(
                width: min(300, context.width - 16),
                child: FavoritesFolderSidebar(
                  withAppbar: true,
                  selectedFolder: folder,
                  isNetworkSelected: isNetwork,
                  onFolderSelected: setFolder,
                  onFolderListReady: (list) {
                    folderList = list;
                  },
                  onSelected: () {
                    context.pop();
                  },
                ),
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondary, child) {
          var offset = Tween<Offset>(
            begin: const Offset(-1, 0),
            end: const Offset(0, 0),
          );
          return SlideTransition(
            position: offset.animate(
              CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
            ),
            child: child,
          );
        },
      ),
    );
  }

  Widget buildBody() {
    final selectedFolder = folder;
    if (selectedFolder == null) {
      _fallbackToAllAfterBuild();
      return _buildLocalPage(localAllFolderLabel);
    }
    if (!isNetwork) {
      if (selectedFolder != localAllFolderLabel &&
          !LocalFavoritesManager().existsFolder(selectedFolder)) {
        _fallbackToAllAfterBuild();
        return _buildLocalPage(localAllFolderLabel);
      }
      return _buildLocalPage(selectedFolder);
    }
    final favoriteData = getFavoriteDataOrNull(selectedFolder);
    if (favoriteData == null) {
      _fallbackToAllAfterBuild();
      return _buildLocalPage(localAllFolderLabel);
    }
    return NetworkFavoritePage(
      favoriteData,
      key: PageStorageKey("network_$selectedFolder"),
      showFolders: showFolderSelector,
    );
  }
}
