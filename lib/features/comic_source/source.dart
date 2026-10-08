import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';

import 'category.dart';
import 'favorites.dart';
import 'models.dart';
import 'normalization.dart';
import 'types.dart';
import 'source_files.dart';

typedef ComicSourceListResolver = List<ComicSource> Function();
typedef ComicSourceResolver = ComicSource? Function(String key);
typedef ComicSourceIntKeyResolver = ComicSource? Function(int key);
typedef ComicSourceIsEmptyResolver = bool Function();
typedef ComicSourceDataSavedHandler = Future<void> Function();

ComicSourceListResolver? _comicSourceListResolver;
ComicSourceResolver? _comicSourceResolver;
ComicSourceIntKeyResolver? _comicSourceIntKeyResolver;
ComicSourceIsEmptyResolver? _comicSourceIsEmptyResolver;
ComicSourceDataSavedHandler? _comicSourceDataSavedHandler;

void configureComicSourceRegistry({
  required ComicSourceListResolver all,
  required ComicSourceResolver find,
  required ComicSourceIntKeyResolver fromIntKey,
  required ComicSourceIsEmptyResolver isEmpty,
}) {
  _comicSourceListResolver = all;
  _comicSourceResolver = find;
  _comicSourceIntKeyResolver = fromIntKey;
  _comicSourceIsEmptyResolver = isEmpty;
}

void configureComicSourceDataSavedHandler(
  ComicSourceDataSavedHandler? handler,
) {
  _comicSourceDataSavedHandler = handler;
}

// Replacements share the complete session and its write queue. Callbacks which
// still hold the old source object must write to the same live session.
class _SourceSession {
  Map<String, dynamic> data = {};
  int revision = 0;
  String persistedSnapshot = '{}';
  Future<void>? activeSave;
  String? pendingSnapshot;
}

class ComicSource {
  static List<ComicSource> all() => _comicSourceListResolver?.call() ?? [];

  static ComicSource? find(String key) => _comicSourceResolver?.call(key);

  static ComicSource? fromIntKey(int key) {
    return _comicSourceIntKeyResolver?.call(key);
  }

  static bool get isEmpty => _comicSourceIsEmptyResolver?.call() ?? true;

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  final ComicThumbnailLoader? loadComicThumbnail;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final Map<String, dynamic> Function(String imageKey)?
  getThumbnailLoadingConfig;

  _SourceSession _session = _SourceSession();

  Map<String, dynamic> get data => _session.data;

  set data(Map<String, dynamic> value) {
    _session.data = value;
    _session.revision++;
  }

  /// Keeps callbacks to an older source attached to its current atomic session.
  void shareSessionWith(ComicSource previous) {
    _session = previous._session;
  }

  bool get isLogged => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final ChapterCommentsLoader? chapterCommentsLoader;

  final SendChapterCommentFunc? sendChapterCommentFunc;

  final RegExp? idMatcher;

  final LikeOrUnlikeComicFunc? likeOrUnlikeComic;

  final VoteCommentFunc? voteCommentFunc;

  final LikeCommentFunc? likeCommentFunc;

  final Map<String, Map<String, dynamic>>? settings;

  final Map<String, Map<String, String>>? translations;

  final HandleClickTagEvent? handleClickTagEvent;

  /// Callback when a tag suggestion is selected in search.
  final TagSuggestionSelectFunc? onTagSuggestionSelected;

  final LinkHandler? linkHandler;

  final bool enableTagsSuggestions;

  final bool enableTagsTranslate;

  final StarRatingFunc? starRatingFunc;

  final ArchiveDownloader? archiveDownloader;

  final UpdateReadProgressFunc? updateReadProgressFunc;

  final ReplyCommentFunc? replyCommentFunc;

  Future<void> loadData() async {
    final session = _session;
    final revision = session.revision;
    final original = jsonEncode(session.data);
    await waitForDataWrites();
    final dirty = jsonEncode(session.data) != session.persistedSnapshot;
    final file = File("${App.dataPath}/comic_source/$key.data");
    final loaded = await file.exists()
        ? jsonDecode(await file.readAsString())
        : <String, dynamic>{};
    if (loaded is! Map) {
      throw FormatException('Source session "$key" must be a JSON object');
    }
    // Comparing the whole map also protects nested changes made without a
    // save request yet. Never stitch an old account into a different session.
    if (identical(session, _session) &&
        session.revision == revision &&
        jsonEncode(session.data) == original &&
        !dirty) {
      session.data = Map<String, dynamic>.from(loaded);
      session.persistedSnapshot = jsonEncode(session.data);
      session.revision++;
    }
  }

  Future<void> waitForDataWrites() async {
    while (_session.activeSave != null) {
      await _session.activeSave;
    }
  }

  bool _stagingData = false;
  String? _stagedSnapshot;

  void stageDataWrites() => _stagingData = true;

  bool get hasStagedDataWrite => _stagedSnapshot != null;

  Future<void> commitDataWrites({
    void Function(String snapshot)? beforeCommit,
  }) async {
    await waitForDataWrites();
    while (_stagedSnapshot != null) {
      final snapshot = _stagedSnapshot!;
      _stagedSnapshot = null;
      await _writeData(
        snapshot,
        suffix: '.update',
        beforeCommit: beforeCommit == null
            ? null
            : () => beforeCommit(snapshot),
      );
      _session.persistedSnapshot = snapshot;
      _notifyDataChanged();
    }
    _stagingData = false;
  }

  Future<void> saveData() {
    // Serialize at the request, not when a queued write eventually starts.
    // A reload can no longer substitute imported data for this user's edit.
    final snapshot = jsonEncode(data);
    _session.revision++;
    if (_stagingData) {
      _stagedSnapshot = snapshot;
      return Future.value();
    }
    _notifyDataChanged();
    _session.pendingSnapshot = snapshot;
    return _session.activeSave ??= _drainDataWrites(_session);
  }

  void _notifyDataChanged() {
    final sync = _comicSourceDataSavedHandler?.call();
    if (sync != null) unawaited(sync);
  }

  Future<void> _drainDataWrites(_SourceSession session) async {
    try {
      while (session.pendingSnapshot != null) {
        final snapshot = session.pendingSnapshot!;
        session.pendingSnapshot = null;
        await _writeData(snapshot);
        session.persistedSnapshot = snapshot;
      }
    } finally {
      session.activeSave = null;
    }
  }

  Future<void> _writeData(
    String snapshot, {
    String suffix = '.save',
    void Function()? beforeCommit,
  }) async {
    final file = File("${App.dataPath}/comic_source/$key.data");
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}$suffix');
    try {
      await temporary.writeAsString(snapshot, flush: true);
      await SourceFileMetadata.atomicReplace(
        temporary,
        file,
        beforeCommit: beforeCommit,
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> reLogin() async {
    if (data["account"] == null) {
      return false;
    }
    final List accountData = data["account"];
    var res = await account!.login!(accountData[0], accountData[1]);
    if (res.error) {
      Log.error("Failed to re-login", res.errorMessage ?? "Error");
    }
    return !res.error;
  }

  /// Get settings dynamically from JavaScript source.
  /// This allows sources to use getters for dynamic settings that can change at runtime.
  Map<String, Map<String, dynamic>>? getSettingsDynamic() {
    try {
      var value = JsEngine().runCode("ComicSource.sources.$key.settings");
      return normalizeComicSourceSettings(value);
    } catch (e) {
      Log.error("ComicSource", "Failed to get dynamic settings: $e");
      return settings;
    }
  }

  ComicSource(
    this.name,
    this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages,
    this.searchPageData,
    this.settings,
    this.loadComicInfo,
    this.loadComicThumbnail,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.filePath,
    this.url,
    this.version,
    this.commentsLoader,
    this.sendCommentFunc,
    this.chapterCommentsLoader,
    this.sendChapterCommentFunc,
    this.likeOrUnlikeComic,
    this.voteCommentFunc,
    this.likeCommentFunc,
    this.idMatcher,
    this.translations,
    this.handleClickTagEvent,
    this.onTagSuggestionSelected,
    this.linkHandler,
    this.enableTagsSuggestions,
    this.enableTagsTranslate,
    this.starRatingFunc,
    this.archiveDownloader, {
    this.updateReadProgressFunc,
    this.replyCommentFunc,
  });
}

class AccountConfig {
  final LoginFunction? login;

  final String? loginWebsite;

  final String? registerWebsite;

  final void Function() logout;

  final List<AccountInfoItem> infoItems;

  final bool Function(String url, String title)? checkLoginStatus;

  final void Function()? onLoginWithWebviewSuccess;

  final List<String>? cookieFields;

  final Future<bool> Function(List<String>)? validateCookies;

  const AccountConfig(
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    this.logout,
    this.checkLoginStatus,
    this.onLoginWithWebviewSuccess,
    this.cookieFields,
    this.validateCookies,
  ) : infoItems = const [];
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final ComicListBuilderWithNext? loadNext;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<Comic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  final Listenable? changeListenable;

  final Future<void> Function()? onRefresh;

  ExplorePageData(
    this.title,
    this.type,
    this.loadPage,
    this.loadNext,
    this.loadMultiPart,
    this.loadMixed, {
    this.changeListenable,
    this.onRefresh,
  });
}

class ExplorePagePart {
  final String title;

  final List<Comic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final PageJumpTarget? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      int page,
      List<String> searchOption,
    );

typedef SearchNextFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      String? next,
      List<String> searchOption,
    );

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final SearchFunction? loadPage;

  final SearchNextFunction? loadNext;

  const SearchPageData(this.searchOptions, this.loadPage, this.loadNext);
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  final String type;

  final String? defaultVal;

  const SearchOptions(this.options, this.label, this.type, this.defaultVal);

  String get defaultValue => defaultVal ?? options.keys.firstOrNull ?? "";
}

typedef CategoryComicsLoader =
    Future<Res<List<Comic>>> Function(
      String category,
      String? param,
      List<String> options,
      int page,
    );

typedef CategoryOptionsLoader =
    Future<Res<List<CategoryComicsOptions>>> Function(
      String category,
      String? param,
    );

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions>? options;

  final CategoryOptionsLoader? optionsLoader;

  /// [category] is the one clicked by the user on the category page.
  ///
  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData({
    this.options,
    this.optionsLoader,
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<Comic>>> Function(String option, int page)? load;

  final Future<Res<List<Comic>>> Function(String option, String?)? loadWithNext;

  const RankingData(this.options, this.load, this.loadWithNext);
}

class CategoryComicsOptions {
  // The label will not be displayed if it is empty.
  final String label;

  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(
    this.label,
    this.options,
    this.notShowWhen,
    this.showWhen,
  );
}

class LinkHandler {
  final List<String> domains;

  final String? Function(String url) linkToId;

  const LinkHandler(this.domains, this.linkToId);
}

class ArchiveDownloader {
  final Future<Res<List<ArchiveInfo>>> Function(String cid) getArchives;

  final Future<Res<String>> Function(String cid, String aid) getDownloadUrl;

  const ArchiveDownloader(this.getArchives, this.getDownloadUrl);
}
