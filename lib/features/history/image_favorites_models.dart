import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/consts.dart';

class ImageFavorite {
  final String eid;
  final String id; // 漫画id
  final int ep;
  final String epName;
  final String sourceKey;
  String imageKey;
  int page;
  bool? isAutoFavorite;

  ImageFavorite(
    this.page,
    this.imageKey,
    this.isAutoFavorite,
    this.eid,
    this.id,
    this.ep,
    this.sourceKey,
    this.epName,
  );

  Map<String, dynamic> toJson() {
    return {
      'page': page,
      'imageKey': imageKey,
      'isAutoFavorite': isAutoFavorite,
      'eid': eid,
      'id': id,
      'ep': ep,
      'sourceKey': sourceKey,
      'epName': epName,
    };
  }

  ImageFavorite.fromJson(Map<String, dynamic> json)
    : page = json['page'],
      imageKey = json['imageKey'],
      isAutoFavorite = json['isAutoFavorite'],
      eid = json['eid'],
      id = json['id'],
      ep = json['ep'],
      sourceKey = json['sourceKey'],
      epName = json['epName'];

  ImageFavorite copyWith({
    int? page,
    String? imageKey,
    bool? isAutoFavorite,
    String? eid,
    String? id,
    int? ep,
    String? sourceKey,
    String? epName,
  }) {
    return ImageFavorite(
      page ?? this.page,
      imageKey ?? this.imageKey,
      isAutoFavorite ?? this.isAutoFavorite,
      eid ?? this.eid,
      id ?? this.id,
      ep ?? this.ep,
      sourceKey ?? this.sourceKey,
      epName ?? this.epName,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImageFavorite &&
        other.id == id &&
        other.sourceKey == sourceKey &&
        other.page == page &&
        other.eid == eid &&
        other.ep == ep;
  }

  @override
  int get hashCode => Object.hash(id, sourceKey, page, eid, ep);
}

bool canUncollectImageFavorite(ImageFavorite? imageFavorite) {
  return imageFavorite != null && imageFavorite.isAutoFavorite != true;
}

class ImageFavoritesEp {
  // 小心拷贝等多章节的可能更新章节顺序
  String eid;
  final int ep;
  int maxPage;
  String epName;
  List<ImageFavorite> imageFavorites;

  ImageFavoritesEp(
    this.eid,
    this.ep,
    this.imageFavorites,
    this.epName,
    this.maxPage,
  );

  // 是否有封面
  bool get isHasFirstPage {
    return imageFavorites[0].page == firstPage;
  }

  // 是否都有imageKey
  bool get isHasImageKey {
    return imageFavorites.every((e) => e.imageKey != "");
  }

  Map<String, dynamic> toJson() {
    return {
      'eid': eid,
      'ep': ep,
      'maxPage': maxPage,
      'epName': epName,
      'imageFavorites': imageFavorites.map((e) => e.toJson()).toList(),
    };
  }
}

class ImageFavoritesComic {
  final String id;
  final String title;
  String subTitle;
  String author;
  final String sourceKey;

  // 不一定是真的这本漫画的所有页数, 如果是多章节的时候
  int maxPage;
  List<String> tags;
  List<String> translatedTags;
  final DateTime time;
  List<ImageFavoritesEp> imageFavoritesEp;
  final Map<String, dynamic> other;

  ImageFavoritesComic(
    this.id,
    this.imageFavoritesEp,
    this.title,
    this.sourceKey,
    this.tags,
    this.translatedTags,
    this.time,
    this.author,
    this.other,
    this.subTitle,
    this.maxPage,
  );

  // 是否都有imageKey
  bool get isAllHasImageKey {
    return imageFavoritesEp.every(
      (e) => e.imageFavorites.every((j) => j.imageKey != ""),
    );
  }

  int get maxPageFromEp {
    int temp = 0;
    for (var e in imageFavoritesEp) {
      temp += e.maxPage;
    }
    return temp;
  }

  // 是否都有封面
  bool get isAllHasFirstPage {
    return imageFavoritesEp.every((e) => e.isHasFirstPage);
  }

  Iterable<ImageFavorite> get images sync* {
    for (var e in imageFavoritesEp) {
      yield* e.imageFavorites;
    }
  }

  Iterable<ImageFavorite> get bookmarks =>
      images.where((image) => image.isAutoFavorite != true);

  /// Toggle an explicit favorite while retaining the gallery's automatic cover.
  bool toggleImageFavorite(
    ImageFavorite image, {
    required String firstImageKey,
    required int chapterPageCount,
  }) {
    var chapter = imageFavoritesEp.where((ep) => ep.ep == image.ep).firstOrNull;
    if (chapter != null && chapter.eid.isNotEmpty && chapter.eid != image.eid) {
      throw StateError(
        'The chapter order of the comic may have changed, temporarily not supported for collection',
      );
    }
    if (chapter == null) {
      chapter = ImageFavoritesEp(
        image.eid,
        image.ep,
        [],
        image.epName,
        chapterPageCount,
      );
      imageFavoritesEp.add(chapter);
    } else {
      chapter.eid = image.eid;
    }
    final previous = chapter.imageFavorites
        .where((entry) => entry.page == image.page)
        .firstOrNull;
    final collected = previous == null || previous.isAutoFavorite == true;
    if (previous != null) chapter.imageFavorites.remove(previous);
    if (collected) {
      chapter.imageFavorites.add(image.copyWith(isAutoFavorite: false));
    }
    if (chapter.imageFavorites.every((entry) => entry.isAutoFavorite == true)) {
      imageFavoritesEp.remove(chapter);
    } else if (!chapter.imageFavorites.any(
      (entry) => entry.page == firstPage,
    )) {
      chapter.imageFavorites.add(
        image.copyWith(
          page: firstPage,
          imageKey: firstImageKey,
          isAutoFavorite: true,
        ),
      );
    }
    return collected;
  }

  @override
  bool operator ==(Object other) {
    return other is ImageFavoritesComic &&
        other.id == id &&
        other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => Object.hash(id, sourceKey);

  factory ImageFavoritesComic.fromRow(Row r) {
    var tempImageFavoritesEp = jsonDecode(r["image_favorites_ep"]);
    List<ImageFavoritesEp> finalImageFavoritesEp = [];
    tempImageFavoritesEp.forEach((i) {
      List<ImageFavorite> temp = [];
      i["imageFavorites"].forEach((j) {
        temp.add(
          ImageFavorite(
            j["page"],
            j["imageKey"],
            j["isAutoFavorite"],
            i["eid"],
            r["id"],
            i["ep"],
            r["source_key"],
            i["epName"],
          ),
        );
      });
      finalImageFavoritesEp.add(
        ImageFavoritesEp(
          i["eid"],
          i["ep"],
          temp,
          i["epName"],
          i["maxPage"] ?? 1,
        ),
      );
    });
    return ImageFavoritesComic(
      r["id"],
      finalImageFavoritesEp,
      r["title"],
      r["source_key"],
      r["tags"].split(","),
      r["translated_tags"].split(","),
      DateTime.fromMillisecondsSinceEpoch(r["time"]),
      r["author"],
      jsonDecode(r["other"]),
      r["sub_title"],
      r["max_page"],
    );
  }
}

class TextWithCount {
  final String text;
  final int count;

  const TextWithCount(this.text, this.count);
}

class ImageFavoritesComputed {
  /// 基于收藏的标签数排序
  final List<TextWithCount> tags;

  /// 基于收藏的作者数排序
  final List<TextWithCount> authors;

  /// 基于喜欢的图片数排序
  final List<TextWithCount> comics;

  final int count;

  /// 计算后的图片收藏数据
  const ImageFavoritesComputed(
    this.tags,
    this.authors,
    this.comics,
    this.count,
  );

  bool get isEmpty => tags.isEmpty && authors.isEmpty && comics.isEmpty;
}
